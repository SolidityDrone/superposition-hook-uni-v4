// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ShareMath
/// @notice ERC-4626 style share conversion with virtual offsets.
/// @dev The virtual offsets bound the empty-vault donation/inflation attack.
library ShareMath {
    uint256 internal constant VIRTUAL_SHARES = 1e3;
    uint256 internal constant VIRTUAL_ASSETS = 1e3;

    function toShares(uint256 assets, uint256 totalAssetsBefore, uint256 totalShares)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(assets, totalShares + VIRTUAL_SHARES, totalAssetsBefore + VIRTUAL_ASSETS);
    }

    function toAssets(uint256 shares, uint256 totalAssets, uint256 totalSupply) internal pure returns (uint256) {
        return Math.mulDiv(shares, totalAssets + VIRTUAL_ASSETS, totalSupply + VIRTUAL_SHARES);
    }
}
