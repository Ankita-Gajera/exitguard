// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC1967 } from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { ERC4626Upgradeable } from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import { IExitGuard } from "../src/interfaces/IExitGuard.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";
import { DemoVaultV2 } from "../src/demo/DemoVaultV2.sol";
import { DemoSister } from "../src/demo/DemoSister.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Fixture } from "./utils/Fixture.sol";

/// @notice The whole story, against real governance machinery: an ERC-4626 vault behind a UUPS proxy, owned by an
///         OpenZeppelin TimelockController. Alice runs ExitGuard. Bob does not.
contract EndToEndTest is Fixture {
    uint256 internal constant TIMELOCK_DELAY = 2 minutes;
    bytes32 internal constant SALT = keccak256("upgrade-1");

    address internal admin = makeAddr("protocolAdmin");
    address internal sister = makeAddr("sisterDeploymentOnEthereum");

    TimelockController internal timelock;
    DemoVault internal vault;
    DemoVaultV2 internal newCode;

    function setUp() public {
        _deployCore();

        address[] memory operators = new address[](1);
        operators[0] = admin;

        timelock = new TimelockController(TIMELOCK_DELAY, operators, operators, address(0));

        DemoVault code = new DemoVault();
        vault = DemoVault(
            address(
                new ERC1967Proxy(
                    address(code), abi.encodeCall(DemoVault.initialize, (IERC20(address(usd)), address(timelock)))
                )
            )
        );
        newCode = new DemoVaultV2();

        _deposit(alice, vault, 1_000e18);
        _deposit(bob, vault, 1_000e18);

        vm.startPrank(alice);
        vault.approve(address(guard), type(uint256).max);
        guard.arm(address(vault), address(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _upgradeCall() internal view returns (bytes memory) {
        return abi.encodeCall(UUPSUpgradeable.upgradeToAndCall, (address(newCode), ""));
    }

    /// @dev The protocol admin queues `call_` against the vault. Returns the logs of that transaction.
    function _schedule(bytes memory call_) internal returns (Vm.Log[] memory logs_) {
        vm.recordLogs();
        vm.prank(admin);
        timelock.schedule(address(vault), 0, call_, bytes32(0), SALT, TIMELOCK_DELAY);
        logs_ = vm.getRecordedLogs();
    }

    /// @dev The delay passes and the protocol admin executes `call_`. Returns the logs of that transaction.
    function _execute(bytes memory call_) internal returns (Vm.Log[] memory logs_) {
        vm.warp(block.timestamp + TIMELOCK_DELAY);
        vm.recordLogs();
        vm.prank(admin);
        timelock.execute(address(vault), 0, call_, bytes32(0), SALT);
        logs_ = vm.getRecordedLogs();
    }

    // ------------------------------------------------------------------------------------------------------------
    // The main story
    // ------------------------------------------------------------------------------------------------------------

    function test_GuardedDepositorLeavesWhenTheUpgradeIsQueued() public {
        vm.startPrank(alice);
        reactive.watchTimelock(BASE_SEPOLIA, address(timelock), address(vault), address(vault));
        reactive.watchProxy(BASE_SEPOLIA, address(vault), address(vault));
        vm.stopPrank();

        // 1. The admin queues an upgrade. The vault still runs the old code.
        Vm.Log[] memory logs = _schedule(_upgradeCall());
        Vm.Log memory queued = _find(logs, address(timelock), TimelockController.CallScheduled.selector);

        // 2. Reactive Network sees the event; ExitGuard pulls Alice out.
        assertEq(_pipe(_record(BASE_SEPOLIA, queued)), 1, "one exit callback");

        assertEq(vault.version(), "1", "the exit ran against the old, known code");
        assertEq(usd.balanceOf(alice), 1_000e18, "Alice has her money back");
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(bob), 1_000e18, "Bob is still in");

        // 3. The delay passes and the upgrade lands. Alice's second tripwire sees it, but she is already out.
        logs = _execute(_upgradeCall());
        Vm.Log memory upgraded = _find(logs, address(vault), IERC1967.Upgraded.selector);

        assertEq(_pipe(_record(BASE_SEPOLIA, upgraded)), 0, "no second callback inside the cooldown");
        assertEq(vault.version(), "2");

        // 4. The new code froze withdrawals. Bob is stuck.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxRedeem.selector, bob, 1_000e18, 0));
        vault.redeem(1_000e18, bob, bob);
    }

    function test_WatchingOnlyTheProxyIsTooLate() public {
        // Alice only watches for the implementation changing, not for the upgrade being queued.
        vm.prank(alice);
        reactive.watchProxy(BASE_SEPOLIA, address(vault), address(vault));

        Vm.Log[] memory logs = _schedule(_upgradeCall());
        Vm.Log memory queued = _find(logs, address(timelock), TimelockController.CallScheduled.selector);

        assertEq(_pipe(_record(BASE_SEPOLIA, queued)), 0, "nothing listens to the timelock");

        logs = _execute(_upgradeCall());
        Vm.Log memory upgraded = _find(logs, address(vault), IERC1967.Upgraded.selector);

        // The tripwire fires, but the hostile code is already live and refuses the redemption.
        _react(_record(BASE_SEPOLIA, upgraded));

        vm.expectEmit(address(guard));
        emit IExitGuard.ExitSkipped(address(vault), reactive.REASON_UPGRADED(), IExitGuard.SkipCause.VaultLimit);

        assertEq(_deliverPending(), 1);

        assertEq(usd.balanceOf(alice), 0);
        assertEq(vault.balanceOf(alice), 1_000e18, "Alice is stuck too: watch the timelock, not just the proxy");

        (bool armed,) = guard.positions(address(vault));
        assertTrue(armed, "still armed in case redemptions reopen");
    }

    function test_OwnershipChangeTriggersAnExit() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(alice);
        reactive.watchOwnership(BASE_SEPOLIA, address(vault), address(vault));

        // The timelock hands the vault to someone else. Whoever that is can now upgrade it at will.
        bytes memory handOver = abi.encodeCall(OwnableUpgradeable.transferOwnership, (newOwner));
        _schedule(handOver);
        Vm.Log[] memory logs = _execute(handOver);
        Vm.Log memory transferred = _find(logs, address(vault), OwnableUpgradeable.OwnershipTransferred.selector);

        assertEq(_pipe(_record(BASE_SEPOLIA, transferred)), 1);

        assertEq(vault.owner(), newOwner);
        assertEq(usd.balanceOf(alice), 1_000e18, "out before the new owner could do anything");
    }

    function test_TroubleOnAnotherChainTriggersAnExitHere() public {
        // The same protocol runs on Ethereum. If that deployment is paused, Alice wants out of this one.
        DemoSister onEthereum = new DemoSister(admin);

        vm.prank(alice);
        reactive.watchPause(ETHEREUM_SEPOLIA, address(onEthereum), address(vault));

        // Incident response on Ethereum.
        vm.recordLogs();
        vm.prank(admin);
        onEthereum.pause();
        Vm.Log memory paused = _find(vm.getRecordedLogs(), address(onEthereum), Pausable.Paused.selector);

        assertEq(_pipe(_record(ETHEREUM_SEPOLIA, paused)), 1, "one exit callback, on this chain");

        assertEq(usd.balanceOf(alice), 1_000e18, "Alice is out before the trouble can reach this deployment");
        assertEq(vault.balanceOf(bob), 1_000e18, "Bob is still in");
        assertEq(vault.version(), "1", "nothing has happened to this vault");

        // The all-clear is not a tripwire.
        vm.recordLogs();
        vm.prank(admin);
        onEthereum.unpause();
        Vm.Log memory unpaused = _find(vm.getRecordedLogs(), address(onEthereum), Pausable.Unpaused.selector);

        assertEq(_pipe(_record(ETHEREUM_SEPOLIA, unpaused)), 0);
    }

    function test_SisterDeployment_OnlyItsGuardianCanPause() public {
        DemoSister onEthereum = new DemoSister(admin);

        vm.expectRevert();
        onEthereum.pause();

        vm.prank(admin);
        onEthereum.pause();
        assertTrue(onEthereum.paused());

        vm.expectRevert();
        onEthereum.unpause();
    }

    function test_ExitGoesToAColdWallet() public {
        vm.startPrank(alice);
        guard.arm(address(vault), coldWallet);
        reactive.watchTimelock(BASE_SEPOLIA, address(timelock), address(vault), address(vault));
        vm.stopPrank();

        Vm.Log[] memory logs = _schedule(_upgradeCall());

        _pipe(_record(BASE_SEPOLIA, _find(logs, address(timelock), TimelockController.CallScheduled.selector)));

        assertEq(usd.balanceOf(coldWallet), 1_000e18);
        assertEq(usd.balanceOf(alice), 0);
    }

    function test_AliceCanComeBackAndBeProtectedAgain() public {
        vm.prank(alice);
        reactive.watchPause(ETHEREUM_SEPOLIA, sister, address(vault));

        bytes32[] memory paused = _topics(bytes32(reactive.TOPIC_PAUSED()));

        // First scare: exit.
        _pipe(_record(ETHEREUM_SEPOLIA, sister, paused, abi.encode(admin)));
        assertEq(usd.balanceOf(alice), 1_000e18);

        // False alarm. A day later Alice deposits again and re-arms; her allowance is still in place.
        vm.warp(block.timestamp + 1 days);

        vm.startPrank(alice);
        usd.approve(address(vault), 1_000e18);
        vault.deposit(1_000e18, alice);
        guard.arm(address(vault), address(0));
        vm.stopPrank();

        // Second scare: exit again.
        _pipe(_record(ETHEREUM_SEPOLIA, sister, paused, abi.encode(admin)));
        assertEq(usd.balanceOf(alice), 1_000e18);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // The health check
    // ------------------------------------------------------------------------------------------------------------

    function test_DrillProvesThePipelineEndToEnd() public {
        vm.startPrank(alice);
        reactive.watchTimelock(BASE_SEPOLIA, address(timelock), address(vault), address(vault));
        reactive.watchProxy(BASE_SEPOLIA, address(vault), address(vault));

        vm.recordLogs();
        uint256 nonce = guard.requestDrill(address(vault));
        vm.stopPrank();

        Vm.Log memory requested = _find(vm.getRecordedLogs(), address(guard), IExitGuard.DrillRequested.selector);

        // Two seconds and ten blocks pass before the answer lands on the destination chain.
        vm.warp(block.timestamp + 2);
        vm.roll(block.number + 10);

        _react(_record(BASE_SEPOLIA, requested));

        vm.expectEmit(address(guard));
        emit IExitGuard.DrillPassed(nonce, address(vault), 3, 2, 10);

        assertEq(_deliverPending(), 1);

        // A drill never touches the position.
        assertEq(vault.balanceOf(alice), 1_000e18);
        (bool armed,) = guard.positions(address(vault));
        assertTrue(armed);
    }
}
