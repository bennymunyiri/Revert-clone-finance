// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "permit2/interfaces/IPermit2.sol";

import "../utils/Swapper.sol";

contract V3Utils is Swapper, IERC721Receiver {
    IPermit2 public immutable permit2;

    event SwapAndIncreaseLiquidity(
        uint256 indexed tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event ChangeRange(uint256 indexed tokenId, uint256 newTokenId);
    event CompoundFees(
        uint256 indexed tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event SwapAndMint(
        uint256 indexed tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event WithdrawAndCollectAndSwap(
        uint256 indexed tokenId,
        address token,
        uint256 amount
    );

    constructor(
        INonfungiblePositionManager _npm,
        address _zeroXRouter,
        address _universalRouter,
        address _permit2
    ) Swapper(_npm, _zeroXRouter, _universalRouter) {
        permit2 = IPermit2(_permit2);
    }

    ////'////////////////////////////
    // Enums
    //////////////////////////////////

    enum WhatToDo {
        CHANGE_RANGE,
        WITHDRAW_AND_COLLECT_AND_SWAP,
        COMPOUND_FEES
    }
    ////'////////////////////////////
    // Structs
    //////////////////////////////////
    struct Instructions {
        // what action to perform on provided Uniswap v3 position
        WhatToDo whatToDo;
        // target token for swaps (if this is address(0) no swaps are executed)
        address targetToken;
        // for removing liquidity slippage
        uint256 amountRemoveMin0;
        uint256 amountRemoveMin1;
        // amountIn0 is used for swap and also as minAmount0 for decreased liquidity + collected fees
        uint256 amountIn0;
        // if token0 needs to be swapped to targetToken - set values
        uint256 amountOut0Min;
        bytes swapData0; // encoded data from 0x api call (address,bytes) - allowanceTarget,data
        // amountIn1 is used for swap and also as minAmount1 for decreased liquidity + collected fees
        uint256 amountIn1;
        // if token1 needs to be swapped to targetToken - set values
        uint256 amountOut1Min;
        bytes swapData1; // encoded data from 0x api call (address,bytes) - allowanceTarget,data
        // collect fee amount for COMPOUND_FEES / CHANGE_RANGE / WITHDRAW_AND_COLLECT_AND_SWAP (if uint256(128).max - ALL)
        uint256 feeAmount0;
        uint256 feeAmount1;
        // for creating new positions with CHANGE_RANGE
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        // remove liquidity amount for COMPOUND_FEES (in this case should be probably 0) / CHANGE_RANGE / WITHDRAW_AND_COLLECT_AND_SWAP
        uint128 liquidity;
        // for adding liquidity slippage
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        // for all uniswap deadlineable functions
        uint256 deadline;
        // left over tokens will be sent to this address
        // what actions create new nft and does the config change in the nft
        address recipient;
        // recipient of newly minted nft (the incoming NFT will ALWAYS be returned to from)
        address recipientNFT;
        // if tokenIn or tokenOut is WETH - unwrap
        bool unwrap;
        // data sent with returned token to IERC721Receiver (optional)
        bytes returnData;
        // data sent with minted token to IERC721Receiver (optional)
        bytes swapAndMintReturnData;
    }

    function executeWithPermit(
        uint256 tokenId,
        Instructions memory instructions,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public returns (uint256 newTokenID) {
        if (nonfungiblePositionManager.ownerOf(tokenId) != msg.sender) {
            revert Unauthorized();
        }

        nonfungiblePositionManager.permit(
            address(this),
            tokenId,
            instructions.deadline,
            v,
            r,
            s
        );
        return execute(tokenId, instructions);
    }

    function execute(
        uint256 tokenId,
        Instructions memory instructions
    ) public returns (uint256 newTokenId) {
        (
            ,
            ,
            address token0,
            address token1,
            ,
            ,
            ,
            uint128 liquidity,
            ,
            ,
            ,

        ) = nonfungiblePositionManager.positions(tokenId);

        uint256 amount0;
        uint256 amount1;

        if (instructions.liquidity != 0) {
            (amount0, amount1) = _decreaseLiquidity(
                tokenId,
                instructions.liquidity,
                instructions.deadline,
                instructions.amountRemoveMin0,
                instructions.amountRemoveMin1
            );
        }

        // (amount0, amount1) = _collectFees(
        //     tokenId,
        //     IERC20(token0),
        //     IERC20(token1),
        //     instructions.feeAmount0 == type(uint128).max // q if amount is greater than uint128 this will revert leading to locked funds
        //         ? type(uint128).max
        //         : (amount0 + instructions.feeAmount0).toUint128(),
        //     instructions.feeAmount1 == type(uint128).max
        //         ? type(uint128).max
        //         : (amount1 + instructions.feeAmount1).toUint128()
        // );

        if (
            amount0 < instructions.amountIn0 || amount1 < instructions.amountIn1
        ) {
            revert AmountError();
        }

        if (instructions.whatToDo == WhatToDo.COMPOUND_FEES) {
            if (instructions.targetToken == token0) {
                (liquidity, amount0, amount1) = _swapAndIncrease(
                    SwapAndIncreaseLiquidityParams(
                        tokenId,
                        amount0,
                        amount1,
                        instructions.recipient,
                        instructions.deadline,
                        IERC20(address(0)),
                        0,
                        0,
                        "",
                        0,
                        0,
                        "",
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        ""
                    ),
                    IERC20(token0),
                    IERC20(token1),
                    instructions.unwrap
                );
            } else if (instructions.targetToken == token1) {
                (liquidity, amount0, amount1) = _swapAndIncrease(
                    SwapAndIncreaseLiquidityParams(
                        tokenId,
                        amount0,
                        amount1,
                        instructions.recipient,
                        instructions.deadline,
                        IERC20(token0),
                        0,
                        0,
                        "",
                        instructions.amountIn0,
                        instructions.amountOut0Min,
                        instructions.swapData0,
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        ""
                    ),
                    IERC20(token0),
                    IERC20(token1),
                    instructions.unwrap
                );
            } else {
                (liquidity, amount0, amount1) = _swapAndIncrease(
                    SwapAndIncreaseLiquidityParams(
                        tokenId,
                        amount0,
                        amount1,
                        instructions.recipient,
                        instructions.deadline,
                        IERC20(address(0)),
                        0,
                        0,
                        "",
                        0,
                        0,
                        "",
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        ""
                    ),
                    IERC20(token0),
                    IERC20(token1),
                    instructions.unwrap
                );
            }
            emit CompoundFees(tokenId, liquidity, amount0, amount1);
        } else if (instructions.whatToDo == WhatToDo.CHANGE_RANGE) {
            if (instructions.targetToken == token0) {
                (newTokenId, , , ) = _swapAndMint(
                    SwapAndMintParams(
                        IERC20(token0),
                        IERC20(token1),
                        instructions.fee,
                        instructions.tickLower,
                        instructions.tickUpper,
                        amount0,
                        amount1,
                        instructions.recipient,
                        instructions.recipientNFT,
                        instructions.deadline,
                        IERC20(token1),
                        instructions.amountIn1,
                        instructions.amountOut1Min,
                        instructions.swapData1,
                        0,
                        0,
                        "",
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        instructions.swapAndMintReturnData,
                        ""
                    ),
                    instructions.unwrap
                );
            } else if (instructions.targetToken == token1) {
                (newTokenId, , , ) = _swapAndMint(
                    SwapAndMintParams(
                        IERC20(token0),
                        IERC20(token1),
                        instructions.fee,
                        instructions.tickLower,
                        instructions.tickUpper,
                        amount0,
                        amount1,
                        instructions.recipient,
                        instructions.recipientNFT,
                        instructions.deadline,
                        IERC20(token0),
                        0,
                        0,
                        "",
                        instructions.amountIn0,
                        instructions.amountOut0Min,
                        instructions.swapData0,
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        instructions.swapAndMintReturnData,
                        ""
                    ),
                    instructions.unwrap
                );
            } else {
                // no swap is done here
                (newTokenId, , , ) = _swapAndMint(
                    SwapAndMintParams(
                        IERC20(token0),
                        IERC20(token1),
                        instructions.fee,
                        instructions.tickLower,
                        instructions.tickUpper,
                        amount0,
                        amount1,
                        instructions.recipient,
                        instructions.recipientNFT,
                        instructions.deadline,
                        IERC20(address(0)),
                        0,
                        0,
                        "",
                        0,
                        0,
                        "",
                        instructions.amountAddMin0,
                        instructions.amountAddMin1,
                        instructions.swapAndMintReturnData,
                        ""
                    ),
                    instructions.unwrap
                );
            }
            emit ChangeRange(tokenId, newTokenId);
        } else if (
            instructions.whatToDo == WhatToDo.WITHDRAW_AND_COLLECT_AND_SWAP
        ) {
            uint256 targetAmount;
            if (token0 != instructions.targetToken) {
                (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                    Swapper.RouterSwapParams(
                        IERC20(token0),
                        IERC20(instructions.targetToken),
                        amount0,
                        instructions.amountOut0Min,
                        instructions.swapData0
                    )
                );
                if (amountInDelta < amount0) {
                    _transferToken(
                        instructions.recipient,
                        IERC20(token0),
                        amount0 - amountInDelta,
                        instructions.unwrap
                    );
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += amount0;
            }
            if (token1 != instructions.targetToken) {
                (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                    Swapper.RouterSwapParams(
                        IERC20(token1),
                        IERC20(instructions.targetToken),
                        amount1,
                        instructions.amountOut1Min,
                        instructions.swapData1
                    )
                );
                if (amountInDelta < amount1) {
                    _transferToken(
                        instructions.recipient,
                        IERC20(token1),
                        amount1 - amountInDelta,
                        instructions.unwrap
                    );
                }
                targetAmount += amountOutDelta;
            } else {
                targetAmount += amount1;
            }

            if (targetAmount != 0 && instructions.targetToken != address(0)) {
                if (
                    targetAmount != 0 && instructions.targetToken != address(0)
                ) {
                    _transferToken(
                        instructions.recipient,
                        IERC20(instructions.targetToken),
                        targetAmount,
                        instructions.unwrap
                    );
                }
            }
            emit WithdrawAndCollectAndSwap(
                tokenId,
                instructions.targetToken,
                targetAmount
            );
        } else {
            revert NotSupportedWhatToDo();
        }
    }

    struct SwapAndIncreaseLiquidityParams {
        uint256 tokenId;
        // how much is provided of token0 and token1
        uint256 amount0;
        uint256 amount1;
        address recipient; // recipient of leftover tokens
        uint256 deadline;
        // source token for swaps (maybe either address(0), token0, token1 or another token)
        // if swapSourceToken is another token than token0 or token1 -> amountIn0 + amountIn1 of swapSourceToken are expected to be available
        IERC20 swapSourceToken;
        // if swapSourceToken needs to be swapped to token0 - set values
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        // if swapSourceToken needs to be swapped to token1 - set values
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        // min amount to be added after swap
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        // if permit2 signatures are used - set this
        bytes permitData;
    }

    struct SwapAndMintParams {
        IERC20 token0;
        IERC20 token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        // how much is provided of token0 and token1
        uint256 amount0;
        uint256 amount1;
        address recipient; // recipient of leftover tokens
        address recipientNFT; // recipient of nft
        uint256 deadline;
        // source token for swaps (maybe either address(0), token0, token1 or another token)
        // if swapSourceToken is another token than token0 or token1 -> amountIn0 + amountIn1 of swapSourceToken are expected to be available
        IERC20 swapSourceToken;
        // if swapSourceToken needs to be swapped to token0 - set values
        uint256 amountIn0;
        uint256 amountOut0Min;
        bytes swapData0;
        // if swapSourceToken needs to be swapped to token1 - set values
        uint256 amountIn1;
        uint256 amountOut1Min;
        bytes swapData1;
        // min amount to be added after swap
        uint256 amountAddMin0;
        uint256 amountAddMin1;
        // data to be sent along newly created NFT when transfered to recipientNFT (sent to IERC721Receiver callback)
        bytes returnData;
        // if permit2 signatures are used - set this
        bytes permitData;
    }

    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        if (msg.sender != address(nonfungiblePositionManager)) {
            revert WrongContract();
        }

        if (from == address(this)) {
            revert SelfSend();
        }
        Instructions memory instructions = abi.decode(data, (Instructions));
        execute(tokenId, instructions);

        nonfungiblePositionManager.safeTransferFrom(
            address(this),
            from,
            tokenId,
            instructions.returnData
        );
        return IERC721Receiver.onERC721Received.selector;
    }

    ///
    struct SwapParams {
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient;
        bytes swapData;
        bool unwrap;
        bytes permitData;
    }

    function swap(
        SwapParams calldata params
    ) external payable returns (uint256 amountOut) {
        if (params.tokenIn == params.tokenOut) {
            revert SameToken();
        }
        if (params.permitData.length > 0) {
            (
                ISignatureTransfer.PermitBatchTransferFrom memory pbtf,
                bytes memory signature
            ) = abi.decode(
                    params.permitData,
                    (ISignatureTransfer.PermitBatchTransferFrom, bytes)
                );
            _prepareAddPermit2(
                params.tokenIn,
                IERC20(address(0)),
                IERC20(address(0)),
                params.amountIn,
                0,
                0,
                pbtf,
                signature
            );
        }
    }

    function swapAndMint()
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount
        )
    {}

    function swapAndIncreaseLiquidity()
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {}

    function _prepareAddApproved() internal {}

    struct PrepareAddPermit2State {
        uint256 needed0;
        uint256 needed1;
        uint256 neededOther;
        uint256 i;
        uint256 balanceBefore0;
        uint256 balanceBefore1;
        uint256 balanceBeforOther;
    }

    function _prepareAddPermit2(
        IERC20 token0,
        IERC20 token1,
        IERC20 otherToken,
        uint256 amount0,
        uint256 amount1,
        uint256 amountOther,
        IPermit2.PermitBatchTransferFrom memory permit,
        bytes memory signature
    ) internal {
        PrepareAddPermit2State memory state;

        (state.needed0, state.needed1, state.neededOther) = _prepareAdd(
            token0,
            token1,
            otherToken,
            amount0,
            amount1,
            amountOther
        );
    }

    function _prepareAdd(
        IERC20 token0,
        IERC20 token1,
        IERC20 otherToken,
        uint256 amount0,
        uint256 amount1,
        uint256 amountOther
    ) internal returns (uint256 needed0, uint256 needed1, uint256 neededOther) {
        if (msg.value != 0) {
            weth.deposit{value: msg.value}();
        }
    }

    function _swapAndMint(
        SwapAndMintParams memory params,
        bool unwrap
    )
        internal
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 added0,
            uint256 added1
        )
    {
        (uint256 total0, uint256 total1) = _swapAndPrepareAmounts(
            params,
            unwrap
        );

        INonfungiblePositionManager.MintParams
            memory mintParams = INonfungiblePositionManager.MintParams(
                address(params.token0),
                address(params.token1),
                params.fee,
                params.tickLower,
                params.tickUpper,
                total0,
                total1,
                params.amountAddMin0,
                params.amountAddMin1,
                address(this),
                params.deadline
            );
        (tokenId, liquidity, added0, added1) = nonfungiblePositionManager.mint(
            mintParams
        );
        nonfungiblePositionManager.safeTransferFrom(
            address(this),
            params.recipientNFT,
            tokenId,
            params.returnData
        );

        emit SwapAndMint(tokenId, liquidity, added0, added1);
    }

    function _swapAndIncrease(
        SwapAndIncreaseLiquidityParams memory params,
        IERC20 token0,
        IERC20 token1,
        bool unwrap
    ) internal returns (uint128 liquidity, uint256 added0, uint256 added1) {
        (uint256 total0, uint256 total1) = _swapAndPrepareAmounts(
            SwapAndMintParams(
                token0,
                token1,
                0,
                0,
                0,
                params.amount0,
                params.amount1,
                params.recipient,
                params.recipient,
                params.deadline,
                params.swapSourceToken,
                params.amountIn0,
                params.amountOut0Min,
                params.swapData0,
                params.amountIn1,
                params.amountOut1Min,
                params.swapData1,
                params.amountAddMin0,
                params.amountAddMin1,
                "",
                params.permitData
            ),
            unwrap
        );
        INonfungiblePositionManager.IncreaseLiquidityParams
            memory increaseLiquidityParams = INonfungiblePositionManager
                .IncreaseLiquidityParams(
                    params.tokenId,
                    total0,
                    total1,
                    params.amountAddMin0,
                    params.amountAddMin1,
                    params.deadline
                );
        (liquidity, added0, added1) = nonfungiblePositionManager
            .increaseLiquidity(increaseLiquidityParams);

        emit SwapAndIncreaseLiquidity(
            params.tokenId,
            liquidity,
            added0,
            added1
        );
    }

    function _swapAndPrepareAmounts(
        SwapAndMintParams memory params,
        bool unwrap
    ) internal returns (uint256 total0, uint256 total1) {
        if (params.swapSourceToken == params.token0) {
            if (params.amount0 < params.amountIn1) {
                revert AmountError();
            }
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                Swapper.RouterSwapParams(
                    params.token0,
                    params.token1,
                    params.amountIn1,
                    params.amountOut1Min,
                    params.swapData1
                )
            );
            total0 = params.amount0 - amountInDelta;
            total1 = params.amount1 + amountOutDelta;
        } else if (params.swapSourceToken == params.token1) {
            if (params.amount1 < params.amountIn0) {
                revert AmountError();
            }
            (uint256 amountInDelta, uint256 amountOutDelta) = _routerSwap(
                Swapper.RouterSwapParams(
                    params.token1,
                    params.token0,
                    params.amountIn0,
                    params.amountOut0Min,
                    params.swapData0
                )
            );
            total1 = params.amount1 - amountInDelta;
            total0 = params.amount0 + amountOutDelta;
        } else if (address(params.swapSourceToken) != address(0)) {
            (uint256 amountInDelta0, uint256 amountOutDelta0) = _routerSwap(
                Swapper.RouterSwapParams(
                    params.swapSourceToken,
                    params.token0,
                    params.amountIn0,
                    params.amountOut0Min,
                    params.swapData0
                )
            );
            (uint256 amountInDelta1, uint256 amountOutDelta1) = _routerSwap(
                Swapper.RouterSwapParams(
                    params.swapSourceToken,
                    params.token1,
                    params.amountIn1,
                    params.amountOut1Min,
                    params.swapData1
                )
            );
            total0 = params.amount0 + amountOutDelta0;
            total1 = params.amount1 + amountOutDelta1;

            // return third token leftover if any
            uint256 leftOver = params.amountIn0 +
                params.amountIn1 -
                amountInDelta0 -
                amountInDelta1;

            if (leftOver != 0) {
                _transferToken(
                    params.recipient,
                    params.swapSourceToken,
                    leftOver,
                    unwrap
                );
            }
        } else {
            total0 = params.amount0;
            total1 = params.amount1;
        }

        if (total0 != 0) {
            SafeERC20.safeApprove(
                params.token0,
                address(nonfungiblePositionManager),
                0
            );
            SafeERC20.safeApprove(
                params.token0,
                address(nonfungiblePositionManager),
                total0
            );
        }
        if (total1 != 0) {
            SafeERC20.safeApprove(
                params.token1,
                address(nonfungiblePositionManager),
                0
            );
            SafeERC20.safeApprove(
                params.token1,
                address(nonfungiblePositionManager),
                total1
            );
        }
    }

    function _returnLeftoverTokens(
        address to,
        IERC20 token0,
        IERC20 token1,
        uint256 total0,
        uint256 total1,
        uint256 added0,
        uint256 added1,
        bool unwrap
    ) internal {
        uint256 left0 = total0 - added0;
        uint256 left1 = total1 - added1;

        // return leftovers
        if (left0 != 0) {
            _transferToken(to, token0, left0, unwrap);
        }
        if (left1 != 0) {
            _transferToken(to, token1, left1, unwrap);
        }
    }

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

    function _decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 deadline,
        uint256 token0Min,
        uint256 token1Min
    ) internal returns (uint256 amount0, uint256 amount1) {
        if (liquidity != 0) {
            (amount0, amount1) = nonfungiblePositionManager.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams(
                    tokenId,
                    liquidity,
                    token0Min,
                    token1Min,
                    deadline
                )
            );
        }
    }

    function _collectFees(
        uint256 tokenId,
        IERC20 token0,
        IERC20 token1,
        uint128 collectAmount0,
        uint128 collectAmount1
    ) internal returns (uint256 amount0, uint256 amount1) {
        uint256 balanceBefore0 = token0.balanceOf(address(this));
        uint256 balanceBefore1 = token1.balanceOf(address(this));

        (amount0, amount1) = nonfungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams(
                tokenId,
                address(this),
                collectAmount0,
                collectAmount1
            )
        );
        uint256 balanceAfter0 = token0.balanceOf(address(this));
        uint256 balanceAfter1 = token1.balanceOf(address(this));

        if (balanceAfter0 - balanceBefore0 != amount0) {
            revert CollectError();
        }
        if (balanceAfter1 - balanceBefore1 != amount1) {
            revert CollectError();
        }
    }

    receive() external payable {
        if (msg.sender != address(weth)) {
            revert NotWETH();
        }
    }
}
