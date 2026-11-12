// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DemoVault } from "./DemoVault.sol";

/// @title The upgrade nobody wanted: withdrawals are frozen.
/// @notice Shows what a depositor without ExitGuard is left with once the new code is live. Testnet only.
contract DemoVaultV2 is DemoVault {
    /// @inheritdoc DemoVault
    function version() external pure override returns (string memory) {
        return "2";
    }

    /// @notice Nobody can redeem any more.
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    /// @notice Nobody can withdraw any more.
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }
}
