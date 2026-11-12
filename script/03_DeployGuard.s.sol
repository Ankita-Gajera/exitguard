// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console2 } from "forge-std/Script.sol";

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ExitGuard } from "../src/ExitGuard.sol";
import { Deployments } from "./utils/Deployments.sol";

/// @notice Step 3 (destination chain): your guard, armed for the demo vault.
/// @dev Deploys the guard, lets it move your vault shares, and arms the position. `GUARD_FUNDING` (in wei of the
///      chain's native token, default 0.005) pays for callbacks.
contract DeployGuard is Deployments {
    function run() external {
        address reactive = _address(REACTIVE_FILE, "reactive");
        address vault = _address(DESTINATION_FILE, "vault");
        address callbackProxy = _callbackProxy();
        uint256 funding = vm.envOr("GUARD_FUNDING", uint256(0.005 ether));

        vm.startBroadcast();

        address you = _broadcaster();
        ExitGuard guard = new ExitGuard{ value: funding }(IPayable(payable(callbackProxy)), reactive, you);

        IERC20(vault).approve(address(guard), type(uint256).max);
        guard.arm(vault, address(0));

        vm.stopBroadcast();

        string memory json = "guard";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "callbackProxy", callbackProxy);
        vm.writeJson(vm.serializeAddress(json, "guard", address(guard)), GUARD_FILE);

        console2.log("Chain            ", block.chainid);
        console2.log("ExitGuard        ", address(guard));
        console2.log("Callback proxy   ", callbackProxy);
        console2.log("Reactive contract", reactive);
        console2.log("Armed for vault  ", vault);
    }
}
