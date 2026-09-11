// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Minimal subset of the Aave v3 Pool used by the hook.
interface IAavePool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}
