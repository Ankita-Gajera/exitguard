// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice Test double for a Reactive Network callback proxy on a destination chain.
/// @dev Does the one thing that matters for authentication: it overwrites the first argument of the payload with
///      the address of the reactive contract that requested the callback, then calls the recipient.
contract MockCallbackProxy {
    mapping(address account => uint256 amount) public debt;

    receive() external payable { }

    /// @param reactive_ Reactive contract that requested the callback.
    /// @param recipient_ Callback contract to call.
    /// @param gasLimit_ Gas handed to the recipient.
    /// @param payload_ ABI-encoded call whose first argument is an `address` placeholder.
    function deliver(address reactive_, address recipient_, uint64 gasLimit_, bytes memory payload_)
        external
        returns (bool success_, bytes memory result_)
    {
        // Layout: 32-byte length, 4-byte selector, then the first argument word.
        assembly ("memory-safe") {
            mstore(add(payload_, 0x24), reactive_)
        }

        (success_, result_) = recipient_.call{ gas: gasLimit_ }(payload_);
    }

    function setDebt(address account_, uint256 amount_) external {
        debt[account_] = amount_;
    }
}
