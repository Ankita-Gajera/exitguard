// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ExitGuardReactive } from "../src/ExitGuardReactive.sol";
import { Fixture, SimpleVault } from "./utils/Fixture.sol";
import { SafeLike, CompoundTimelockLike, MetaMorphoLike } from "./mocks/GovernanceLikes.sol";

/// @notice The ready-made tripwires, end to end: contracts that emit the same events as the real governance
///         machinery (a Safe, a Compound timelock, a MetaMorpho vault), and Alice's deposit leaving because of them.
contract PresetsTest is Fixture {
    address internal curator = makeAddr("curator");

    SimpleVault internal vault;

    function setUp() public {
        _deployCore();

        vault = new SimpleVault(IERC20(address(usd)));
        _protect(address(vault));
    }

    /// @dev Alice deposits 1,000 test dollars into `vault_`, lets her guard move the shares, and arms it.
    function _protect(address vault_) internal {
        _deposit(alice, SimpleVault(vault_), 1_000e18);

        vm.startPrank(alice);
        IERC20(vault_).approve(address(guard), type(uint256).max);
        guard.arm(vault_, address(0));
        vm.stopPrank();
    }

    /// @dev Pipes the first `topic0_` log that `emitter_` emitted since `vm.recordLogs()`.
    function _pipeRecorded(address emitter_, bytes32 topic0_) internal returns (uint256) {
        Vm.Log memory entry = _find(vm.getRecordedLogs(), emitter_, topic0_);
        return _pipe(_record(BASE_SEPOLIA, entry));
    }

    function test_Safe_ALowerThresholdTriggersAnExit() public {
        address[] memory signers = new address[](3);
        signers[0] = makeAddr("signer1");
        signers[1] = makeAddr("signer2");
        signers[2] = makeAddr("signer3");

        SafeLike safe = new SafeLike(signers, 2);

        vm.prank(alice);
        reactive.watchSafe(BASE_SEPOLIA, address(safe), address(vault));

        // The multisig that controls the vault drops to one signature.
        vm.recordLogs();
        safe.changeThreshold(1);

        assertEq(_pipeRecorded(address(safe), SafeLike.ChangedThreshold.selector), 1);
        assertEq(usd.balanceOf(alice), 1_000e18, "Alice is out");
    }

    function test_Safe_ANewSignerTriggersAnExitOnce() public {
        address[] memory signers = new address[](2);
        signers[0] = makeAddr("signer1");
        signers[1] = makeAddr("signer2");

        SafeLike safe = new SafeLike(signers, 2);

        vm.prank(alice);
        reactive.watchSafe(BASE_SEPOLIA, address(safe), address(vault));

        // One transaction adds a signer and lowers the threshold: two watched events, one exit.
        vm.recordLogs();
        safe.addOwnerWithThreshold(makeAddr("newSigner"), 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_pipe(_record(BASE_SEPOLIA, _find(logs, address(safe), SafeLike.AddedOwner.selector))), 1);
        assertEq(_pipe(_record(BASE_SEPOLIA, _find(logs, address(safe), SafeLike.ChangedThreshold.selector))), 0);
        assertEq(usd.balanceOf(alice), 1_000e18);

        // Later a signer leaves. Alice is out and disarmed; the cooldown has passed, the guard just skips.
        vm.warp(block.timestamp + 1 hours);
        vm.recordLogs();
        safe.removeLastOwner();

        assertEq(_pipeRecorded(address(safe), SafeLike.RemovedOwner.selector), 1, "the callback is delivered");
        assertEq(usd.balanceOf(alice), 1_000e18, "and changes nothing");
    }

    function test_CompoundTimelock_AQueuedTransactionAgainstTheVaultTriggersAnExit() public {
        CompoundTimelockLike timelock = new CompoundTimelockLike(makeAddr("governor"), 2 days);

        vm.prank(alice);
        reactive.watchCompoundTimelock(BASE_SEPOLIA, address(timelock), address(vault), address(vault));

        // Governance queues something for another contract: Alice stays.
        vm.recordLogs();
        timelock.queueTransaction(makeAddr("treasury"), 0, "sweep()", "");
        assertEq(_pipeRecorded(address(timelock), CompoundTimelockLike.QueueTransaction.selector), 0);
        assertEq(vault.balanceOf(alice), 1_000e18);

        // Governance queues a change to the vault: Alice leaves, two days before it can execute.
        vm.recordLogs();
        timelock.queueTransaction(address(vault), 0, "upgradeTo(address)", abi.encode(makeAddr("newCode")));
        assertEq(_pipeRecorded(address(timelock), CompoundTimelockLike.QueueTransaction.selector), 1);
        assertEq(usd.balanceOf(alice), 1_000e18);
    }

    function test_MetaMorpho_AShorterTimelockTriggersAnExit() public {
        MetaMorphoLike morphoVault = new MetaMorphoLike(IERC20(address(usd)), curator, makeAddr("morpho"), 1 days);
        _protect(address(morphoVault));

        vm.prank(alice);
        (, uint256 count) = reactive.watchMetaMorpho(BASE_SEPOLIA, address(morphoVault), false);
        assertEq(count, 4);

        // A higher cap is routine for Alice.
        vm.recordLogs();
        morphoVault.submitCap(keccak256("market"), 5_000_000e18);
        assertEq(_pipeRecorded(address(morphoVault), MetaMorphoLike.SubmitCap.selector), 0);

        // The curator asks for a shorter timelock, which would mean less warning next time. It takes effect in a
        // day. Alice is out in seconds.
        vm.recordLogs();
        vm.prank(curator);
        morphoVault.submitTimelock(1 hours);

        assertEq(_pipeRecorded(address(morphoVault), MetaMorphoLike.SubmitTimelock.selector), 1);
        assertEq(usd.balanceOf(alice), 1_000e18, "the first vault's deposit is untouched");
        assertEq(morphoVault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(alice), 1_000e18, "only the vault that announced a change is left");
    }

    function test_MetaMorpho_EveryAnnouncedChangeIsATripwire() public {
        MetaMorphoLike morphoVault = new MetaMorphoLike(IERC20(address(usd)), curator, makeAddr("morpho"), 1 days);

        vm.prank(alice);
        reactive.watchMetaMorpho(BASE_SEPOLIA, address(morphoVault), true);

        vm.prank(alice);
        reactive.setCooldown(0);

        vm.startPrank(curator);
        vm.recordLogs();
        morphoVault.submitGuardian(makeAddr("newGuardian"));
        morphoVault.submitMarketRemoval(keccak256("market"));
        morphoVault.submitCap(keccak256("market"), 1);
        morphoVault.setCurator(makeAddr("newCurator"));
        vm.stopPrank();

        Vm.Log[] memory logs = vm.getRecordedLogs();

        _react(_record(BASE_SEPOLIA, _find(logs, address(morphoVault), MetaMorphoLike.SubmitGuardian.selector)));
        _react(_record(BASE_SEPOLIA, _find(logs, address(morphoVault), MetaMorphoLike.SubmitMarketRemoval.selector)));
        _react(_record(BASE_SEPOLIA, _find(logs, address(morphoVault), MetaMorphoLike.SubmitCap.selector)));
        _react(_record(BASE_SEPOLIA, _find(logs, address(morphoVault), MetaMorphoLike.SetCurator.selector)));

        assertEq(system.callbackCount(), 4);
    }
}
