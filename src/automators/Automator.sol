// SPDX-License-Identifier: BUSL-1.1
// @audit aderyn.
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "v3-core/interfaces/IUniswapV3Factory.sol";
import "v3-core/interfaces/IUniswapV3Pool.sol";
import "v3-core/libraries/TickMath.sol";
import "v3-core/libraries/FullMath.sol";

import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../../lib/IWETH9.sol";
import "../utils/Swapper.sol";
import "../interfaces/IVault.sol";

abstract contract Automator is Swapper, Ownable {
    uint256 internal constant Q64 = 2 ** 64;
    uint256 internal constant Q96 = 2 ** 96;

    uint32 public constant MIN_TWAP_SECONDS = 60; // 1 minute
    uint32 public constant MAX_TWAP_TICK_DIFFERENCE = 200; // 2%

    // admin events
    event OperatorChanged(address newOperator, bool active);
    event VaultChanged(address newVault, bool active);

    event WithdrawerChanged(address newWithdrawer);
    //@audit-info this should be indexed
    event TWAPConfigChanged(uint32 TWAPSeconds, uint16 maxTWAPTickDifference);

    // configurable by owner
    mapping(address => bool) public operators;
    mapping(address => bool) public vaults;

    address public withdrawer;
    uint32 public TWAPSeconds;
    uint16 public maxTWAPTickDifference;

    //  who is the initial owner? am assuming the first to deploy this contract
    // does this mean they will be only one operator or?
    constructor(
        INonfungiblePositionManager npm,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference,
        address _zeroxRouter,
        address _universalRouter
    ) Swapper(npm, _zeroxRouter, _universalRouter) {
        setOperator(_operator, true);
        setWithdrawer(_withdrawer);
        setTWAPConfig(_maxTWAPTickDifference, _TWAPSeconds);
    }

    /**
     * @notice Owner controlled function to set withdrawer address
     * @param _withdrawer withdrawer
     */
    //does this follow cei
    // q what if its address 0.
    function setWithdrawer(address _withdrawer) public onlyOwner {
        emit WithdrawerChanged(_withdrawer);
        withdrawer = _withdrawer;
    }

    /**
     * @notice Owner controlled function to activate/deactivate operator address
     * @param _operator operator
     * @param _active active or not
     */
    // does this follow CEI
    // what if we set the operator to address(0) what will happen?
    function setOperator(address _operator, bool _active) public onlyOwner {
        emit OperatorChanged(_operator, _active);
        operators[_operator] = _active;
    }

    /**
     * @notice Owner controlled function to activate/deactivate vault address
     * @param _vault vault
     * @param _active active or not
     */
    // what happens when we deactivate a vault with funds and users
    //  how do we deactivate
    // what happens when we set vault as address zero.
    function setVault(address _vault, bool _active) public onlyOwner {
        emit VaultChanged(_vault, _active);
        vaults[_vault] = _active;
    }

    /**
     * @notice Owner controlled function to increase TWAPSeconds / decrease maxTWAPTickDifference
     */
    function setTWAPConfig(
        uint16 _maxTWAPTickDifference,
        uint32 _TWAPSeconds
    ) public onlyOwner {
        if (_TWAPSeconds < MIN_TWAP_SECONDS) {
            revert InvalidConfig();
        }
        if (_maxTWAPTickDifference > MAX_TWAP_TICK_DIFFERENCE) {
            revert InvalidConfig();
        }
        emit TWAPConfigChanged(_TWAPSeconds, _maxTWAPTickDifference);
        TWAPSeconds = _TWAPSeconds;
        maxTWAPTickDifference = _maxTWAPTickDifference;
    }

    /**
     * @notice Withdraws token balance (accumulated protocol fee)
     * @param tokens Addresses of tokens to withdraw
     * @param to Address to send to
     */
    function withdrawBalances(
        address[] calldata tokens,
        address to
    ) external virtual {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 i;
        uint256 count = tokens.length;
        for (; i < count; ++i) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                _transferToken(to, IERC20(tokens[i]), balance, true);
            }
        }
    }

    /**
     * @notice Withdraws ETH balance
     * @param to Address to send to
     */
    // q us eth different from other coins in this protol why do we withdraw it separately
    function withdrawETH(address to) external {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 balance = address(this).balance;
        if (balance > 0) {
            (bool sent, ) = to.call{value: balance}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        }
    }

    // validate if swap can be done with specified oracle parameters - if not possible reverts
    // if possible returns minAmountOut
    // q what tokens are we validating for a swap -> eg the one used to delevrage in autoexit.sol

    function _validateSwap(
        // q what is this boolean value
        bool swap0For1,
        uint256 amountIn,
        IUniswapV3Pool pool,
        uint32 twapPeriod,
        uint16 maxTickDifference,
        uint64 maxPriceDifferenceX64
    )
        internal
        view
        returns (
            uint256 amountOutMin,
            int24 currentTick,
            uint160 sqrtPriceX96,
            uint256 priceX96
        )
    {
        // get current price and tick
        (sqrtPriceX96, currentTick, , , , , ) = pool.slot0();

        // check if current tick not too far from TWAP
        if (
            !_hasMaxTWAPTickDifference(
                pool,
                twapPeriod,
                currentTick,
                maxTickDifference
            )
        ) {
            revert TWAPCheckFailed();
        }

        // calculate min output price price and percentage
        priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, Q96);
        if (swap0For1) {
            // notes calculates minimum amount out for amount using Fullmath library
            amountOutMin = FullMath.mulDiv(
                amountIn * (Q64 - maxPriceDifferenceX64),
                priceX96,
                Q96 * Q64
            );
        } else {
            amountOutMin = FullMath.mulDiv(
                amountIn * (Q64 - maxPriceDifferenceX64),
                Q96,
                priceX96 * Q64
            );
        }
    }

    // Checks if there was not more tick difference
    // returns false if not enough data available or tick difference >= maxDifference
    function _hasMaxTWAPTickDifference(
        IUniswapV3Pool pool,
        uint32 twapPeriod,
        int24 currentTick,
        uint16 maxDifference
    ) internal view returns (bool) {
        (int24 twapTick, bool twapOk) = _getTWAPTick(pool, twapPeriod);
        if (twapOk) {
            return
                twapTick - currentTick >= -int16(maxDifference) &&
                twapTick - currentTick <= int16(maxDifference);
        } else {
            return false;
        }
    }

    // gets twap tick from pool history if enough history available
    function _getTWAPTick(
        IUniswapV3Pool pool,
        uint32 twapPeriod
    ) internal view returns (int24, bool) {
        uint32[] memory secondsAgos = new uint32[](2);
        // q why zero
        secondsAgos[0] = 0; // from (before)
        secondsAgos[1] = twapPeriod; // from (before)

        // pool observe may fail when there is not enough history available
        try pool.observe(secondsAgos) returns (
            int56[] memory tickCumulatives,
            uint160[] memory
        ) {
            return (
                int24(
                    (tickCumulatives[0] - tickCumulatives[1]) /
                        int56(uint56(twapPeriod))
                ),
                true
            );
        } catch {
            return (0, false);
        }
    }

    // q why are we doing this?? -> to decrease liquidity and collect in autoexit.sol
    function _decreaseFullLiquidityAndCollect(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amountRemoveMin0,
        uint256 amountRemoveMin1,
        uint256 deadline
    )
        internal
        returns (
            uint256 amount0,
            uint256 amount1,
            uint256 feeAmount0,
            uint256 feeAmount1
        )
    {
        if (liquidity > 0) {
            // store in temporarely "misnamed" variables - see comment below
            // q what is returned this first variable or after minusing -> its the last one
            (feeAmount0, feeAmount1) = nonfungiblePositionManager
                .decreaseLiquidity(
                    INonfungiblePositionManager.DecreaseLiquidityParams(
                        tokenId,
                        liquidity,
                        amountRemoveMin0,
                        amountRemoveMin1,
                        deadline
                    )
                );
        }
        (amount0, amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(
                tokenId,
                address(this),
                type(uint128).max,
                type(uint128).max
            )
        );

        // fee amount is what was collected additionally to liquidity amount
        // q is this where the this contract collects the money -> the amount of fees accrued by holding this position.
        // q what is returned this first variable or after minusing  follow-up which one is returned the first variable or this one. -> this one
        feeAmount0 = amount0 - feeAmount0;
        feeAmount1 = amount1 - feeAmount1;
    }

    // transfers token (or unwraps WETH and sends ETH)
    function _transferToken(
        address to,
        IERC20 token,
        uint256 amount,
        bool unwrap
    ) internal {
        if (address(weth) == address(token) && unwrap) {
            weth.withdraw(amount);
            (bool sent, ) = to.call{value: amount}("");
            if (!sent) {
                revert EtherSendFailed();
            }
        } else {
            SafeERC20.safeTransfer(token, to, amount);
        }
    }

    function _validateOwner(
        uint256 tokenId,
        address vault
    ) internal returns (address owner) {
        // msg.sender must not be a vault
        if (vaults[msg.sender]) {
            revert Unauthorized();
        }

        if (vault != address(0)) {
            if (!vaults[vault]) {
                revert Unauthorized();
            }
            owner = IVault(vault).ownerOf(tokenId);
        } else {
            // q does this mean a vault can be address 0
            owner = nonfungiblePositionManager.ownerOf(tokenId);
        }

        if (owner != msg.sender) {
            revert Unauthorized();
        }
    }

    // needed for WETH unwrapping
    receive() external payable {
        if (msg.sender != address(weth)) {
            revert NotWETH();
        }
    }
}
