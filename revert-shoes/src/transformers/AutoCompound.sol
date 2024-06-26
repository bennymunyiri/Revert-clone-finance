// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Multicall.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "v3-periphery/interfaces/INonfungiblePositionManager.sol";

import "../automators/Automator.sol";

contract AutoCompound is Automator, Multicall, ReentrancyGuard {
    //////////////////////////////
    // Events
    //////////////////////////////
    event BalanceAdded(uint256 tokenId, address token, uint256 amount);
    event BalanceRemoved(uint256 tokenId, address token, uint256 amount);
    event BalanceWithdrawn(
        uint256 tokenId,
        address token,
        address to,
        uint256 amount
    );

    //////////////////////////////
    // Constructor
    //////////////////////////////
    constructor(
        INonfungiblePositionManager _npm,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference
    )
        Automator(
            _npm,
            _operator,
            _withdrawer,
            _TWAPSeconds,
            _maxTWAPTickDifference,
            address(0),
            address(0)
        )
    {}

    //////////////////////////////
    // Mappings
    //////////////////////////////
    mapping(uint256 => mapping(address => uint256)) public positionBalances;

    uint64 public constant MAX_REWARD_X64 = uint64(Q64 / 50); // 2%
    uint64 public totalRewardX64 = MAX_REWARD_X64;

    //////////////////////////////
    // Structs
    //////////////////////////////
    // cause i jus
    struct ExecuteParams {
        // account or tokenId to autocompound
        uint256 tokenId;
        // swap direction
        bool swap0to1;
        // swap amount calculated off-chain if this is set to 0 no swap happens
        uint256 amountIn;
    }
    struct ExecuteState {
        uint256 amount0;
        uint256 amount1;
        uint256 maxAddAmount0;
        uint256 maxAddAmount1;
        uint256 amount0Fees;
        uint256 amount1Fees;
        uint256 priceX96;
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 compounded0;
        uint256 compounded1;
        int24 tick;
        uint160 sqrtPriceX96;
        uint256 amountInDelta;
        uint256 amountOutDelta;
    }

    //////////////////////////////
    // External
    //////////////////////////////
    function executeWithVault(
        ExecuteParams calldata params,
        address vault
    ) external {
        if (!operators[msg.sender] || !vaults[vault]) {
            revert Unauthorized();
        }
        IVault(vault).transform(
            params.tokenId,
            address(this),
            abi.encodeWithSelector(AutoCompound.execute.selector, params)
        );
    }

    function execute(ExecuteParams calldata params) external nonReentrant {
        if (!operators[msg.sender] && !vaults[msg.sender]) {
            revert Unauthorized();
        }
        ExecuteState memory state;
        (state.amount0, state.amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(
                params.tokenId,
                address(this),
                type(uint128).max,
                type(uint128).max
            )
        );
        (
            ,
            ,
            state.token0,
            state.token1,
            state.fee,
            state.tickLower,
            state.tickUpper,
            ,
            ,
            ,
            ,

        ) = nonfungiblePositionManager.positions(params.tokenId);

        state.amount0 =
            state.amount0 +
            positionBalances[params.tokenId][state.token0];
        state.amount1 =
            state.amount1 +
            positionBalances[params.tokenId][state.token1];

        // state autocompoundingBalances to work with - start autocompounding process
        if (state.amount0 > 0 || state.amount1 > 0) {
            uint256 amountIn = params.amountIn;

            if (amountIn > 0) {
                IUniswapV3Pool pool = _getPool(
                    state.token0,
                    state.token1,
                    state.fee
                );
                (state.sqrtPriceX96, state.tick, , , , , ) = pool.slot0();
                uint32 tSecs = TWAPSeconds;

                if (tSecs > 0) {
                    if (
                        !_hasMaxTWAPTickDifference(
                            pool,
                            tSecs,
                            state.tick,
                            maxTWAPTickDifference
                        )
                    ) {
                        amountIn = 0;
                    }
                }
                if (amountIn > 0) {
                    (state.amountInDelta, state.amountOutDelta) = _poolSwap(
                        Swapper.PoolSwapParams(
                            pool,
                            IERC20(state.token0),
                            IERC20(state.token1),
                            state.fee,
                            params.swap0to1,
                            amountIn,
                            0
                        )
                    );
                    state.amount0 = params.swap0to1
                        ? state.amount0 - state.amountInDelta
                        : state.amount0 + state.amountOutDelta;
                    state.amount1 = params.swap0to1
                        ? state.amount1 + state.amountOutDelta
                        : state.amount1 - state.amountInDelta;
                }
            }
            uint256 rewardX64 = totalRewardX64;

            state.maxAddAmount0 = (state.amount0 * Q64) / (rewardX64 + Q64);
            state.maxAddAmount1 = (state.amount1 * Q64) / (rewardX64 + Q64);

            if (state.maxAddAmount0 > 0 || state.maxAddAmount1 > 0) {
                _checkApprovals(state.token0, state.token1);
            }
            (
                ,
                state.compounded0,
                state.compounded1
            ) = nonfungiblePositionManager.increaseLiquidity(
                INonfungiblePositionManager.IncreaseLiquidityParams(
                    params.tokenId,
                    state.maxAddAmount0,
                    state.maxAddAmount1,
                    0,
                    0,
                    block.timestamp
                )
            );

            state.amount0Fees = (state.compounded0 * rewardX64) / Q64;
            state.amount1Fees = (state.compounded1 * rewardX64) / Q64;

            _setBalance(
                params.tokenId,
                state.token0,
                state.amount0 - state.compounded0 - state.amount0Fees
            );
            _setBalance(
                params.tokenId,
                state.token1,
                state.amount1 - state.compounded1 - state.amount1Fees
            );

            _increaseBalance(0, state.token0, state.amount0Fees);
            _increaseBalance(0, state.token1, state.amount1Fees);
        }
    }

    function withdrawLeftoverBalances(
        uint256 tokenId,
        address to
    ) external nonReentrant {
        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (vaults[owner]) {
            owner = IVault(owner).ownerOf(tokenId);
        }
        if (owner != msg.sender) {
            revert Unauthorized();
        }
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
        uint256 balance0 = positionBalances[tokenId][token0];
        if (balance0 > 0) {
            _withdrawBalanceInternal(tokenId, token0, to, balance0, balance0);
        }
        uint256 balance1 = positionBalances[tokenId][token1];
        if (balance1 > 0) {
            _withdrawBalanceInternal(tokenId, token1, to, balance1, balance1);
        }
    }

    function withdrawBalances(
        address[] calldata tokens,
        address to
    ) external override nonReentrant {
        if (msg.sender != withdrawer) {
            revert Unauthorized();
        }

        uint256 i;
        uint256 count = tokens.length;
        for (; i < count; ++i) {
            uint256 balance = positionBalances[0][tokens[i]];
            _withdrawBalanceInternal(0, tokens[i], to, balance, balance);
        }
    }

    function setReward() external onlyOwner {}

    //////////////////////////////
    // Internal
    //////////////////////////////

    function _increaseBalance(
        uint256 tokenId,
        address token,
        uint256 amount
    ) internal {
        positionBalances[tokenId][token] =
            positionBalances[tokenId][token] +
            amount;
        emit BalanceAdded(tokenId, token, amount);
    }

    function _setBalance(
        uint256 tokenId,
        address token,
        uint256 amount
    ) internal {
        uint256 currentBalance = positionBalances[tokenId][token];
        if (amount != currentBalance) {
            positionBalances[tokenId][token] = amount;
            if (amount > currentBalance) {
                emit BalanceAdded(tokenId, token, amount - currentBalance);
            } else {
                emit BalanceRemoved(tokenId, token, currentBalance - amount);
            }
        }
    }

    function _withdrawBalanceInternal(
        uint256 tokenId,
        address token,
        address to,
        uint256 balance,
        uint256 amount
    ) internal {
        require(amount <= balance, "amount>balance");
        positionBalances[tokenId][token] =
            positionBalances[tokenId][token] -
            amount;
        emit BalanceRemoved(tokenId, token, amount);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit BalanceWithdrawn(tokenId, token, to, amount);
    }

    function _checkApprovals(address token0, address token1) internal {
        uint256 allowance0 = IERC20(token0).allowance(
            address(this),
            address(nonfungiblePositionManager)
        );

        if (allowance0 == 0) {
            SafeERC20.safeApprove(
                IERC20(token0),
                address(nonfungiblePositionManager),
                type(uint256).max
            );
        }
        uint256 allowance1 = IERC20(token1).allowance(
            address(this),
            address(nonfungiblePositionManager)
        );
        if (allowance1 == 0) {
            SafeERC20.safeApprove(
                IERC20(token1),
                address(nonfungiblePositionManager),
                type(uint256).max
            );
        }
    }
}
