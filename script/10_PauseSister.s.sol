// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console2 } from "forge-std/Script.sol";

import { DemoSister } from "../src/demo/DemoSister.sol";
import { Deployments } from "./utils/Deployments.sol";

/// @notice Step 10 (the sister's chain): an incident. The protocol pauses its deployment there.
/// @dev The `Paused` event is the tripwire. Run the `Status` script against the vault's chain a few seconds
///      later: your shares have been redeemed, although nothing has happened to the vault itself.
contract PauseSister is Deployments {
    function run() external {
        DemoSister sister = DemoSister(_address(SISTER_FILE, "sister"));

        vm.startBroadcast();
        sister.pause();
        vm.stopBroadcast();

        console2.log("Sister deployment paused", address(sister));
    }
}
