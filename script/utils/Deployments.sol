// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script } from "forge-std/Script.sol";

/// @notice Shared plumbing for the demo scripts: where addresses are stored between steps, and which callback
///         proxy belongs to which chain.
/// @dev Each step writes a small JSON file under `deployments/`; later steps read what they need from there, so
///      nothing has to be copied by hand between the two networks.
abstract contract Deployments is Script {
    string internal constant DIR = "deployments";
    string internal constant DESTINATION_FILE = "deployments/destination.json";
    string internal constant REACTIVE_FILE = "deployments/reactive.json";
    string internal constant GUARD_FILE = "deployments/guard.json";
    string internal constant SISTER_FILE = "deployments/sister.json";

    /// @dev Salt of the demo's timelock operation, so queue and execute refer to the same one.
    bytes32 internal constant UPGRADE_SALT = keccak256("exitguard-demo-upgrade");

    error UnknownChain(uint256 chainId);

    function _address(string memory file_, string memory key_) internal view returns (address) {
        // Reads only the files this project wrote under `deployments/` (see `fs_permissions` in foundry.toml).
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return vm.parseJsonAddress(vm.readFile(file_), string.concat(".", key_));
    }

    function _uint(string memory file_, string memory key_) internal view returns (uint256) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        return vm.parseJsonUint(vm.readFile(file_), string.concat(".", key_));
    }

    /// @dev The account whose key signs the broadcast transactions.
    function _broadcaster() internal view returns (address broadcaster_) {
        (, broadcaster_,) = vm.readCallers();
    }

    /// @dev Reactive Network callback proxy on the current chain. `CALLBACK_PROXY` overrides the built-in list
    ///      (see https://dev.reactive.network/origins-and-destinations).
    function _callbackProxy() internal view returns (address proxy_) {
        proxy_ = vm.envOr("CALLBACK_PROXY", address(0));

        if (proxy_ != address(0)) {
            return proxy_;
        }

        if (block.chainid == 84532) return 0x476F44b11F5C942c58f4c8E3d0300E5710743585; // Base Sepolia
        if (block.chainid == 11155111) return 0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4; // Ethereum Sepolia
        if (block.chainid == 1301) return 0x775c9B990ADe401060B78D0e98684eEf8d2466C1; // Unichain Sepolia

        revert UnknownChain(block.chainid);
    }
}
