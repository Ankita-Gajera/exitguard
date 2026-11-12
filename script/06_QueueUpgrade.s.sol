// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console2 } from "forge-std/Script.sol";

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { Deployments } from "./utils/Deployments.sol";

/// @notice Step 6 (destination chain): the protocol queues an upgrade of the vault.
/// @dev This is the event ExitGuard is waiting for. The timelock emits `CallScheduled`; within seconds your shares
///      should be redeemed back to you, while the vault still runs the old code.
contract QueueUpgrade is Deployments {
    function run() external {
        TimelockController timelock = TimelockController(payable(_address(DESTINATION_FILE, "timelock")));
        address vault = _address(DESTINATION_FILE, "vault");
        address newCode = _address(DESTINATION_FILE, "vaultV2");

        bytes memory upgrade = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newCode, ""));
        uint256 delay = timelock.getMinDelay();

        vm.startBroadcast();
        timelock.schedule(vault, 0, upgrade, bytes32(0), UPGRADE_SALT, delay);
        vm.stopBroadcast();

        console2.log("Upgrade queued. Executable in (seconds)", delay);
    }
}
