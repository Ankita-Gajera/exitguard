// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Vm } from "forge-std/Test.sol";

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { ExitGuard } from "../src/ExitGuard.sol";
import { IExitGuard } from "../src/interfaces/IExitGuard.sol";
import { Fixture, SimpleVault } from "./utils/Fixture.sol";
import { HostileVault } from "./mocks/HostileVault.sol";

/// @notice A well-formed vault whose redemptions are switched off.
contract FrozenVault is SimpleVault {
    constructor(IERC20 asset_) SimpleVault(asset_) { }

    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }
}

contract ExitGuardTest is Fixture {
    uint8 internal constant REASON = 1;
    uint256 internal constant ORIGIN_TX = 0xabc;

    SimpleVault internal vault;

    function setUp() public {
        _deployCore();
        vault = new SimpleVault(IERC20(address(usd)));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Alice deposits, lets the guard move her shares, and arms the position.
    function _protect(uint256 assets_) internal returns (uint256 shares_) {
        shares_ = _deposit(alice, vault, assets_);

        vm.startPrank(alice);
        vault.approve(address(guard), type(uint256).max);
        guard.arm(address(vault), address(0));
        vm.stopPrank();
    }

    /// @dev Alice holds `shares_` of a hostile vault, lets the guard move them, and arms the position.
    function _protectHostile(HostileVault.Mode mode_, uint256 shares_) internal returns (HostileVault hostile_) {
        hostile_ = new HostileVault(mode_);
        hostile_.setBalance(alice, shares_);

        vm.startPrank(alice);
        hostile_.approve(address(guard), type(uint256).max);
        guard.arm(address(hostile_), address(0));
        vm.stopPrank();
    }

    /// @dev The callback proxy delivers an `exit` callback requested by the owner's reactive contract.
    function _exit(address vault_) internal returns (bool success_, bytes memory result_) {
        return proxy.deliver(
            address(reactive),
            address(guard),
            DEFAULT_CALLBACK_GAS,
            abi.encodeCall(IExitGuard.exit, (address(0), vault_, REASON, ETHEREUM_SEPOLIA, ORIGIN_TX))
        );
    }

    function _armed(address vault_) internal view returns (bool armed_) {
        (armed_,) = guard.positions(vault_);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------------------------------------------------

    function test_Constructor_SetsRolesAndKeepsFunds() public view {
        assertEq(guard.owner(), alice);
        assertEq(guard._CALLBACK_SENDER(), address(reactive));
        assertEq(address(guard._SERVICE_PROVIDER()), address(proxy));
        assertEq(address(guard).balance, 0.1 ether);
    }

    function test_Constructor_RejectsZeroAddresses() public {
        IPayable callbackProxy = IPayable(payable(address(proxy)));

        vm.expectRevert(ExitGuard.ZeroAddress.selector);
        new ExitGuard(IPayable(payable(address(0))), address(reactive), alice);

        vm.expectRevert(ExitGuard.ZeroAddress.selector);
        new ExitGuard(callbackProxy, address(0), alice);

        vm.expectRevert(ExitGuard.ZeroAddress.selector);
        new ExitGuard(callbackProxy, address(reactive), address(0));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Arming
    // ------------------------------------------------------------------------------------------------------------

    function test_Arm_DefaultsReceiverToOwner() public {
        vm.expectEmit(address(guard));
        emit IExitGuard.Armed(address(vault), alice);

        vm.prank(alice);
        guard.arm(address(vault), address(0));

        (bool armed, address receiver) = guard.positions(address(vault));
        assertTrue(armed);
        assertEq(receiver, alice);
    }

    function test_Arm_AcceptsAnotherReceiver() public {
        vm.prank(alice);
        guard.arm(address(vault), coldWallet);

        (, address receiver) = guard.positions(address(vault));
        assertEq(receiver, coldWallet);
    }

    function test_Arm_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(ExitGuard.NotOwner.selector);
        guard.arm(address(vault), address(0));
    }

    function test_Arm_RejectsZeroVault() public {
        vm.prank(alice);
        vm.expectRevert(ExitGuard.ZeroAddress.selector);
        guard.arm(address(0), address(0));
    }

    function test_Arm_RejectsReceiversThatWouldTrapFunds() public {
        vm.startPrank(alice);

        vm.expectRevert(ExitGuard.InvalidReceiver.selector);
        guard.arm(address(vault), address(guard));

        vm.expectRevert(ExitGuard.InvalidReceiver.selector);
        guard.arm(address(vault), address(vault));

        vm.stopPrank();
    }

    function test_Disarm_StopsProtection() public {
        _protect(1_000e18);

        vm.expectEmit(address(guard));
        emit IExitGuard.Disarmed(address(vault));

        vm.prank(alice);
        guard.disarm(address(vault));

        assertFalse(_armed(address(vault)));
    }

    function test_Disarm_OnlyOwner() public {
        _protect(1_000e18);

        vm.prank(stranger);
        vm.expectRevert(ExitGuard.NotOwner.selector);
        guard.disarm(address(vault));
    }

    function test_Disarm_RevertsWhenNotArmed() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExitGuard.NotArmed.selector, address(vault)));
        guard.disarm(address(vault));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Exit: who may trigger it
    // ------------------------------------------------------------------------------------------------------------

    function test_Exit_RejectsDirectCalls() public {
        _protect(1_000e18);

        // Even the owner cannot call the callback entry point directly, let alone a stranger.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, address(proxy)));
        guard.exit(address(reactive), address(vault), REASON, ETHEREUM_SEPOLIA, ORIGIN_TX);

        assertEq(vault.balanceOf(alice), 1_000e18);
    }

    function test_Exit_RejectsCallbacksFromOtherReactiveContracts() public {
        _protect(1_000e18);

        // Someone else's reactive contract asks the proxy to call this guard.
        (bool success, bytes memory result) = proxy.deliver(
            stranger,
            address(guard),
            DEFAULT_CALLBACK_GAS,
            abi.encodeCall(IExitGuard.exit, (address(0), address(vault), REASON, ETHEREUM_SEPOLIA, ORIGIN_TX))
        );

        assertFalse(success);
        assertEq(
            result, abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, stranger, address(reactive))
        );
        assertEq(vault.balanceOf(alice), 1_000e18);
        assertTrue(_armed(address(vault)));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Exit: the happy path
    // ------------------------------------------------------------------------------------------------------------

    function test_Exit_RedeemsEverythingToTheOwner() public {
        uint256 shares = _protect(1_000e18);

        vm.expectEmit(address(guard));
        emit IExitGuard.Disarmed(address(vault));
        vm.expectEmit(address(guard));
        emit IExitGuard.Exited(address(vault), REASON, shares, 1_000e18, ETHEREUM_SEPOLIA, ORIGIN_TX);

        (bool success,) = _exit(address(vault));

        assertTrue(success);
        assertEq(usd.balanceOf(alice), 1_000e18);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(usd.balanceOf(address(guard)), 0, "the guard never holds assets");
        assertFalse(_armed(address(vault)), "one exit per arming");
    }

    function test_Exit_SendsAssetsToTheConfiguredReceiver() public {
        _protect(1_000e18);

        vm.prank(alice);
        guard.arm(address(vault), coldWallet);

        _exit(address(vault));

        assertEq(usd.balanceOf(coldWallet), 1_000e18);
        assertEq(usd.balanceOf(alice), 0);
    }

    function test_Exit_LeavesOtherDepositorsAlone() public {
        _protect(1_000e18);
        uint256 bobShares = _deposit(bob, vault, 500e18);

        _exit(address(vault));

        assertEq(vault.balanceOf(bob), bobShares);
        assertEq(usd.balanceOf(bob), 0);
    }

    function test_Exit_RedeemsOnlyWhatTheAllowanceCovers() public {
        _deposit(alice, vault, 1_000e18);

        vm.startPrank(alice);
        vault.approve(address(guard), 400e18);
        guard.arm(address(vault), address(0));
        vm.stopPrank();

        _exit(address(vault));

        assertEq(usd.balanceOf(alice), 400e18);
        assertEq(vault.balanceOf(alice), 600e18);
    }

    function test_Exit_SecondCallbackDoesNothing() public {
        _protect(1_000e18);
        _exit(address(vault));

        vm.expectEmit(address(guard));
        emit IExitGuard.ExitSkipped(address(vault), REASON, IExitGuard.SkipCause.NotArmed);

        (bool success,) = _exit(address(vault));

        assertTrue(success);
        assertEq(usd.balanceOf(alice), 1_000e18);
    }

    function testFuzz_Exit_RedeemsMinOfBalanceAndAllowance(uint256 assets_, uint256 allowance_) public {
        assets_ = bound(assets_, 1, usd.MAX_MINT());
        allowance_ = bound(allowance_, 0, 2 * usd.MAX_MINT());

        uint256 shares = _deposit(alice, vault, assets_);

        vm.startPrank(alice);
        vault.approve(address(guard), allowance_);
        guard.arm(address(vault), address(0));
        vm.stopPrank();

        (bool success,) = _exit(address(vault));
        assertTrue(success);

        uint256 expected = shares < allowance_ ? shares : allowance_;

        assertEq(vault.balanceOf(alice), shares - expected);
        assertEq(usd.balanceOf(alice), expected);
        assertEq(_armed(address(vault)), expected == 0, "stays armed only if nothing could be redeemed");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Exit: nothing to do
    // ------------------------------------------------------------------------------------------------------------

    function test_Exit_SkipsWhenNotArmed() public {
        _deposit(alice, vault, 1_000e18);

        vm.prank(alice);
        vault.approve(address(guard), type(uint256).max);

        vm.expectEmit(address(guard));
        emit IExitGuard.ExitSkipped(address(vault), REASON, IExitGuard.SkipCause.NotArmed);

        (bool success,) = _exit(address(vault));

        assertTrue(success);
        assertEq(vault.balanceOf(alice), 1_000e18);
    }

    function test_Exit_SkipsWhenOwnerHoldsNoShares() public {
        vm.prank(alice);
        guard.arm(address(vault), address(0));

        vm.expectEmit(address(guard));
        emit IExitGuard.ExitSkipped(address(vault), REASON, IExitGuard.SkipCause.NoShares);

        (bool success,) = _exit(address(vault));

        assertTrue(success);
        assertTrue(_armed(address(vault)), "still armed for a later deposit");
    }

    function test_Exit_SkipsWhenGuardHasNoAllowance() public {
        _deposit(alice, vault, 1_000e18);

        vm.prank(alice);
        guard.arm(address(vault), address(0));

        vm.expectEmit(address(guard));
        emit IExitGuard.ExitSkipped(address(vault), REASON, IExitGuard.SkipCause.NoAllowance);

        (bool success,) = _exit(address(vault));

        assertTrue(success);
        assertEq(vault.balanceOf(alice), 1_000e18);
        assertTrue(_armed(address(vault)));
    }

    function test_Exit_SkipsWhenVaultReportsNothingRedeemable() public {
        FrozenVault frozen = new FrozenVault(IERC20(address(usd)));
        _deposit(alice, frozen, 1_000e18);

        vm.startPrank(alice);
        frozen.approve(address(guard), type(uint256).max);
        guard.arm(address(frozen), address(0));
        vm.stopPrank();

        vm.expectEmit(address(guard));
        emit IExitGuard.ExitSkipped(address(frozen), REASON, IExitGuard.SkipCause.VaultLimit);

        (bool success,) = _exit(address(frozen));

        assertTrue(success);
        assertTrue(_armed(address(frozen)), "still armed in case the vault thaws");
    }

    function test_Exit_SkipsWhenVaultHasNoCode() public {
        address ghost = makeAddr("ghost");

        vm.prank(alice);
        guard.arm(ghost, address(0));

        vm.expectEmit(address(guard));
        emit IExitGuard.ExitSkipped(ghost, REASON, IExitGuard.SkipCause.NoShares);

        (bool success,) = _exit(ghost);

        assertTrue(success);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Exit: vaults that fight back
    // ------------------------------------------------------------------------------------------------------------

    function test_Exit_RecordsFailureAndStaysArmedWhenVaultReverts() public {
        HostileVault hostile = _protectHostile(HostileVault.Mode.Revert, 100e18);

        vm.expectEmit(address(guard));
        emit IExitGuard.ExitFailed(
            address(hostile),
            REASON,
            ETHEREUM_SEPOLIA,
            ORIGIN_TX,
            abi.encodeWithSelector(HostileVault.Frozen.selector, address(guard))
        );

        (bool success,) = _exit(address(hostile));

        assertTrue(success, "the callback itself must not revert");
        assertTrue(_armed(address(hostile)), "armed again so a later tripwire can retry");
        assertEq(hostile.balanceOf(alice), 100e18);
    }

    function test_Exit_SurvivesVaultThatBurnsAllItsGas() public {
        HostileVault hostile = _protectHostile(HostileVault.Mode.BurnGas, 100e18);

        vm.recordLogs();
        (bool success,) = _exit(address(hostile));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(success, "the gas reserve lets the guard finish");
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IExitGuard.ExitFailed.selector);
        assertTrue(_armed(address(hostile)));
    }

    function test_Exit_TruncatesOversizedRevertData() public {
        HostileVault hostile = _protectHostile(HostileVault.Mode.RevertBomb, 100e18);

        vm.recordLogs();
        (bool success,) = _exit(address(hostile));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(success);
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], IExitGuard.ExitFailed.selector);

        (,, bytes memory revertData) = abi.decode(logs[0].data, (uint256, uint256, bytes));
        assertEq(revertData.length, 256, "32 KB of revert data is cut to 256 bytes");
    }

    function test_Exit_AcceptsVaultThatReturnsNothing() public {
        HostileVault quiet = _protectHostile(HostileVault.Mode.ReturnNothing, 100e18);

        vm.expectEmit(address(guard));
        emit IExitGuard.Exited(address(quiet), REASON, 100e18, 0, ETHEREUM_SEPOLIA, ORIGIN_TX);

        (bool success,) = _exit(address(quiet));

        assertTrue(success);
        assertEq(quiet.balanceOf(alice), 0);
        assertFalse(_armed(address(quiet)));
    }

    function test_Exit_TreatsMissingMaxRedeemAsNoLimit() public {
        HostileVault minimal = _protectHostile(HostileVault.Mode.NoLimitMethod, 100e18);

        vm.expectEmit(address(guard));
        emit IExitGuard.Exited(address(minimal), REASON, 100e18, 100e18, ETHEREUM_SEPOLIA, ORIGIN_TX);

        (bool success,) = _exit(address(minimal));

        assertTrue(success);
        assertEq(minimal.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Manual exit
    // ------------------------------------------------------------------------------------------------------------

    function test_ExitNow_LetsTheOwnerPullTheCord() public {
        uint256 shares = _protect(1_000e18);

        vm.expectEmit(address(guard));
        emit IExitGuard.Exited(address(vault), guard.REASON_MANUAL(), shares, 1_000e18, block.chainid, 0);

        vm.prank(alice);
        guard.exitNow(address(vault));

        assertEq(usd.balanceOf(alice), 1_000e18);
    }

    function test_ExitNow_OnlyOwner() public {
        _protect(1_000e18);

        vm.prank(stranger);
        vm.expectRevert(ExitGuard.NotOwner.selector);
        guard.exitNow(address(vault));
    }

    function test_ExitNow_RevertsWhenNotArmed() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ExitGuard.NotArmed.selector, address(vault)));
        guard.exitNow(address(vault));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Drills
    // ------------------------------------------------------------------------------------------------------------

    function _answerDrill(uint256 nonce_, uint256 tripwires_) internal returns (bool success_) {
        (success_,) = proxy.deliver(
            address(reactive),
            address(guard),
            DEFAULT_CALLBACK_GAS,
            abi.encodeCall(IExitGuard.drill, (address(0), nonce_, address(vault), tripwires_))
        );
    }

    function test_Drill_MeasuresTheRoundTrip() public {
        vm.expectEmit(address(guard));
        emit IExitGuard.DrillRequested(1, address(vault));

        vm.prank(alice);
        uint256 nonce = guard.requestDrill(address(vault));
        assertEq(nonce, 1);

        // Three seconds and fifteen (200 ms) blocks later the answer arrives.
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 15);

        vm.expectEmit(address(guard));
        emit IExitGuard.DrillPassed(1, address(vault), 2, 3, 15);

        assertTrue(_answerDrill(1, 2));

        (,, uint64 secondsElapsed, uint64 blocksElapsed, address drilledVault, uint64 tripwires, bool passed) =
            guard.drills(1);

        assertTrue(passed);
        assertEq(secondsElapsed, 3);
        assertEq(blocksElapsed, 15);
        assertEq(drilledVault, address(vault));
        assertEq(tripwires, 2);
    }

    function test_Drill_NumbersRequestsFromOne() public {
        vm.startPrank(alice);
        assertEq(guard.requestDrill(address(vault)), 1);
        assertEq(guard.requestDrill(address(0)), 2);
        vm.stopPrank();

        assertEq(guard.drillCount(), 2);
    }

    function test_Drill_IgnoresRepeatedAndUnknownAnswers() public {
        vm.prank(alice);
        guard.requestDrill(address(vault));

        assertTrue(_answerDrill(1, 2));

        vm.recordLogs();
        assertTrue(_answerDrill(1, 2), "a repeated answer is ignored, not reverted");
        assertTrue(_answerDrill(99, 2), "an unknown nonce is ignored, not reverted");
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_Drill_OnlyOwnerMayRequest() public {
        vm.prank(stranger);
        vm.expectRevert(ExitGuard.NotOwner.selector);
        guard.requestDrill(address(vault));
    }

    function test_Drill_RejectsDirectAnswers() public {
        vm.prank(alice);
        guard.requestDrill(address(vault));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, address(proxy)));
        guard.drill(address(reactive), 1, address(vault), 2);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Gas money
    // ------------------------------------------------------------------------------------------------------------

    function test_WithdrawGasFunds_ReturnsDepositToOwner() public {
        uint256 before = alice.balance;

        vm.prank(alice);
        guard.withdrawGasFunds(0.04 ether);

        assertEq(alice.balance, before + 0.04 ether);
        assertEq(address(guard).balance, 0.06 ether);
    }

    function test_WithdrawGasFunds_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(ExitGuard.NotOwner.selector);
        guard.withdrawGasFunds(0.01 ether);
    }

    function test_CoverDebt_PaysTheProxyFromOwnBalance() public {
        proxy.setDebt(address(guard), 0.03 ether);

        // Anyone may settle the guard's bill; it only ever helps the owner.
        vm.prank(stranger);
        guard.coverDebt();

        assertEq(address(proxy).balance, 0.03 ether);
        assertEq(address(guard).balance, 0.07 ether);
    }

    function test_Pay_OnlyTheProxyCanCollect() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, address(proxy)));
        guard.pay(0.01 ether);

        vm.prank(address(proxy));
        guard.pay(0.01 ether);

        assertEq(address(proxy).balance, 0.01 ether);
    }

    function test_Receive_AcceptsTopUps() public {
        vm.deal(stranger, 1 ether);

        vm.prank(stranger);
        (bool success,) = address(guard).call{ value: 0.5 ether }("");

        assertTrue(success);
        assertEq(address(guard).balance, 0.6 ether);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Readiness
    // ------------------------------------------------------------------------------------------------------------

    function test_Readiness_ReportsWhatAnExitWouldDo() public {
        // Nothing set up yet.
        (bool armed,, uint256 shares, uint256 assets, IExitGuard.SkipCause blocker) = guard.readiness(address(vault));
        assertFalse(armed);
        assertEq(shares, 0);
        assertEq(assets, 0);
        assertEq(uint8(blocker), uint8(IExitGuard.SkipCause.NotArmed));

        // Deposited and armed, but the guard has no allowance.
        _deposit(alice, vault, 1_000e18);
        vm.prank(alice);
        guard.arm(address(vault), coldWallet);

        address receiver;
        (armed, receiver, shares,, blocker) = guard.readiness(address(vault));
        assertTrue(armed);
        assertEq(receiver, coldWallet);
        assertEq(shares, 0);
        assertEq(uint8(blocker), uint8(IExitGuard.SkipCause.NoAllowance));

        // Fully set up.
        vm.prank(alice);
        vault.approve(address(guard), type(uint256).max);

        (armed,, shares, assets,) = guard.readiness(address(vault));
        assertTrue(armed);
        assertEq(shares, 1_000e18);
        assertEq(assets, 1_000e18);
    }
}
