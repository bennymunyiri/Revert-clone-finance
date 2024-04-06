// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FixedPoint128.sol";

import "v3-periphery/libraries/LiquidityAmounts.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";

import "permit2/interfaces/IPermit2.sol";

import "./interfaces/IVault.sol";
import "./interfaces/IV3Oracle.sol";
import "./interfaces/IInterestRateModel.sol";
import "./interfaces/IErrors.sol";

contract V3Vault is
    ERC20,
    Multicall,
    Ownable,
    IVault,
    IERC721Receiver,
    IErrors
{
    using Math for uint256;
    ///////////////////////////////
    // Constants///////////////////
    /////////////////////////////
    uint256 private constant Q32 = 2 ** 32;
    uint256 private constant Q96 = 2 ** 96;

    uint32 public constant MAX_COLLATERAL_FACTOR_X32 = uint32((Q32 * 90) / 100); // 90%

    uint32 public constant MIN_LIQUIDATION_PENALTY_X32 =
        uint32((Q32 * 2) / 100); // 2%
    uint32 public constant MAX_LIQUIDATION_PENALTY_X32 =
        uint32((Q32 * 10) / 100); // 10%

    uint32 public constant MIN_RESERVE_PROTECTION_FACTOR_X32 =
        uint32(Q32 / 100); //1%

    uint32 public constant MAX_DAILY_LEND_INCREASE_X32 = uint32(Q32 / 10); //10%
    uint32 public constant MAX_DAILY_DEBT_INCREASE_X32 = uint32(Q32 / 10); //10%

    IUniswapV3Factory public immutable factory;
    IInterestRateModel public immutable interestRateModel;
    IV3Oracle public immutable oracle;
    IPermit2 public immutable permit2;

    INonfungiblePositionManager public immutable nonfungiblePositionManager;

    address public immutable override asset;
    uint8 private immutable assetDecimals;

    uint256 public lastDebtExchangeRateX96 = Q96;
    uint256 public lastLendExchangeRateX96 = Q96;

    uint256 private transformedTokenId = 0; // transient storage (when available in dencun)

    uint256 public globalDebtLimit = 0;
    uint256 public globalLendLimit = 0;

    // daily lend increase limit handling
    uint256 public dailyLendIncreaseLimitMin = 0;
    uint256 public dailyLendIncreaseLimitLeft = 0;
    uint256 public dailyLendIncreaseLimitLastReset = 0;

    // daily debt increase limit handling
    uint256 public dailyDebtIncreaseLimitMin = 0;
    uint256 public dailyDebtIncreaseLimitLeft = 0;
    uint256 public dailyDebtIncreaseLimitLastReset = 0;

    uint256 public lastExchangeRateUpdate = 0;
    uint256 public debtSharesTotal = 0;
    uint32 public reserveFactorX32 = 0;
    ///////////////////////////////
    // mappings///////////////////
    /////////////////////////////
    struct Loan {
        uint256 debtShares;
    }
    mapping(uint256 => Loan) public loans;

    mapping(address => uint256[]) private ownedTokens;
    mapping(uint256 => address) private tokenOwner;
    mapping(address => bool) public transformerAllowList;

    mapping(uint256 => uint256) private ownedTokensIndex;
    mapping(address => mapping(uint256 => mapping(address => bool)))
        public transformApprovals;

    ///////////////////////////////
    // Events///////////////////
    /////////////////////////////
    event ExchangeRateUpdate(
        uint256 debtExchangeRateX96,
        uint256 lendExchangeRateX96
    );
    event Add(uint256 indexed tokenId, address owner, uint256 oldTokenId);
    event Remove(uint256 indexed tokenId, address recipient);

    struct TokenConfig {
        uint32 collateralFactorX32; // how much this token is valued as collateral
        uint32 collateralValueLimitFactorX32; // how much asset equivalent may be lent out given this collateral
        uint192 totalDebtShares; // how much debt shares are theoretically backed by this collateral
    }

    mapping(address => TokenConfig) public tokenConfigs;

    constructor(
        string memory name,
        string memory symbol,
        address _asset,
        INonfungiblePositionManager _nonfungiblePositionManager,
        IInterestRateModel _interestRateModel,
        IV3Oracle _oracle,
        IPermit2 _permit2
    ) ERC20(name, symbol) {
        asset = _asset;
        assetDecimals = IERC20Metadata(_asset).decimals();
        nonfungiblePositionManager = _nonfungiblePositionManager;
        factory = IUniswapV3Factory(_nonfungiblePositionManager.factory());
        interestRateModel = _interestRateModel;
        oracle = _oracle;
        permit2 = _permit2;
    }

    ///////////////////////////////
    // External functions ///////////////////
    /////////////////////////////

    // gets the total information about the vault
    function vaultInfo()
        external
        view
        override
        returns (
            uint256 debt,
            uint256 lent,
            uint256 balance,
            uint256 available,
            uint256 reserves,
            uint256 debtExchangeRateX96,
            uint256 lendExchangeRateX96
        )
    {
        (debtExchangeRateX96, lendExchangeRateX96) = _calculateGlobalInterest();

        (balance, available, reserves) = _getAvailableBalance(
            debtExchangeRateX96,
            lendExchangeRateX96
        );

        debt = _convertToAssets(
            debtSharesTotal,
            debtExchangeRateX96,
            Math.Rounding.Up
        );
        lent = _convertToAssets(
            totalSupply(),
            lendExchangeRateX96,
            Math.Rounding.Up
        );
    }

    // lenders informations
    function lendInfo(
        address account
    ) external view override returns (uint256 amount) {
        (, uint256 newLendExchangeRateX96) = _calculateGlobalInterest();
        amount = _convertToAssets(
            balanceOf(account),
            newLendExchangeRateX96,
            Math.Rounding.Down
        );
    }

    // gets debters informations
    function loanInfo(
        uint256 tokenId
    )
        external
        view
        override
        returns (
            uint256 debt,
            uint256 fullValue,
            uint256 collateralValue,
            uint256 liquidationCost,
            uint256 liquidationValue
        )
    {}

    // mapping of tokenId TO owner
    function ownerOf(
        uint256 tokenId
    ) external view override returns (address owner) {
        return tokenOwner[tokenId];
    }

    function loanCount(address owner) external view override returns (uint256) {
        return ownedTokens[owner].length;
    }

    // retrieve number tokens owned to the protocol.
    function loanAtIndex(
        address owner,
        uint256 index
    ) external view override returns (uint256) {
        return ownedTokens[owner][index];
    }

    ///////////////////////////////
    //IERC4626 functions ///////////////////
    /////////////////////////////

    ////////////////// OVERRIDDEN EXTERNAL VIEW FUNCTIONS FROM ERC20
    /// @inheritdoc IERC20Metadata
    function decimals()
        public
        view
        override(IERC20Metadata, ERC20)
        returns (uint8)
    {
        return assetDecimals;
    }

    ////////////////// OVERRIDDEN EXTERNAL VIEW FUNCTIONS FROM ERC4626

    /// @inheritdoc IERC4626
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset).balanceOf(address(this));
    }

    /// @inheritdoc IERC4626
    function convertToShares(
        uint256 assets
    ) external view override returns (uint256 shares) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return
            _convertToShares(assets, lendExchangeRateX96, Math.Rounding.Down);
    }

    function convertToAssets(
        uint256 shares
    ) external view override returns (uint256 assets) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return
            _convertToAssets(
                shares,
                lastLendExchangeRateX96,
                Math.Rounding.Down
            );
    }

    function maxDeposit(address) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        uint256 value = _convertToAssets(
            totalSupply(),
            lendExchangeRateX96,
            Math.Rounding.Up
        );
        if (value >= globalLendLimit) {
            return 0;
        } else {
            return globalLendLimit - value;
        }
    }

    function maxMint(address) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        uint256 value = _convertToAssets(
            totalSupply(),
            lendExchangeRateX96,
            Math.Rounding.Up
        );
        if (value >= globalLendLimit) {
            return 0;
        } else {
            return
                _convertToShares(
                    globalLendLimit - value,
                    lendExchangeRateX96,
                    Math.Rounding.Down
                );
        }
    }

    function maxRedeem(address owner) external view override returns (uint256) {
        return balanceOf(owner);
    }

    function maxWithdraw(
        address owner
    ) external view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return
            _convertToAssets(
                //q can this break the protocl
                balanceOf(owner),
                lendExchangeRateX96,
                Math.Rounding.Down
            );
    }

    function previewDeposit(
        uint256 assets
    ) public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return
            _convertToShares(assets, lendExchangeRateX96, Math.Rounding.Down);
    }

    function previewMint(
        uint256 shares
    ) public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToAssets(shares, lendExchangeRateX96, Math.Rounding.Up);
    }

    function previewRedeem(
        uint256 shares
    ) public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return _convertToShares(shares, lendExchangeRateX96, Math.Rounding.Up);
    }

    function previewWithdraw(
        uint256 assets
    ) public view override returns (uint256) {
        (, uint256 lendExchangeRateX96) = _calculateGlobalInterest();
        return
            _convertToAssets(assets, lendExchangeRateX96, Math.Rounding.Down);
    }

    ////////////////// OVERRIDDEN EXTERNAL FUNCTIONS FROM ERC4626

    function deposit(
        uint256 assets,
        address receiver
    ) external override returns (uint256) {
        (, uint256 shares) = _deposit(receiver, assets, false, "");

        return shares;
    }

    function mint(
        uint256 shares,
        address receiver
    ) external override returns (uint256) {
        (uint256 assets, ) = _deposit(receiver, shares, true, "");
        return assets;
    }

    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) external override returns (uint256) {
        (, uint256 shares) = _withdraw(receiver, owner, assets, false);
        return shares;
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) external override returns (uint256) {
        (uint256 assets, ) = _withdraw(receiver, owner, shares, true);
        return assets;
    }

    ///////////////////////////////
    //  Permit 2///////////////////
    /////////////////////////////

    function deposit(
        uint256 assets,
        address receiver,
        bytes calldata permitData
    ) external override returns (uint256) {
        (, uint256 shares) = _deposit(receiver, assets, false, permitData);
        return shares;
    }

    // mint using permit2 data
    function mint(
        uint256 shares,
        address receiver,
        bytes calldata permitData
    ) external override returns (uint256) {
        (uint256 assets, ) = _deposit(receiver, shares, true, permitData);
        return assets;
    }

    function create(uint256 tokenId, address recipient) external override {
        nonfungiblePositionManager.safeTransferFrom(
            msg.sender,
            address(this),
            tokenId,
            abi.encode(recipient)
        );
    }

    function createWithPermit(
        uint256 tokenId,
        address owner,
        address recipient,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override {}

    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        if (
            msg.sender != address(nonfungiblePositionManager) ||
            from == address(this)
        ) {
            revert WrongContract();
        }
        (
            uint256 debtExchangeRateX96,
            uint256 lendExchangeRateX96
        ) = _updateGlobalInterest();

        if (transformedTokenId == 0) {
            address owner = from;

            if (data.length > 0) {
                owner = abi.decode(data, (address));
            }
            loans[tokenId] = Loan(0);
            _addTokenToOwner(owner, tokenId);
            emit Add(tokenId, owner, 0);
        } else {
            uint256 oldTokenId = transformedTokenId;
            if (tokenId != oldTokenId) {
                address owner = tokenOwner[oldTokenId];

                transformedTokenId = tokenId;
                loans[tokenId] = Loan(loans[oldTokenId].debtShares);

                _addTokenToOwner(owner, tokenId);
                emit Add(tokenId, owner, oldTokenId);
                _cleanupLoan(
                    oldTokenId,
                    debtExchangeRateX96,
                    lendExchangeRateX96,
                    owner
                );

                // sets data of new loan
                _updateAndCheckCollateral(
                    tokenId,
                    debtExchangeRateX96,
                    lendExchangeRateX96,
                    0,
                    loans[tokenId].debtShares
                );
            }
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    function approveTransform(
        uint256 tokenId,
        address target,
        bool isActive
    ) external override {
        if (tokenOwner[tokenId] != msg.sender) {
            revert Unauthorized();
        }
        transformApprovals[msg.sender][tokenId][target] = isActive;
    }

    function transform(
        uint256 tokenId,
        address transformer,
        bytes calldata data
    ) external override returns (uint256 newTokenId) {
        if (tokenId == 0 || !transformerAllowList[transformer]) {
            revert TransformNotAllowed();
        }
        if (transformedTokenId > 0) {
            revert Reentrancy();
        }
        transformedTokenId = tokenId;

        (uint256 newDebtExchangeRateX96, ) = _updateGlobalInterest();

        address loanOwner = tokenOwner[tokenId];

        if (
            loanOwner != msg.sender &&
            !transformApprovals[loanOwner][tokenId][msg.sender]
        ) {
            revert Unauthorized();
        }
        nonfungiblePositionManager.approve(transformer, tokenId);
        (bool success, ) = transformer.call(data);

        if (!success) {
            revert TransformFailed();
        }
        tokenId = transformedTokenId;
        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner != address(this)) {
            revert Unauthorized();
        }
        nonfungiblePositionManager.approve(address(0), tokenId);

        uint256 debt = _convertToAssets(
            loans[tokenId].debtShares,
            newDebtExchangeRateX96,
            Math.Rounding.Up
        );
    }

    function borrow(uint256 tokenId, uint256 assets) external override {}

    function decreaseLiquidityAndCollect(
        DecreaseLiquidityAndCollectParams calldata params
    ) external override returns (uint256 amount0, uint256 amount1) {}

    function repay(
        uint256 tokenId,
        uint256 amount,
        bool isShare
    ) external override {}

    function liquidate(
        LiquidateParams calldata params
    ) external override returns (uint256 amount0, uint256 amount1) {}

    function withdrawReserves(
        uint256 amount,
        address receiver
    ) external onlyOwner {}

    function setTransformer(
        address transformer,
        bool active
    ) external onlyOwner {}

    function setLimits(
        uint256 _minLoanSize,
        uint256 _globalLendLimit,
        uint256 _globalDebtLimit,
        uint256 _dailyLendIncreaseLimitMin,
        uint256 _dailyDebtIncreaseLimitMin
    ) external {}

    function setReserveFactor(uint32 _reserveFactorX32) external onlyOwner {}

    function setReserveProtectionFactor() external onlyOwner {}

    function setTokenConfig(
        address token,
        uint32 collateralFactorX32,
        uint32 collateralValueLimitFactorX32
    ) external onlyOwner {}

    function setEmergencyAdmin(address admin) external onlyOwner {}

    //////////////////
    ///INTERNAL FUNCTIONS//
    /////////////////

    function _deposit(
        address receiver,
        uint256 amount,
        bool isShare,
        bytes memory permitData
    ) internal returns (uint256 assets, uint256 shares) {
        (, uint newLendExchangeRateX96) = _updateGlobalInterest();
        _resetDailyDebtIncreaseLimit(newLendExchangeRateX96, false);

        if (isShare) {
            shares = amount;
            assets = _convertToAssets(
                shares,
                newLendExchangeRateX96,
                Math.Rounding.Up
            );
        } else {
            assets = amount;
            shares = _convertToShares(
                assets,
                newLendExchangeRateX96,
                Math.Rounding.Down
            );
        }

        if (permitData.length > 0) {
            (
                ISignatureTransfer.PermitTransferFrom memory permit,
                bytes memory signature
            ) = abi.decode(
                    permitData,
                    (ISignatureTransfer.PermitTransferFrom, bytes)
                );
            permit2.permitTransferFrom(
                permit,
                ISignatureTransfer.SignatureTransferDetails(
                    address(this),
                    assets
                ),
                msg.sender,
                signature
            );
        } else {
            SafeERC20.safeTransferFrom(
                IERC20(asset),
                msg.sender,
                address(this),
                assets
            );
        }

        _mint(receiver, shares);
        if (totalSupply() > globalLendLimit) {
            revert GlobalLendLimit();
        }
        if (assets > dailyLendIncreaseLimitLeft) {
            revert DailyLendIncreaseLimit();
        } else {
            dailyLendIncreaseLimitLeft -= assets;
        }
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function _withdraw(
        address receiver,
        address owner,
        uint256 amount,
        bool isShare
    ) internal returns (uint256 assets, uint256 shares) {
        (
            uint256 newDebtExchangeRateX96,
            uint256 newLendExchangeRateX96
        ) = _updateGlobalInterest();

        if (isShare) {
            shares = amount;
            assets = _convertToAssets(
                amount,
                newLendExchangeRateX96,
                Math.Rounding.Down
            );
        } else {
            assets = amount;
            shares = _convertToShares(
                amount,
                newLendExchangeRateX96,
                Math.Rounding.Up
            );
        }

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        (, uint256 available, ) = _getAvailableBalance(
            newDebtExchangeRateX96,
            newLendExchangeRateX96
        );
        if (available < assets) {
            revert InsufficientLiquidity();
        }
        _burn(owner, shares);
        SafeERC20.safeTransfer(IERC20(asset), receiver, assets);

        dailyLendIncreaseLimitLeft += assets;

        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function _repay(
        uint256 tokenId,
        uint256 amount,
        bool isShare,
        bytes memory permitData
    ) internal {}

    function _getAvailableBalance(
        uint256 debtExchangeRateX96,
        uint256 lendExchangeRateX96
    )
        internal
        view
        returns (uint256 balance, uint256 available, uint256 reserves)
    {
        balance = totalAssets();

        uint256 debt = _convertToAssets(
            debtSharesTotal,
            debtExchangeRateX96,
            Math.Rounding.Up
        );
        uint256 lent = _convertToAssets(
            totalSupply(),
            lendExchangeRateX96,
            Math.Rounding.Down
        );

        reserves = balance + debt > lent ? balance + debt - lent : 0;
        available = balance > reserves ? balance - reserves : 0;
    }

    function _sendPositionValue(
        uint256 tokenId,
        uint256 liquidationValue,
        uint256 fullValue,
        uint256 feeValue,
        address recipient
    ) internal returns (uint256 amount0, uint256 amount1) {}

    function _cleanupLoan(
        uint256 tokenId,
        uint256 debtExchangeRateX96,
        uint256 lendExchangeRateX96,
        address owner
    ) internal {
        _removeTokenFromOwner(owner, tokenId);
        _updateAndCheckCollateral(
            tokenId,
            debtExchangeRateX96,
            lendExchangeRateX96,
            loans[tokenId].debtShares,
            0
        );
        delete loans[tokenId];
        nonfungiblePositionManager.safeTransferFrom(
            address(this),
            owner,
            tokenId
        );
        emit Remove(tokenId, owner);
    }

    function _calculateLiquidation(
        uint256 debt,
        uint256 fullValue,
        uint256 collateralValue
    )
        internal
        pure
        returns (
            uint256 liquidationValue,
            uint256 liquidatorCost,
            uint256 reserveCost
        )
    {}

    function _handlerReserveLiquidation(
        uint256 reserveCost,
        uint256 newDebtExchangeRateX96,
        uint256 newLendExchangeRateX96
    ) internal returns (uint256 missing) {}

    function _calculateTokenCollateralFactorX32(
        uint256 tokenId
    ) internal view returns (uint32) {
        (
            ,
            ,
            address token0,
            address token1,
            ,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = nonfungiblePositionManager.positions(tokenId);
        uint32 factor0X32 = tokenConfigs[token0].collateralFactorX32;
        uint32 factor1X32 = tokenConfigs[token1].collateralFactorX32;
        return factor0X32 > factor1X32 ? factor1X32 : factor0X32;
    }

    function _updateGlobalInterest()
        internal
        returns (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96)
    {
        if (block.timestamp > lastExchangeRateUpdate) {
            (
                newDebtExchangeRateX96,
                newLendExchangeRateX96
            ) = _calculateGlobalInterest();
            lastDebtExchangeRateX96 = newDebtExchangeRateX96;
            lastLendExchangeRateX96 = newLendExchangeRateX96;
            lastExchangeRateUpdate = block.timestamp;
            emit ExchangeRateUpdate(
                newDebtExchangeRateX96,
                newLendExchangeRateX96
            );
        } else {
            newDebtExchangeRateX96 = lastDebtExchangeRateX96;
            newLendExchangeRateX96 = lastLendExchangeRateX96;
        }
    }

    function _calculateGlobalInterest()
        internal
        view
        returns (uint256 newDebtExchangeRateX96, uint256 newLendExchangeRateX96)
    {
        uint256 oldDebtExchangeRateX96 = lastDebtExchangeRateX96;
        uint256 oldLendExchangeRateX96 = lastLendExchangeRateX96;

        (, uint256 available, ) = _getAvailableBalance(
            oldDebtExchangeRateX96,
            oldLendExchangeRateX96
        );
        uint256 debt = _convertToAssets(
            debtSharesTotal,
            oldDebtExchangeRateX96,
            Math.Rounding.Up
        );
        (uint256 borrowRateX96, uint256 supplyRateX96) = interestRateModel
            .getRatesPerSecondX96(available, debt);

        supplyRateX96 = supplyRateX96.mulDiv(Q32 - reserveFactorX32, Q32);

        uint256 lastRateUpdate = lastExchangeRateUpdate;

        if (lastRateUpdate > 0) {
            newDebtExchangeRateX96 =
                oldDebtExchangeRateX96 +
                (oldDebtExchangeRateX96 *
                    (block.timestamp - lastRateUpdate) *
                    borrowRateX96) /
                Q96;
            newLendExchangeRateX96 =
                oldLendExchangeRateX96 +
                (oldLendExchangeRateX96 *
                    (block.timestamp - lastRateUpdate) *
                    supplyRateX96) /
                Q96;
        } else {
            newDebtExchangeRateX96 = oldDebtExchangeRateX96;
            newLendExchangeRateX96 = oldLendExchangeRateX96;
        }
    }

    function _requireLoanIsHealthy(
        uint256 tokenId,
        uint256 debt
    ) internal view {
        (bool isHealthy, , , ) = _checkLoanIsHealthy(tokenId, debt);
        if (!isHealthy) {
            revert CollateralFail();
        }
    }

    function _updateAndCheckCollateral(
        uint256 tokenId,
        uint256 debtExchangeRateX96,
        uint256 lendExchangeRateX96,
        uint256 oldShares,
        uint256 newShares
    ) internal {
        if (oldShares != newShares) {
            (
                ,
                ,
                address token0,
                address token1,
                ,
                ,
                ,
                ,
                ,
                ,
                ,

            ) = nonfungiblePositionManager.positions(tokenId);
            if (oldShares > newShares) {
                tokenConfigs[token0].totalDebtShares -= SafeCast.toUint192(
                    oldShares - newShares
                );
                tokenConfigs[token1].totalDebtShares -= SafeCast.toUint192(
                    oldShares - newShares
                );
            } else {
                tokenConfigs[token0].totalDebtShares += SafeCast.toUint192(
                    newShares - oldShares
                );
                tokenConfigs[token1].totalDebtShares += SafeCast.toUint192(
                    newShares - oldShares
                );
                uint256 lentAssets = _convertToAssets(
                    totalSupply(),
                    lendExchangeRateX96,
                    Math.Rounding.Up
                );
                uint256 collateralValueLimitFactorX32 = tokenConfigs[token0]
                    .collateralValueLimitFactorX32;
                if (
                    collateralValueLimitFactorX32 < type(uint32).max &&
                    _convertToAssets(
                        tokenConfigs[token0].totalDebtShares,
                        debtExchangeRateX96,
                        Math.Rounding.Up
                    ) >
                    (lentAssets * collateralValueLimitFactorX32) / Q32
                ) {
                    revert CollateralValueLimit();
                }
                collateralValueLimitFactorX32 = tokenConfigs[token1]
                    .collateralValueLimitFactorX32;
                if (
                    collateralValueLimitFactorX32 < type(uint32).max &&
                    _convertToAssets(
                        tokenConfigs[token1].totalDebtShares,
                        debtExchangeRateX96,
                        Math.Rounding.Up
                    ) >
                    (lentAssets * collateralValueLimitFactorX32) / Q32
                ) {
                    revert CollateralValueLimit();
                }
            }
        }
    }

    function _resetDailyLendIncreaseLimit(
        uint256 newLendExchangeRateX96,
        bool force
    ) internal {
        uint256 time = block.timestamp / 1 days;

        if (force || time > dailyLendIncreaseLimitLastReset) {
            uint256 lendIncreaseLimit = (_convertToAssets(
                totalSupply(),
                newLendExchangeRateX96,
                Math.Rounding.Up
            ) * (Q32 + MAX_DAILY_LEND_INCREASE_X32)) / Q32;
            dailyLendIncreaseLimitLeft = dailyLendIncreaseLimitMin >
                lendIncreaseLimit
                ? dailyLendIncreaseLimitMin
                : lendIncreaseLimit;

            dailyLendIncreaseLimitLastReset = time;
        }
    }

    function _resetDailyDebtIncreaseLimit(
        uint256 newLendExchangeRateX96,
        bool force
    ) internal {}

    function _checkLoanIsHealthy(
        uint256 tokenId,
        uint256 debt
    )
        internal
        view
        returns (
            bool isHealthy,
            uint256 fullValue,
            uint256 collateralValue,
            uint256 feeValue
        )
    {
        (fullValue, feeValue, , ) = oracle.getValue(tokenId, address(asset));
        uint256 collateralFactorX32 = _calculateTokenCollateralFactorX32(
            tokenId
        );
        collateralValue = fullValue.mulDiv(collateralFactorX32, Q32);
        isHealthy = collateralValue >= debt;
    }

    function _convertToShares(
        uint256 amount,
        uint256 exchangeRateX96,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        return amount.mulDiv(Q96, exchangeRateX96, rounding);
    }

    function _convertToAssets(
        uint256 shares,
        uint256 exchangeRateX96,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        return shares.mulDiv(exchangeRateX96, Q96, rounding);
    }

    function _addTokenToOwner(address to, uint256 tokenId) internal {
        ownedTokensIndex[tokenId] = ownedTokens[to].length;
        ownedTokens[to].push(tokenId);
        tokenOwner[tokenId] = to;
    }

    function _removeTokenFromOwner(address from, uint256 tokenId) internal {
        uint256 lastTokenIndex = ownedTokens[from].length - 1;
        uint256 tokenIndex = ownedTokensIndex[tokenId];
        if (tokenIndex != lastTokenIndex) {
            uint256 lastTokenId = ownedTokens[from][lastTokenIndex];
            ownedTokens[from][tokenIndex] = lastTokenId;
            ownedTokensIndex[lastTokenId] = tokenIndex;
        }
        ownedTokens[from].pop();
        // Note that ownedTokensIndex[tokenId] is not deleted. There is no need to delete it - gas optimization
        delete tokenOwner[tokenId]; // Remove the token from the token owner mapping
    }
}
