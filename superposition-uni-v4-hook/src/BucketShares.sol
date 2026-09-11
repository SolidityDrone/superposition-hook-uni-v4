// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/// @title BucketShares
/// @notice ERC-1155 share tokens for `SuperpositionHook` buckets: one id per tick range.
/// @dev The hook is the only minter/burner. Shares are transferable and support ERC-1155
///      `setApprovalForAll`, so an approved delegate contract can withdraw on the owner's behalf.
///      The id is `uint256(keccak256(abi.encodePacked(tickLower, tickUpper)))`.
contract BucketShares is ERC1155 {
    /// @notice Thrown when a non-hook address tries to mint or burn.
    error OnlyHook();

    /// @notice The hook allowed to mint and burn shares.
    address public immutable hook;

    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    /// @param uri_ Metadata URI (optional).
    /// @param hook_ The SuperpositionHook address.
    constructor(string memory uri_, address hook_) ERC1155(uri_) {
        hook = hook_;
    }

    /// @notice Mints `amount` shares of bucket `id` to `to`. Hook only.
    function mint(address to, uint256 id, uint256 amount) external onlyHook {
        _mint(to, id, amount, "");
    }

    /// @notice Burns `amount` shares of bucket `id` from `from`. Hook only.
    function burn(address from, uint256 id, uint256 amount) external onlyHook {
        _burn(from, id, amount);
    }
}
