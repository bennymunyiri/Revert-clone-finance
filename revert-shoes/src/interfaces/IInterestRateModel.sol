// SPDX-License-Identifier: BUSL-1.1
// written-info aderyn.
pragma solidity ^0.8.0;

interface IInterestRateModel {
    // gets borrow and supply interest rate per second
    // notes calculates the borrow rate and supply rate per second
    function getRatesPerSecondX96(
        uint256 cash,
        uint256 debt
    ) external view returns (uint256 borrowRateX96, uint256 supplyRateX96);
}
