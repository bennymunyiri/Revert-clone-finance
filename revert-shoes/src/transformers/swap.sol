//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

import "permit2/interfaces/IPermit2.sol";

import "../utils/Swapper.sol";

abstract contract Swap is Swapper {
    // Invariants
    IPermit2 public immutable permit2;

    constructor(
        INonfungiblePositionManager _nonfungiblePositionManager,
        address _zeroxRouter,
        address _universalRouter,
        address _permit2
    ) Swapper(_nonfungiblePositionManager, _zeroxRouter, _universalRouter) {
        permit2 = IPermit2(_permit2);
    }

    struct SwapParams {
        IERC20 tokenIn;
        IERC20 tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        address recipient; // recipient of tokenOut and leftover tokenIn (if any leftover)
        bytes swapData;
        bool unwrap; // if tokenIn or tokenOut is WETH - unwrap
        bytes permitData; // if permit2 signatures are used - set this
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
        } else {
            _prepareAddApproved(
                params.tokenIn,
                IERC20(address(0)),
                IERC20(address(0)),
                params.amountIn,
                0,
                0
            );
        }
        uint256 amountInDelta;
        (amountInDelta, amountOut) = _routerSwap(
            Swapper.RouterSwapParams(
                params.tokenIn,
                params.tokenOut,
                params.amountIn,
                params.minAmountOut,
                params.swapData
            )
        );
        // send swapped amount of tokenOut
        if (amountOut != 0) {
            _transferToken(
                params.recipient,
                params.tokenOut,
                amountOut,
                params.unwrap
            );
        }

        // if not all was swapped - return leftovers of tokenIn
        uint256 leftOver = params.amountIn - amountInDelta;
        if (leftOver != 0) {
            _transferToken(
                params.recipient,
                params.tokenIn,
                leftOver,
                params.unwrap
            );
        }
    }

    struct PrepareAddPermit2State {
        uint256 needed0;
        uint256 needed1;
        uint256 neededOther;
        uint256 i;
        uint256 balanceBefore0;
        uint256 balanceBefore1;
        uint256 balanceBeforeOther;
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
        ISignatureTransfer.SignatureTransferDetails[]
            memory transferDetails = new ISignatureTransfer.SignatureTransferDetails[](
                permit.permitted.length
            );

        if (state.needed0 > 0) {
            state.balanceBefore0 = token0.balanceOf(address(this));
            transferDetails[state.i++] = ISignatureTransfer
                .SignatureTransferDetails(address(this), state.needed0);
        }
        if (state.needed1 > 0) {
            state.balanceBefore1 = token1.balanceOf(address(this));
            transferDetails[state.i++] = ISignatureTransfer
                .SignatureTransferDetails(address(this), state.needed1);
        }
        if (state.neededOther > 0) {
            state.balanceBeforeOther = otherToken.balanceOf(address(this));
            transferDetails[state.i++] = ISignatureTransfer
                .SignatureTransferDetails(address(this), state.neededOther);
        }
        permit2.permitTransferFrom(
            permit,
            transferDetails,
            msg.sender,
            signature
        );
        if (state.needed0 > 0) {
            if (
                token0.balanceOf(address(this)) - state.balanceBefore0 !=
                state.needed0
            ) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
        }
        if (state.needed1 > 0) {
            if (
                token1.balanceOf(address(this)) - state.balanceBefore1 !=
                state.needed1
            ) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
        }
        if (state.neededOther > 0) {
            if (
                otherToken.balanceOf(address(this)) -
                    state.balanceBeforeOther !=
                state.neededOther
            ) {
                revert TransferError(); // reverts for fee-on-transfer tokens
            }
        }
    }

    function _prepareAdd(
        IERC20 token0,
        IERC20 token1,
        IERC20 otherToken,
        uint256 amount0,
        uint256 amount1,
        uint256 amountOther
    ) internal returns (uint256 needed0, uint256 needed1, uint256 neededOther) {
        uint256 amountAdded0;
        uint256 amountAdded1;
        uint256 amountAddedOther;

        // wrap ether sent
        if (msg.value != 0) {
            weth.deposit{value: msg.value}();

            if (address(weth) == address(token0)) {
                amountAdded0 = msg.value;
                if (amountAdded0 > amount0) {
                    revert TooMuchEtherSent();
                }
            } else if (address(weth) == address(token1)) {
                amountAdded1 = msg.value;
                if (amountAdded1 > amount1) {
                    revert TooMuchEtherSent();
                }
            } else if (address(weth) == address(otherToken)) {
                amountAddedOther = msg.value;
                if (amountAddedOther > amountOther) {
                    revert TooMuchEtherSent();
                }
            } else {
                revert NoEtherToken();
            }
        }

        // calculate missing token amounts
        if (amount0 > amountAdded0) {
            needed0 = amount0 - amountAdded0;
        }
        if (amount1 > amountAdded1) {
            needed1 = amount1 - amountAdded1;
        }
        if (
            amountOther > amountAddedOther &&
            address(otherToken) != address(0) &&
            token0 != otherToken &&
            token1 != otherToken
        ) {
            neededOther = amountOther - amountAddedOther;
        }
    }

    function _prepareAddApproved(
        IERC20 token0,
        IERC20 token1,
        IERC20 otherToken,
        uint256 amount0,
        uint256 amount1,
        uint256 amountOther
    ) internal {
        (uint256 needed0, uint256 needed1, uint256 neededOther) = _prepareAdd(
            token0,
            token1,
            otherToken,
            amount0,
            amount1,
            amountOther
        );
        if (needed0 > 0) {
            SafeERC20.safeTransferFrom(
                token0,
                msg.sender,
                address(this),
                needed0
            );
        }
        if (needed1 > 0) {
            SafeERC20.safeTransferFrom(
                token1,
                msg.sender,
                address(this),
                needed1
            );
        }
        if (neededOther > 0) {
            SafeERC20.safeTransferFrom(
                otherToken,
                msg.sender,
                address(this),
                neededOther
            );
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
}
