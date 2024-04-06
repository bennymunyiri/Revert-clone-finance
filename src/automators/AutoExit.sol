// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "./Automator.sol";

/// @title AutoExit
/// @notice Lets a v3 position to be automatically removed (limit order) or swapped to the opposite token (stop loss order) when it reaches a certain tick.
/// A revert controlled bot (operator) is responsable for the execution of optimized swaps (using external swap router)
/// Positions need to be approved (approve or setApprovalForAll) for the contract and configured with configToken method
contract AutoExit is Automator {
    //@audit indexing should be used
    event Executed(
        uint256 indexed tokenId,
        address account,
        bool isSwap,
        uint256 amountReturned0,
        uint256 amountReturned1,
        address token0,
        address token1
    ); //@audit indexing of token slippage and trigger
    event PositionConfigured(
        uint256 indexed tokenId,
        bool isActive,
        bool token0Swap,
        bool token1Swap,
        int24 token0TriggerTick,
        int24 token1TriggerTick,
        uint64 token0SlippageX64,
        uint64 token1SlippageX64,
        bool onlyFees,
        uint64 maxRewardX64
    );

    constructor(
        INonfungiblePositionManager _npm,
        address _operator,
        address _withdrawer,
        uint32 _TWAPSeconds,
        uint16 _maxTWAPTickDifference,
        address _zeroxRouter,
        address _universalRouter
    )
        Automator(
            _npm,
            _operator,
            _withdrawer,
            _TWAPSeconds,
            _maxTWAPTickDifference,
            _zeroxRouter,
            _universalRouter
        )
    {}

    // define how stoploss / limit should be handled
    struct PositionConfig {
        bool isActive; // if position is active
        // should swap token to other token when triggered
        bool token0Swap;
        bool token1Swap;
        // when should action be triggered (when this tick is reached - allow execute)
        int24 token0TriggerTick; // when tick is below this one
        int24 token1TriggerTick; // when tick is equal or above this one
        // max price difference from current pool price for swap / Q64
        uint64 token0SlippageX64; // when token 0 is swapped to token 1
        uint64 token1SlippageX64; // when token 1 is swapped to token 0
        bool onlyFees; // if only fees maybe used for protocol reward
        uint64 maxRewardX64; // max allowed reward percentage of fees or full position
    }

    // configured tokens
    //@audit-info use name mappings
    //q is this the tokenId
    mapping(uint256 => PositionConfig) public positionConfigs;

    /// @notice params for execute()
    struct ExecuteParams {
        uint256 tokenId; // tokenid to process
        bytes swapData; // if its a swap order - must include swap data
        uint128 liquidity; // liquidity the calculations are based on
        uint256 amountRemoveMin0; // min amount to be removed from liquidity
        uint256 amountRemoveMin1; // min amount to be removed from liquidity
        uint256 deadline; // for uniswap operations - operator promises fair value
        uint64 rewardX64; // which reward will be used for protocol, can be max configured amount (considering onlyFees)
    }

    struct ExecuteState {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 amount0;
        uint256 amount1;
        uint256 feeAmount0;
        uint256 feeAmount1;
        uint256 amountOutMin;
        uint256 amountInDelta;
        uint256 amountOutDelta;
        IUniswapV3Pool pool;
        uint256 swapAmount;
        int24 tick;
        bool isSwap;
        bool isAbove;
        address owner;
    }

    /**
     * @notice Handle token (must be in correct state)
     * Can only be called only from configured operator account
     * Swap needs to be done with max price difference from current pool price - otherwise reverts
     */
    function execute(ExecuteParams calldata params) external {
        if (!operators[msg.sender]) {
            revert Unauthorized();
        }

        ExecuteState memory state;
        PositionConfig memory config = positionConfigs[params.tokenId];

        if (!config.isActive) {
            revert NotConfigured();
        }

        if (
            // true , true or false, true
            // it should be true , false or
            // false, false
            (config.onlyFees && params.rewardX64 > config.maxRewardX64) ||
            (!config.onlyFees && params.rewardX64 > config.maxRewardX64)
        ) {
            revert ExceedsMaxReward();
        }

        // get position info
        (
            ,
            ,
            state.token0,
            state.token1,
            state.fee,
            state.tickLower,
            state.tickUpper,
            state.liquidity,
            ,
            ,
            ,

        ) = nonfungiblePositionManager.positions(params.tokenId);

        // so can be executed only once
        if (state.liquidity == 0) {
            revert NoLiquidity();
        }
        // q when can this be otherwise
        if (state.liquidity != params.liquidity) {
            revert LiquidityChanged();
        }

        state.pool = _getPool(state.token0, state.token1, state.fee);
        // getting current tick
        (, state.tick, , , , , ) = state.pool.slot0();

        // not triggered

        //q why not move this up =>  becoz we need to get accont and stuff
        if (
            // tick is 5
            // token0 tick = 2
            // token1 tick = 6
            // @audit medium wrong use of signs in the tick as per the natspec.
            config.token0TriggerTick <= state.tick &&
            state.tick < config.token1TriggerTick
        ) {
            revert NotReady();
        }

        state.isAbove = state.tick >= config.token1TriggerTick;
        state.isSwap =
            // false 0true or true 1true
            (!state.isAbove && config.token0Swap) ||
            (state.isAbove && config.token1Swap);

        // decrease full liquidity for given position - and return fees as well
        (
            state.amount0,
            state.amount1,
            state.feeAmount0,
            state.feeAmount1
        ) = _decreaseFullLiquidityAndCollect(
            params.tokenId,
            state.liquidity,
            params.amountRemoveMin0,
            params.amountRemoveMin1,
            params.deadline
        );

        // swap to other token
        if (state.isSwap) {
            // if (params.swapData.length == 0) {
            //     revert MissingSwapData();
            // }

            // reward is taken before swap - if from fees only
            // notes we first collect fees
            if (config.onlyFees) {
                // q why do we collect fees from both coins. -> we are calculating for both instances.
                state.amount0 -= (state.feeAmount0 * params.rewardX64) / Q64;
                state.amount1 -= (state.feeAmount1 * params.rewardX64) / Q64;
            }
            //isswap is true onlyfees true
            //amount0 1000 amount1 1000 feeamount0 100 feeamount1 100
            //1000 - 150 = 750, 750
            //swapAmount => 750

            state.swapAmount = state.isAbove ? state.amount1 : state.amount0;

            // checks if price in valid oracle range and calculates amountOutMin
            (state.amountOutMin, , , ) = _validateSwap(
                !state.isAbove,
                state.swapAmount,
                state.pool,
                TWAPSeconds,
                maxTWAPTickDifference,
                state.isAbove
                    ? config.token1SlippageX64
                    : config.token0SlippageX64
            );

            (state.amountInDelta, state.amountOutDelta) = _routerSwap(
                Swapper.RouterSwapParams(
                    state.isAbove ? IERC20(state.token1) : IERC20(state.token0),
                    state.isAbove ? IERC20(state.token0) : IERC20(state.token1),
                    state.swapAmount, //750
                    state.amountOutMin, //650
                    params.swapData
                )
            );
            // isabove is true
            // amount0 => -1 + 2 = 1
            // amount1 => - 1 + 3 = 2
            //q follow-up can this lead to someone earning more tokens later while autoexitting.
            //650 +
            state.amount0 = state.isAbove
                ? state.amount0 + state.amountOutDelta
                : state.amount0 - state.amountInDelta;
            state.amount1 = state.isAbove
                ? state.amount1 - state.amountInDelta
                : state.amount1 + state.amountOutDelta;

            // when swap and !onlyFees - protocol reward is removed only from target token (to incentivize optimal swap done by operator)
            //@audit if this returns a negative number it will or lock funds
            if (!config.onlyFees) {
                if (state.isAbove) {
                    state.amount0 -= (state.amount0 * params.rewardX64) / Q64;
                } else {
                    state.amount1 -= (state.amount1 * params.rewardX64) / Q64;
                }
            }
        } else {
            // reward is taken as configured
            // could mutliply directly feeamount * params.rewardx64;
            // q what happens when  state.amount0  is a negative number
            state.amount0 -=
                ((config.onlyFees ? state.feeAmount0 : state.amount0) *
                    params.rewardX64) /
                Q64;
            state.amount1 -=
                ((config.onlyFees ? state.feeAmount1 : state.amount1) *
                    params.rewardX64) /
                Q64;
        }

        state.owner = nonfungiblePositionManager.ownerOf(params.tokenId);
        if (state.amount0 > 0) {
            _transferToken(
                state.owner,
                IERC20(state.token0),
                state.amount0,
                true
            );
        }
        if (state.amount1 > 0) {
            _transferToken(
                state.owner,
                IERC20(state.token1),
                state.amount1,
                true
            );
        }

        // delete config for position
        delete positionConfigs[params.tokenId];

        //q is this necessary
        emit PositionConfigured(
            params.tokenId,
            false,
            false,
            false,
            0,
            0,
            0,
            0,
            false,
            0
        );

        // log event
        emit Executed(
            params.tokenId,
            msg.sender,
            state.isSwap,
            state.amount0,
            state.amount1,
            state.token0,
            state.token1
        );
    }

    // function to configure a token to be used with this runner
    // it needs to have approvals set for this contract beforehand
    function configToken(
        uint256 tokenId,
        PositionConfig calldata config
    ) external {
        address owner = nonfungiblePositionManager.ownerOf(tokenId);
        if (owner != msg.sender) {
            revert Unauthorized();
        }

        if (config.isActive) {
            if (config.token0TriggerTick >= config.token1TriggerTick) {
                revert InvalidConfig();
            }
        }

        positionConfigs[tokenId] = config;

        emit PositionConfigured(
            tokenId,
            config.isActive,
            config.token0Swap,
            config.token1Swap,
            config.token0TriggerTick,
            config.token1TriggerTick,
            config.token0SlippageX64,
            config.token1SlippageX64,
            config.onlyFees,
            config.maxRewardX64
        );
    }
}
