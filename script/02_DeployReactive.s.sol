// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console2 } from "forge-std/Script.sol";

import { ExitGuardReactive } from "../src/ExitGuardReactive.sol";
import { Deployments } from "./utils/Deployments.sol";

/// @notice Step 2 (Reactive Network, e.g. Lasna): your reactive contract.
/// @dev Deployed before the guard because the guard needs this address in its constructor. `REACTIVE_FUNDING`
///      (in wei of REACT, default 0.5) pays for reactive transactions.
contract DeployReactive is Deployments {
    function run() external {
        uint256 destinationChainId = _uint(DESTINATION_FILE, "chainId");
        uint256 funding = vm.envOr("REACTIVE_FUNDING", uint256(0.5 ether));

        vm.startBroadcast();

        address you = _broadcaster();
        ExitGuardReactive reactive = new ExitGuardReactive{ value: funding }(you, destinationChainId);

        vm.stopBroadcast();

        vm.createDir(DIR, true);

        string memory json = "reactive";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "owner", you);
        vm.writeJson(vm.serializeAddress(json, "reactive", address(reactive)), REACTIVE_FILE);

        console2.log("Chain              ", block.chainid);
        console2.log("ExitGuardReactive  ", address(reactive));
        console2.log("Destination chain  ", destinationChainId);
        console2.log("Funded with (wei)  ", funding);
    }
}
