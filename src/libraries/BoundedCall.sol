// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title Calls into a contract that may have turned hostile.
/// @notice ExitGuard talks to a vault at the exact moment its code or its owner is changing, so every call into
///         the vault is bounded: a fixed gas budget, at most one word of return data, and a capped copy of revert
///         data. A vault cannot make the guard run out of gas by returning a huge blob.
library BoundedCall {
    /// @notice Static call that expects one 32-byte word back.
    /// @return ok_ False if the target has no code, reverted, or returned less than one word.
    /// @return value_ The returned word (zero when `ok_` is false).
    function staticUint(address target_, bytes memory data_) internal view returns (bool ok_, uint256 value_) {
        if (target_.code.length == 0) {
            return (false, 0);
        }

        assembly ("memory-safe") {
            ok_ := staticcall(gas(), target_, add(data_, 0x20), mload(data_), 0x00, 0x20)

            switch and(ok_, gt(returndatasize(), 0x1f))
            case 1 { value_ := mload(0x00) }
            default { ok_ := 0 }
        }
    }

    /// @notice State-changing call that expects one 32-byte word back.
    /// @param gas_ Upper bound on the gas handed to the target.
    /// @param maxRevertBytes_ Upper bound on the revert data copied into memory.
    /// @return ok_ False if the target has no code or reverted.
    /// @return value_ The returned word (zero if the call failed or returned less than one word).
    /// @return revertData_ Revert data, truncated to `maxRevertBytes_` (empty on success).
    function callUint(address target_, bytes memory data_, uint256 gas_, uint256 maxRevertBytes_)
        internal
        returns (bool ok_, uint256 value_, bytes memory revertData_)
    {
        if (target_.code.length == 0) {
            return (false, 0, "");
        }

        assembly ("memory-safe") {
            ok_ := call(gas_, target_, 0, add(data_, 0x20), mload(data_), 0x00, 0x20)

            switch ok_
            case 1 {
                if gt(returndatasize(), 0x1f) { value_ := mload(0x00) }
            }
            default {
                let size := returndatasize()
                if gt(size, maxRevertBytes_) { size := maxRevertBytes_ }

                revertData_ := mload(0x40)
                mstore(revertData_, size)
                returndatacopy(add(revertData_, 0x20), 0x00, size)
                mstore(0x40, and(add(add(revertData_, 0x20), add(size, 0x1f)), not(0x1f)))
            }
        }
    }
}
