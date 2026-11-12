// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @notice A vault that misbehaves on redemption, for testing how ExitGuard copes with code it cannot trust.
/// @dev Only the handful of ERC-20 / ERC-4626 methods the guard touches are implemented.
contract HostileVault {
    enum Mode {
        Revert, // `redeem` reverts with a custom error
        BurnGas, // `redeem` loops until it runs out of gas
        RevertBomb, // `redeem` reverts with a very large blob of data
        ReturnNothing, // `redeem` succeeds but returns no data
        NoLimitMethod // `maxRedeem` does not exist; `redeem` works
    }

    error Frozen(address caller);

    Mode public mode;
    uint256 public redeemCalls;

    mapping(address account => uint256 shares) public balanceOf;
    mapping(address account => mapping(address spender => uint256 amount)) public allowance;

    constructor(Mode mode_) {
        mode = mode_;
    }

    function setBalance(address account_, uint256 shares_) external {
        balanceOf[account_] = shares_;
    }

    function approve(address spender_, uint256 amount_) external returns (bool) {
        allowance[msg.sender][spender_] = amount_;
        return true;
    }

    function maxRedeem(address account_) external view returns (uint256) {
        if (mode == Mode.NoLimitMethod) {
            // Behave like a contract that has no such method.
            assembly ("memory-safe") {
                revert(0, 0)
            }
        }

        return balanceOf[account_];
    }

    function previewRedeem(uint256 shares_) external pure returns (uint256) {
        return shares_;
    }

    function redeem(uint256 shares_, address, address owner_) external returns (uint256) {
        ++redeemCalls;

        if (mode == Mode.Revert) {
            revert Frozen(msg.sender);
        }

        if (mode == Mode.BurnGas) {
            uint256 sink;

            while (true) {
                unchecked {
                    ++sink;
                }
            }
        }

        if (mode == Mode.RevertBomb) {
            assembly ("memory-safe") {
                revert(0, 0x8000)
            }
        }

        balanceOf[owner_] -= shares_;

        if (mode == Mode.ReturnNothing) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }

        return shares_;
    }
}
