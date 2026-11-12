// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console2 } from "forge-std/Script.sol";

import { ExitGuardReactive } from "../src/ExitGuardReactive.sol";
import { Deployments } from "./utils/Deployments.sol";

/// @notice Step 4 (Reactive Network): link the reactive contract to the guard and lay the tripwires.
/// @dev Three tripwires for the demo vault: the timelock queueing any call against it (the early warning), its
///      implementation changing, and its proxy admin changing.
contract LayTripwires is Deployments {
    function run() external {
        ExitGuardReactive reactive = ExitGuardReactive(payable(_address(REACTIVE_FILE, "reactive")));
        address guard = _address(GUARD_FILE, "guard");
        address timelock = _address(DESTINATION_FILE, "timelock");
        address vault = _address(DESTINATION_FILE, "vault");
        uint64 chainId = uint64(_uint(DESTINATION_FILE, "chainId"));

        vm.startBroadcast();

        reactive.setGuard(guard);
        uint256 queuedId = reactive.watchTimelock(chainId, timelock, vault, vault);
        (uint256 upgradedId, uint256 adminChangedId) = reactive.watchProxy(chainId, vault, vault);

        vm.stopBroadcast();

        console2.log("Guard linked           ", guard);
        console2.log("Tripwire: call queued  ", queuedId);
        console2.log("Tripwire: upgraded     ", upgradedId);
        console2.log("Tripwire: admin changed", adminChangedId);
    }
}
