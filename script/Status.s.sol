// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { console2 } from "forge-std/Script.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC4626 } from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import { ExitGuard } from "../src/ExitGuard.sol";
import { IExitGuard } from "../src/interfaces/IExitGuard.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { Deployments } from "./utils/Deployments.sol";

/// @notice Read-only report from the destination chain: where the money is, whether the guard is ready, and the
///         result of the latest drill. Sends no transactions.
contract Status is Deployments {
    function run() external view {
        address you = _address(DESTINATION_FILE, "owner");
        address bob = _address(DESTINATION_FILE, "bob");
        address usd = _address(DESTINATION_FILE, "usd");
        address vault = _address(DESTINATION_FILE, "vault");
        ExitGuard guard = ExitGuard(payable(_address(GUARD_FILE, "guard")));

        console2.log("== Vault ==");
        console2.log("Code version             ", DemoVault(vault).version());
        console2.log("Your test dollars        ", IERC20(usd).balanceOf(you));
        console2.log("Your vault shares        ", IERC20(vault).balanceOf(you));
        console2.log("Bob's vault shares       ", IERC20(vault).balanceOf(bob));
        console2.log("Bob can redeem right now ", IERC4626(vault).maxRedeem(bob));

        (bool armed, address receiver, uint256 shares, uint256 assets, IExitGuard.SkipCause blocker) =
            guard.readiness(vault);

        console2.log("== Guard ==");
        console2.log("Armed                    ", armed);
        console2.log("Receiver                 ", receiver);
        console2.log("Shares it could redeem   ", shares);
        console2.log("Worth (test dollars)     ", assets);

        if (shares == 0) {
            console2.log("Why nothing to redeem    ", _describe(blocker));
        }

        console2.log("Gas money held (wei)     ", address(guard).balance);
        console2.log("Debt to callback proxy   ", guard._SERVICE_PROVIDER().debt(address(guard)));

        uint256 nonce = guard.drillCount();

        console2.log("== Latest drill ==");

        if (nonce == 0) {
            console2.log("No drill requested yet");
            return;
        }

        (,, uint64 secondsElapsed, uint64 blocksElapsed,, uint64 tripwires, bool passed) = guard.drills(nonce);

        console2.log("Nonce                    ", nonce);
        console2.log("Answered                 ", passed);

        if (passed) {
            console2.log("Round trip (seconds)     ", secondsElapsed);
            console2.log("Round trip (blocks)      ", blocksElapsed);
            console2.log("Tripwires on this vault  ", tripwires);
        }
    }

    function _describe(IExitGuard.SkipCause cause_) internal pure returns (string memory) {
        if (cause_ == IExitGuard.SkipCause.NotArmed) return "position is not armed";
        if (cause_ == IExitGuard.SkipCause.NoShares) return "you hold no shares";
        if (cause_ == IExitGuard.SkipCause.NoAllowance) return "the guard has no allowance on your shares";
        return "the vault reports nothing can be redeemed";
    }
}
