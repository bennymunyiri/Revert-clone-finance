// SPDX-License-Identifier: BUSL-1.1
// @audit-aderyn.
pragma solidity ^0.8.0;

// notes this interface returns the  price of a token for nft providier
interface IV3Oracle {
    // gets value and prices for a given v3 nft denominated in token
    // reverts if any involved token is not configured
    // reverts if prices are not valid given oracle configuration
    function getValue(
        uint256 tokenId,
        // q which is this token?
        address token
    )
        external
        view
        returns (
            uint256 value,
            uint256 feeValue,
            uint256 price0X96,
            uint256 price1X96
        );

    // gets breakdown of position specifying liquidity amounts and available fee amounts
    // notes returns the breakdown of a nft its contents
    function getPositionBreakdown(
        uint256 tokenId
    )
        external
        view
        returns (
            address token0,
            address token1,
            uint24 fee,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            uint128 fees0,
            uint128 fees1
        );
}
