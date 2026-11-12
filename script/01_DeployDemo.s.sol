// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console2 } from "forge-std/Script.sol";

import { DemoDeployer } from "../src/demo/DemoDeployer.sol";
import { Deployments } from "./utils/Deployments.sol";

/// @notice Step 1 (destination chain, e.g. Base Sepolia): the protocol being watched.
/// @dev One transaction (see `DemoDeployer`): test dollars, a timelock, an upgradeable ERC-4626 vault owned by
///      that timelock, the "bad" implementation the demo will upgrade to, and two deposits of 1,000 test dollars:
///      one for you, one for Bob, a depositor who does not run ExitGuard.
contract DeployDemo is Deployments {
    /// @dev Stand-in for a depositor without ExitGuard. Nobody holds this key; that is the point.
    address internal constant BOB = 0x0000000000000000000000000000000000000B0b;

    function run() external {
        uint256 delay = vm.envOr("TIMELOCK_DELAY", uint256(120));

        vm.startBroadcast();

        address you = _broadcaster();

        DemoDeployer demo = new DemoDeployer(delay, you, BOB);

        vm.stopBroadcast();

        vm.createDir(DIR, true);

        string memory json = "destination";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "owner", you);
        vm.serializeAddress(json, "bob", BOB);
        vm.serializeAddress(json, "usd", address(demo.usd()));
        vm.serializeAddress(json, "timelock", address(demo.timelock()));
        vm.serializeAddress(json, "vault", address(demo.vault()));
        vm.serializeUint(json, "timelockDelay", delay);
        vm.writeJson(vm.serializeAddress(json, "vaultV2", address(demo.vaultV2())), DESTINATION_FILE);

        console2.log("Chain            ", block.chainid);
        console2.log("You              ", you);
        console2.log("MockUSD          ", address(demo.usd()));
        console2.log("Timelock         ", address(demo.timelock()));
        console2.log("Vault (proxy)    ", address(demo.vault()));
        console2.log("Vault V2 code    ", address(demo.vaultV2()));
        console2.log("Your vault shares", demo.vault().balanceOf(you));
        console2.log("Bob's vault shares", demo.vault().balanceOf(BOB));
    }
}
