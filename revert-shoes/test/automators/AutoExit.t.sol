// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./../AutomatorIntegrationTestBase.sol";

import "../../../src/automators/AutoExit.sol";
import "../../../src/interfaces/IErrors.sol";

contract AutoExitTest is AutomatorIntegrationTestBase {
    AutoExit autoExit;

    function setUp() external {
        _setupBase();
        autoExit = new AutoExit(
            NPM,
            OPERATOR_ACCOUNT,
            WITHDRAWER_ACCOUNT,
            60,
            100,
            EX0x,
            UNIVERSAL_ROUTER
        );
    }

    function _setConfig(
        uint256 tokenId,
        bool isActive,
        bool token0Swap,
        bool token1Swap,
        uint64 token0SlippageX64,
        uint64 token1SlippageX64,
        int24 token0TriggerTick,
        int24 token1TriggerTick,
        bool onlyFees
    ) internal {
        AutoExit.PositionConfig memory config = AutoExit.PositionConfig(
            isActive,
            token0Swap,
            token1Swap,
            token0TriggerTick,
            token1TriggerTick,
            token0SlippageX64,
            token1SlippageX64,
            onlyFees,
            onlyFees ? MAX_FEE_REWARD : MAX_REWARD
        );

        vm.prank(TEST_NFT_ACCOUNT);
        autoExit.configToken(tokenId, config);
    }

    function testNoLiquidity() external {
        _setConfig(
            TEST_NFT,
            true,
            false,
            false,
            0,
            0,
            type(int24).min,
            type(int24).max,
            false
        );

        (, , , , , , , uint128 liquidity, , , , ) = NPM.positions(TEST_NFT);

        assertEq(liquidity, 0);

        vm.expectRevert(IErrors.NoLiquidity.selector);
        vm.prank(OPERATOR_ACCOUNT);
        autoExit.execute(
            AutoExit.ExecuteParams(
                TEST_NFT,
                "",
                liquidity,
                0,
                0,
                block.timestamp,
                MAX_REWARD
            )
        );
    }
}
