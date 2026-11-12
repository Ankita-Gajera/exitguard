// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console2 } from "forge-std/Script.sol";

import { ExitGuard } from "../src/ExitGuard.sol";
import { Deployments } from "./utils/Deployments.sol";

/// @notice Step 5 (destination chain): prove the pipeline works without touching the position.
/// @dev The guard emits `DrillRequested`; a few seconds later the reactive contract's answer arrives and the guard
///      emits `DrillPassed` with the round-trip time and the number of tripwires guarding the vault. Run the
///      `Status` script afterwards to read the result.
contract Drill is Deployments {
    function run() external {
        ExitGuard guard = ExitGuard(payable(_address(GUARD_FILE, "guard")));
        address vault = _address(DESTINATION_FILE, "vault");

        vm.startBroadcast();
        uint256 nonce = guard.requestDrill(vault);
        vm.stopBroadcast();

        console2.log("Drill requested, nonce", nonce);
    }
}
