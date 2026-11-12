// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console2 } from "forge-std/Script.sol";

import { ExitGuardReactive } from "../src/ExitGuardReactive.sol";
import { Deployments } from "./utils/Deployments.sol";

/// @notice Step 9 (Reactive Network): lay a tripwire across chains.
/// @dev If the sister deployment is paused on its chain, leave the vault on this one.
contract WatchSister is Deployments {
    function run() external {
        ExitGuardReactive reactive = ExitGuardReactive(payable(_address(REACTIVE_FILE, "reactive")));
        address vault = _address(DESTINATION_FILE, "vault");
        address sister = _address(SISTER_FILE, "sister");
        uint64 sisterChainId = uint64(_uint(SISTER_FILE, "chainId"));

        vm.startBroadcast();
        uint256 id = reactive.watchPause(sisterChainId, sister, vault);
        vm.stopBroadcast();

        console2.log("Watching chain         ", sisterChainId);
        console2.log("Tripwire: sister paused", id);
    }
}
