// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console2 } from "forge-std/Script.sol";

import { DemoSister } from "../src/demo/DemoSister.sol";
import { Deployments } from "./utils/Deployments.sol";

/// @notice Step 8 (another chain): deploy the demo protocol's sister deployment.
/// @dev Run this against a chain other than the vault's, for example Base Sepolia when the vault is on Ethereum
///      Sepolia. You are its guardian, so you can play the incident response in step 10.
contract DeploySister is Deployments {
    function run() external {
        vm.startBroadcast();

        DemoSister sister = new DemoSister(_broadcaster());

        vm.stopBroadcast();

        vm.createDir(DIR, true);

        string memory json = "sister";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.writeJson(vm.serializeAddress(json, "sister", address(sister)), SISTER_FILE);

        console2.log("Chain            ", block.chainid);
        console2.log("Sister deployment", address(sister));
    }
}
