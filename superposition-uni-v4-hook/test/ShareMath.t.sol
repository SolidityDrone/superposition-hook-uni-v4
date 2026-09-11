// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ShareMath} from "../src/libraries/ShareMath.sol";

contract ShareMathTest is Test {
    function test_first_deposit_is_one_to_one() public pure {
        assertEq(ShareMath.toShares(1000e18, 0, 0), 1000e18);
    }

    function test_second_deposit_into_doubled_vault_mints_half() public pure {
        // Existing: 1000 assets, 1000 shares. Vault doubled to 2000 assets.
        uint256 shares = ShareMath.toShares(1000e18, 2000e18, 1000e18);
        assertApproxEqAbs(shares, 500e18, 1e15);
    }

    function test_redeem_all_assets() public pure {
        uint256 assets = ShareMath.toAssets(1000e18, 2000e18, 1000e18);
        assertApproxEqAbs(assets, 2000e18, 1e15);
    }

    function test_zero_assets_mints_zero() public pure {
        assertEq(ShareMath.toShares(0, 2000e18, 1000e18), 0);
    }
}
