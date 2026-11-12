// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console2 } from "forge-std/Script.sol";

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import { DemoVault } from "../src/demo/DemoVault.sol";
import { Deployments } from "./utils/Deployments.sol";

/// @notice Step 7 (destination chain): the delay has passed and the upgrade lands.
/// @dev After this the vault runs the V2 code, which freezes withdrawals. Bob, who had no ExitGuard, is stuck.
contract ExecuteUpgrade is Deployments {
    function run() external {
        TimelockController timelock = TimelockController(payable(_address(DESTINATION_FILE, "timelock")));
        address vault = _address(DESTINATION_FILE, "vault");
        address newCode = _address(DESTINATION_FILE, "vaultV2");

        bytes memory upgrade = abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (newCode, ""));

        vm.startBroadcast();
        timelock.execute(vault, 0, upgrade, bytes32(0), UPGRADE_SALT);
        vm.stopBroadcast();

        console2.log("Vault now runs version", DemoVault(vault).version());
    }
}
