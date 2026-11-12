// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";

import { ExitGuardReactive } from "../src/ExitGuardReactive.sol";
import { IExitGuard } from "../src/interfaces/IExitGuard.sol";
import { Fixture } from "./utils/Fixture.sol";
import { MockSystemContract } from "./mocks/MockSystemContract.sol";

contract ExitGuardReactiveTest is Fixture {
    address internal vault = makeAddr("vault");
    address internal otherVault = makeAddr("otherVault");
    address internal timelock = makeAddr("timelock");
    address internal sister = makeAddr("sisterDeployment");

    uint256 internal any;

    function setUp() public {
        _deployCore();
        any = reactive.ANY_TOPIC();
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Data of `CallScheduled(bytes32 indexed id, uint256 indexed index, address target, uint256 value,
    ///      bytes data, bytes32 predecessor, uint256 delay)` for a call against `target_`.
    function _scheduledData(address target_) internal pure returns (bytes memory) {
        return abi.encode(target_, uint256(0), hex"4f1ef286", bytes32(0), uint256(2 days));
    }

    function _callScheduled(address target_) internal view returns (IReactive.LogRecord memory) {
        return _record(
            BASE_SEPOLIA,
            timelock,
            _topics(bytes32(reactive.TOPIC_CALL_SCHEDULED()), keccak256("operation"), bytes32(0)),
            _scheduledData(target_)
        );
    }

    function _upgraded(address proxy_) internal view returns (IReactive.LogRecord memory) {
        return _record(BASE_SEPOLIA, proxy_, _topics(bytes32(reactive.TOPIC_UPGRADED()), bytes32(uint256(0xbeef))), "");
    }

    function _freshReactive() internal returns (ExitGuardReactive fresh_) {
        vm.prank(alice);
        fresh_ = new ExitGuardReactive(alice, BASE_SEPOLIA);
    }

    function _custom(uint256 topic1_, uint256 topic2_, uint256 topic3_, uint8 dataWord_, bytes32 dataValue_)
        internal
        view
        returns (ExitGuardReactive.Tripwire memory)
    {
        return ExitGuardReactive.Tripwire({
            chainId: ETHEREUM_SEPOLIA,
            source: sister,
            topic0: uint256(keccak256("Custom(uint256,uint256,uint256,bytes)")),
            topic1: topic1_,
            topic2: topic2_,
            topic3: topic3_,
            dataValue: dataValue_,
            vault: vault,
            dataWord: dataWord_,
            reason: 100,
            active: true
        });
    }

    // ------------------------------------------------------------------------------------------------------------
    // Deployment and linking
    // ------------------------------------------------------------------------------------------------------------

    function test_Constructor_SetsOwnerDestinationAndDefaults() public view {
        assertEq(reactive.owner(), alice);
        assertEq(reactive.destinationChainId(), BASE_SEPOLIA);
        assertEq(reactive.callbackGasLimit(), 500_000);
        assertEq(reactive.cooldown(), 5 minutes);
        assertEq(address(reactive).balance, 1 ether);
        assertEq(address(reactive._SERVICE_PROVIDER()), SYSTEM_ADDR);
    }

    function test_Constructor_RejectsZeroOwnerAndZeroChain() public {
        vm.expectRevert(ExitGuardReactive.ZeroAddress.selector);
        new ExitGuardReactive(address(0), BASE_SEPOLIA);

        vm.expectRevert(ExitGuardReactive.ZeroChainId.selector);
        new ExitGuardReactive(alice, 0);
    }

    function test_SetGuard_SubscribesToDrillRequests() public {
        ExitGuardReactive fresh = _freshReactive();
        address newGuard = makeAddr("newGuard");

        vm.expectEmit(address(fresh));
        emit ExitGuardReactive.GuardSet(newGuard);

        vm.prank(alice);
        fresh.setGuard(newGuard);

        assertEq(fresh.guard(), newGuard);
        assertTrue(
            system.isSubscribed(
                address(fresh), BASE_SEPOLIA, newGuard, uint256(IExitGuard.DrillRequested.selector), any, any, any
            )
        );
    }

    function test_SetGuard_OnlyOnceOnlyOwnerNeverZero() public {
        ExitGuardReactive fresh = _freshReactive();

        vm.prank(stranger);
        vm.expectRevert(ExitGuardReactive.NotOwner.selector);
        fresh.setGuard(address(guard));

        vm.prank(alice);
        vm.expectRevert(ExitGuardReactive.ZeroAddress.selector);
        fresh.setGuard(address(0));

        // The fixture's contract is already linked.
        vm.prank(alice);
        vm.expectRevert(ExitGuardReactive.GuardAlreadySet.selector);
        reactive.setGuard(makeAddr("anotherGuard"));
    }

    function test_Tripwires_NeedAGuardFirst() public {
        ExitGuardReactive fresh = _freshReactive();

        vm.prank(alice);
        vm.expectRevert(ExitGuardReactive.GuardNotSet.selector);
        fresh.watchPause(BASE_SEPOLIA, sister, vault);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Laying tripwires
    // ------------------------------------------------------------------------------------------------------------

    function test_WatchTimelock_MatchesTheTargetInTheEventData() public {
        vm.expectEmit(address(reactive));
        emit ExitGuardReactive.TripwireAdded(
            0, BASE_SEPOLIA, timelock, reactive.TOPIC_CALL_SCHEDULED(), vault, reactive.REASON_UPGRADE_SCHEDULED()
        );

        vm.prank(alice);
        uint256 id = reactive.watchTimelock(BASE_SEPOLIA, timelock, vault, vault);

        ExitGuardReactive.Tripwire memory wire = reactive.tripwire(id);

        assertEq(id, 0);
        assertEq(wire.chainId, BASE_SEPOLIA);
        assertEq(wire.source, timelock);
        assertEq(wire.topic0, reactive.TOPIC_CALL_SCHEDULED());
        assertEq(wire.dataWord, 0);
        assertEq(wire.dataValue, bytes32(uint256(uint160(vault))));
        assertEq(wire.vault, vault);
        assertEq(wire.reason, reactive.REASON_UPGRADE_SCHEDULED());
        assertTrue(wire.active);

        assertEq(reactive.tripwireCount(), 1);
        assertEq(reactive.tripwiresOf(vault), 1);
        assertTrue(
            system.isSubscribed(
                address(reactive), BASE_SEPOLIA, timelock, reactive.TOPIC_CALL_SCHEDULED(), any, any, any
            )
        );
    }

    function test_WatchProxy_CoversImplementationAndAdminChanges() public {
        vm.prank(alice);
        (uint256 upgradedId, uint256 adminChangedId) = reactive.watchProxy(BASE_SEPOLIA, vault, vault);

        assertEq(reactive.tripwire(upgradedId).topic0, reactive.TOPIC_UPGRADED());
        assertEq(reactive.tripwire(upgradedId).reason, reactive.REASON_UPGRADED());
        assertEq(reactive.tripwire(adminChangedId).topic0, reactive.TOPIC_ADMIN_CHANGED());
        assertEq(reactive.tripwire(adminChangedId).reason, reactive.REASON_ADMIN_CHANGED());
        assertEq(reactive.tripwire(upgradedId).dataWord, reactive.NO_DATA_MATCH());
        assertEq(reactive.tripwiresOf(vault), 2);
    }

    function test_WatchOwnership_CoversBothStepsOfATransfer() public {
        vm.prank(alice);
        (uint256 startedId, uint256 transferredId) = reactive.watchOwnership(BASE_SEPOLIA, vault, vault);

        assertEq(reactive.tripwire(startedId).topic0, reactive.TOPIC_OWNERSHIP_TRANSFER_STARTED());
        assertEq(reactive.tripwire(transferredId).topic0, reactive.TOPIC_OWNERSHIP_TRANSFERRED());
        assertEq(reactive.tripwiresOf(vault), 2);
    }

    function test_WatchPause_CanWatchAnotherChain() public {
        vm.prank(alice);
        uint256 id = reactive.watchPause(ETHEREUM_SEPOLIA, sister, vault);

        assertEq(reactive.tripwire(id).chainId, ETHEREUM_SEPOLIA);
        assertEq(reactive.tripwire(id).topic0, reactive.TOPIC_PAUSED());
        assertTrue(
            system.isSubscribed(address(reactive), ETHEREUM_SEPOLIA, sister, reactive.TOPIC_PAUSED(), any, any, any)
        );
    }

    function test_WellKnownTopics_MatchTheStandards() public view {
        assertEq(
            reactive.TOPIC_UPGRADED(), 0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b, "ERC-1967"
        );
        assertEq(
            reactive.TOPIC_ADMIN_CHANGED(),
            0x7e644d79422f17c01e4894b5f4f588d331ebfa28653d42ae832dc59e38c9798f,
            "ERC-1967"
        );
        assertEq(
            reactive.TOPIC_OWNERSHIP_TRANSFERRED(),
            0x8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0,
            "Ownable"
        );
    }

    function test_Tripwires_OnlyOwnerMayLayThem() public {
        vm.startPrank(stranger);

        vm.expectRevert(ExitGuardReactive.NotOwner.selector);
        reactive.watchTimelock(BASE_SEPOLIA, timelock, vault, vault);

        vm.expectRevert(ExitGuardReactive.NotOwner.selector);
        reactive.watchProxy(BASE_SEPOLIA, vault, vault);

        vm.expectRevert(ExitGuardReactive.NotOwner.selector);
        reactive.watchOwnership(BASE_SEPOLIA, vault, vault);

        vm.expectRevert(ExitGuardReactive.NotOwner.selector);
        reactive.watchPause(BASE_SEPOLIA, sister, vault);

        vm.expectRevert(ExitGuardReactive.NotOwner.selector);
        reactive.addTripwire(_custom(any, any, any, 255, bytes32(0)));

        vm.stopPrank();
    }

    function test_AddTripwire_RejectsVagueOrReservedTripwires() public {
        ExitGuardReactive.Tripwire memory wire;

        vm.startPrank(alice);

        wire = _custom(any, any, any, 255, bytes32(0));
        wire.chainId = 0;
        vm.expectRevert(ExitGuardReactive.InvalidTripwire.selector);
        reactive.addTripwire(wire);

        wire = _custom(any, any, any, 255, bytes32(0));
        wire.source = address(0);
        vm.expectRevert(ExitGuardReactive.InvalidTripwire.selector);
        reactive.addTripwire(wire);

        wire = _custom(any, any, any, 255, bytes32(0));
        wire.topic0 = any;
        vm.expectRevert(ExitGuardReactive.InvalidTripwire.selector);
        reactive.addTripwire(wire);

        wire = _custom(any, any, any, 255, bytes32(0));
        wire.vault = address(0);
        vm.expectRevert(ExitGuardReactive.InvalidTripwire.selector);
        reactive.addTripwire(wire);

        // The guard's own events are reserved for drills.
        wire = _custom(any, any, any, 255, bytes32(0));
        wire.chainId = BASE_SEPOLIA;
        wire.source = address(guard);
        vm.expectRevert(ExitGuardReactive.InvalidTripwire.selector);
        reactive.addTripwire(wire);

        vm.stopPrank();
    }

    function test_AddTripwire_CapsTripwiresPerEvent() public {
        uint256 max = reactive.MAX_TRIPWIRES_PER_EVENT();

        vm.startPrank(alice);

        for (uint256 i = 0; i < max; ++i) {
            // Small loop counter; the cast cannot truncate.
            // forge-lint: disable-next-line(unsafe-typecast)
            reactive.watchPause(BASE_SEPOLIA, sister, address(uint160(0x1000 + i)));
        }

        vm.expectRevert(ExitGuardReactive.TooManyTripwires.selector);
        reactive.watchPause(BASE_SEPOLIA, sister, vault);

        vm.stopPrank();
    }

    function test_Subscriptions_AreSharedAndReleasedWithTheLastTripwire() public {
        uint256 baseline = system.subscribeCalls(); // the drill subscription made by `setGuard`

        vm.startPrank(alice);
        uint256 first = reactive.watchPause(BASE_SEPOLIA, sister, vault);
        uint256 second = reactive.watchPause(BASE_SEPOLIA, sister, otherVault);
        vm.stopPrank();

        assertEq(system.subscribeCalls(), baseline + 1, "two tripwires on one event share one subscription");

        vm.prank(alice);
        reactive.removeTripwire(first);

        assertEq(system.unsubscribeCalls(), 0, "the subscription is still needed");
        assertTrue(system.isSubscribed(address(reactive), BASE_SEPOLIA, sister, reactive.TOPIC_PAUSED(), any, any, any));

        vm.prank(alice);
        reactive.removeTripwire(second);

        assertEq(system.unsubscribeCalls(), 1);
        assertFalse(
            system.isSubscribed(address(reactive), BASE_SEPOLIA, sister, reactive.TOPIC_PAUSED(), any, any, any)
        );
    }

    function test_RemoveTripwire_StopsItFiring() public {
        vm.prank(alice);
        (uint256 upgradedId, uint256 adminChangedId) = reactive.watchProxy(BASE_SEPOLIA, vault, vault);

        vm.expectEmit(address(reactive));
        emit ExitGuardReactive.TripwireRemoved(upgradedId);

        vm.prank(alice);
        reactive.removeTripwire(upgradedId);

        assertFalse(reactive.tripwire(upgradedId).active);
        assertTrue(reactive.tripwire(adminChangedId).active);
        assertEq(reactive.tripwiresOf(vault), 1);
        assertEq(reactive.tripwiresFor(BASE_SEPOLIA, vault, reactive.TOPIC_UPGRADED()).length, 0);

        _react(_upgraded(vault));

        assertEq(system.callbackCount(), 0);
    }

    function test_RemoveTripwire_RejectsUnknownRemovedAndStrangers() public {
        vm.prank(alice);
        uint256 id = reactive.watchPause(BASE_SEPOLIA, sister, vault);

        vm.prank(stranger);
        vm.expectRevert(ExitGuardReactive.NotOwner.selector);
        reactive.removeTripwire(id);

        vm.startPrank(alice);

        vm.expectRevert(abi.encodeWithSelector(ExitGuardReactive.UnknownTripwire.selector, 7));
        reactive.removeTripwire(7);

        reactive.removeTripwire(id);

        vm.expectRevert(abi.encodeWithSelector(ExitGuardReactive.UnknownTripwire.selector, id));
        reactive.removeTripwire(id);

        vm.stopPrank();
    }

    function test_Tripwire_RevertsForUnknownId() public {
        vm.expectRevert(abi.encodeWithSelector(ExitGuardReactive.UnknownTripwire.selector, 0));
        reactive.tripwire(0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reacting
    // ------------------------------------------------------------------------------------------------------------

    function test_React_OnlyTheSystemContractMayCall() public {
        IReactive.LogRecord memory record = _upgraded(vault);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM_ADDR));
        reactive.react(record);
    }

    function test_React_RequestsAnExitWhenATripwireMatches() public {
        vm.prank(alice);
        (uint256 upgradedId,) = reactive.watchProxy(BASE_SEPOLIA, vault, vault);

        IReactive.LogRecord memory record = _upgraded(vault);

        vm.expectEmit(address(reactive));
        emit ExitGuardReactive.Tripped(upgradedId, vault, reactive.REASON_UPGRADED(), BASE_SEPOLIA, record.txHash);

        _react(record);

        assertEq(system.callbackCount(), 1);

        MockSystemContract.CallbackRequest memory request = system.callbackAt(0);

        assertEq(request.sender, address(reactive));
        assertEq(request.chainId, BASE_SEPOLIA);
        assertEq(request.recipient, address(guard));
        assertEq(request.gasLimit, 500_000);
        assertEq(
            request.payload,
            abi.encodeCall(
                IExitGuard.exit, (address(0), vault, reactive.REASON_UPGRADED(), BASE_SEPOLIA, record.txHash)
            ),
            "first argument is the placeholder the callback proxy overwrites"
        );
        assertEq(reactive.lastFiredAt(vault), block.timestamp);
    }

    function test_React_TimelockTripwireFiresOnlyForItsTarget() public {
        vm.prank(alice);
        reactive.watchTimelock(BASE_SEPOLIA, timelock, vault, vault);

        // The timelock queues a call against some other contract: not our business.
        _react(_callScheduled(otherVault));
        assertEq(system.callbackCount(), 0);

        // The timelock queues a call against the vault: exit.
        _react(_callScheduled(vault));
        assertEq(system.callbackCount(), 1);
    }

    function test_React_OneTimelockCanGuardSeveralVaults() public {
        vm.startPrank(alice);
        reactive.watchTimelock(BASE_SEPOLIA, timelock, vault, vault);
        reactive.watchTimelock(BASE_SEPOLIA, timelock, otherVault, otherVault);
        vm.stopPrank();

        IReactive.LogRecord memory record = _callScheduled(otherVault);
        _react(record);

        assertEq(system.callbackCount(), 1);
        assertEq(
            system.callbackAt(0).payload,
            abi.encodeCall(
                IExitGuard.exit,
                (address(0), otherVault, reactive.REASON_UPGRADE_SCHEDULED(), BASE_SEPOLIA, record.txHash)
            )
        );
    }

    function test_React_DataFilterIgnoresEventsWithTooLittleData() public {
        vm.prank(alice);
        reactive.watchTimelock(BASE_SEPOLIA, timelock, vault, vault);

        IReactive.LogRecord memory record = _callScheduled(vault);
        record.data = hex"0000000000000000000000000000000000000000000000000000000000";

        _react(record);

        assertEq(system.callbackCount(), 0);
    }

    function test_React_TopicFiltersMustAllMatch() public {
        bytes32 role = keccak256("ADMIN_ROLE");

        vm.prank(alice);
        reactive.addTripwire(_custom(uint256(role), any, any, 255, bytes32(0)));

        bytes32 topic0 = keccak256("Custom(uint256,uint256,uint256,bytes)");

        _react(_record(ETHEREUM_SEPOLIA, sister, _topics(topic0, keccak256("OTHER_ROLE")), ""));
        assertEq(system.callbackCount(), 0, "different topic1");

        _react(_record(ETHEREUM_SEPOLIA, sister, _topics(topic0, role), ""));
        assertEq(system.callbackCount(), 1, "matching topic1");
    }

    function test_React_ZeroFilterDoesNotMatchAMissingTopic() public {
        // The filter asks for topic1 == 0. A log with no topic1 at all reports zero in that field too.
        vm.prank(alice);
        reactive.addTripwire(_custom(0, any, any, 255, bytes32(0)));

        bytes32 topic0 = keccak256("Custom(uint256,uint256,uint256,bytes)");

        _react(_record(ETHEREUM_SEPOLIA, sister, _topics(topic0), ""));
        assertEq(system.callbackCount(), 0, "the log has one topic only");

        _react(_record(ETHEREUM_SEPOLIA, sister, _topics(topic0, bytes32(0)), ""));
        assertEq(system.callbackCount(), 1, "the log really carries topic1 == 0");
    }

    function test_React_IgnoresLogsItHasNoTripwireFor() public {
        vm.prank(alice);
        reactive.watchProxy(BASE_SEPOLIA, vault, vault);

        _react(_upgraded(otherVault)); // same event, another contract
        _react(_record(ETHEREUM_SEPOLIA, vault, _topics(bytes32(reactive.TOPIC_UPGRADED())), "")); // another chain
        _react(_record(BASE_SEPOLIA, vault, _topics(keccak256("Transfer(address,address,uint256)")), "")); // other event
        _react(_record(BASE_SEPOLIA, vault, new bytes32[](0), "")); // anonymous log

        assertEq(system.callbackCount(), 0);
    }

    function test_React_DoesNothingBeforeAGuardIsSet() public {
        ExitGuardReactive fresh = _freshReactive();

        system.deliver(fresh, _upgraded(vault));

        assertEq(system.callbackCount(), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Cooldown
    // ------------------------------------------------------------------------------------------------------------

    function test_Cooldown_CollapsesABurstIntoOneExit() public {
        vm.startPrank(alice);
        reactive.watchTimelock(BASE_SEPOLIA, timelock, vault, vault);
        (uint256 upgradedId,) = reactive.watchProxy(BASE_SEPOLIA, vault, vault);
        vm.stopPrank();

        _react(_callScheduled(vault));
        assertEq(system.callbackCount(), 1);

        // A minute later the upgrade lands. The exit was already requested.
        vm.warp(block.timestamp + 60);

        vm.expectEmit(address(reactive));
        emit ExitGuardReactive.Suppressed(upgradedId, vault);

        _react(_upgraded(vault));
        assertEq(system.callbackCount(), 1);
    }

    function test_Cooldown_AllowsARetryOnceItHasPassed() public {
        vm.startPrank(alice);
        reactive.watchTimelock(BASE_SEPOLIA, timelock, vault, vault);
        reactive.watchProxy(BASE_SEPOLIA, vault, vault);
        vm.stopPrank();

        _react(_callScheduled(vault));

        vm.warp(block.timestamp + reactive.cooldown());
        _react(_upgraded(vault));

        assertEq(system.callbackCount(), 2);
    }

    function test_Cooldown_IsPerVault() public {
        vm.startPrank(alice);
        reactive.watchProxy(BASE_SEPOLIA, vault, vault);
        reactive.watchProxy(BASE_SEPOLIA, otherVault, otherVault);
        vm.stopPrank();

        _react(_upgraded(vault));
        _react(_upgraded(otherVault));

        assertEq(system.callbackCount(), 2);
    }

    function test_Cooldown_TwoTripwiresOnOneEventRequestOneExit() public {
        // Two tripwires for the same vault listen to the same event (one plain, one filtered).
        vm.startPrank(alice);
        reactive.watchPause(ETHEREUM_SEPOLIA, sister, vault);
        ExitGuardReactive.Tripwire memory wire = _custom(any, any, any, 255, bytes32(0));
        wire.topic0 = reactive.TOPIC_PAUSED();
        reactive.addTripwire(wire);
        vm.stopPrank();

        _react(_record(ETHEREUM_SEPOLIA, sister, _topics(bytes32(reactive.TOPIC_PAUSED())), abi.encode(stranger)));

        assertEq(system.callbackCount(), 1);
    }

    function test_SetCooldown_ZeroDisablesIt() public {
        vm.startPrank(alice);
        reactive.watchProxy(BASE_SEPOLIA, vault, vault);

        vm.expectEmit(address(reactive));
        emit ExitGuardReactive.CooldownSet(0);
        reactive.setCooldown(0);
        vm.stopPrank();

        _react(_upgraded(vault));
        _react(_upgraded(vault));

        assertEq(system.callbackCount(), 2);
    }

    function test_SetCooldown_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert(ExitGuardReactive.NotOwner.selector);
        reactive.setCooldown(0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Drills
    // ------------------------------------------------------------------------------------------------------------

    function _drillRequested(uint256 nonce_, address vault_) internal view returns (IReactive.LogRecord memory) {
        return _record(
            BASE_SEPOLIA,
            address(guard),
            _topics(IExitGuard.DrillRequested.selector, bytes32(nonce_), bytes32(uint256(uint160(vault_)))),
            ""
        );
    }

    function test_Drill_AnswersWithTheNumberOfTripwires() public {
        vm.startPrank(alice);
        reactive.watchTimelock(BASE_SEPOLIA, timelock, vault, vault);
        reactive.watchProxy(BASE_SEPOLIA, vault, vault);
        vm.stopPrank();

        vm.expectEmit(address(reactive));
        emit ExitGuardReactive.DrillAnswered(7, vault, 3);

        _react(_drillRequested(7, vault));

        assertEq(system.callbackCount(), 1);
        assertEq(system.callbackAt(0).recipient, address(guard));
        assertEq(system.callbackAt(0).payload, abi.encodeCall(IExitGuard.drill, (address(0), 7, vault, 3)));
    }

    function test_Drill_IsNotSubjectToTheCooldown() public {
        vm.prank(alice);
        reactive.watchProxy(BASE_SEPOLIA, vault, vault);

        _react(_upgraded(vault));
        _react(_drillRequested(1, vault));
        _react(_drillRequested(2, vault));

        assertEq(system.callbackCount(), 3);
    }

    function test_Drill_IgnoresOtherEventsFromTheGuard() public {
        _react(_record(BASE_SEPOLIA, address(guard), _topics(IExitGuard.Disarmed.selector, bytes32(0)), ""));

        // Right signature, wrong shape.
        _react(_record(BASE_SEPOLIA, address(guard), _topics(IExitGuard.DrillRequested.selector), ""));

        assertEq(system.callbackCount(), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Settings and funds
    // ------------------------------------------------------------------------------------------------------------

    function test_SetCallbackGasLimit_AppliesToLaterCallbacks() public {
        vm.startPrank(alice);
        reactive.watchProxy(BASE_SEPOLIA, vault, vault);

        vm.expectEmit(address(reactive));
        emit ExitGuardReactive.CallbackGasLimitSet(800_000);
        reactive.setCallbackGasLimit(800_000);
        vm.stopPrank();

        _react(_upgraded(vault));

        assertEq(system.callbackAt(0).gasLimit, 800_000);
    }

    function test_SetCallbackGasLimit_RejectsLimitsTheNetworkWouldIgnore() public {
        vm.startPrank(alice);

        vm.expectRevert(ExitGuardReactive.GasLimitTooLow.selector);
        reactive.setCallbackGasLimit(99_999);

        reactive.setCallbackGasLimit(100_000);
        vm.stopPrank();

        vm.prank(stranger);
        vm.expectRevert(ExitGuardReactive.NotOwner.selector);
        reactive.setCallbackGasLimit(800_000);
    }

    function test_Withdraw_ReturnsDepositToOwner() public {
        uint256 before = alice.balance;

        vm.prank(alice);
        reactive.withdraw(0.4 ether);

        assertEq(alice.balance, before + 0.4 ether);
        assertEq(address(reactive).balance, 0.6 ether);

        vm.prank(stranger);
        vm.expectRevert(ExitGuardReactive.NotOwner.selector);
        reactive.withdraw(0.1 ether);
    }

    function test_CoverDebt_PaysTheSystemContractFromOwnBalance() public {
        system.setDebt(address(reactive), 0.25 ether);

        vm.prank(stranger);
        reactive.coverDebt();

        assertEq(SYSTEM_ADDR.balance, 0.25 ether);
        assertEq(address(reactive).balance, 0.75 ether);
    }

    function test_Pay_OnlyTheSystemContractCanCollect() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM_ADDR));
        reactive.pay(0.1 ether);

        vm.prank(SYSTEM_ADDR);
        reactive.pay(0.1 ether);

        assertEq(SYSTEM_ADDR.balance, 0.1 ether);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Property: a tripwire fires exactly when every one of its filters matches
    // ------------------------------------------------------------------------------------------------------------

    function testFuzz_React_FiresExactlyWhenEveryFilterMatches(
        uint256 seed_,
        uint256[3] memory logTopics_,
        uint256[3] memory otherTopics_,
        uint8 topicCount_,
        bytes memory data_,
        bytes32 otherValue_
    ) public {
        topicCount_ = uint8(bound(topicCount_, 1, 4));

        // Decide each filter from two bits of the seed: wildcard, the log's own value, or an unrelated value.
        uint256[3] memory filters;
        bool expected = true;

        for (uint256 i = 0; i < 3; ++i) {
            uint256 choice = (seed_ >> (2 * i)) & 3;

            if (choice == 0) {
                filters[i] = any;
            } else if (choice == 1) {
                filters[i] = logTopics_[i];
            } else {
                filters[i] = otherTopics_[i];
            }

            vm.assume(logTopics_[i] != any && otherTopics_[i] != any);

            bool present = topicCount_ > i + 1;

            if (filters[i] != any && !(present && filters[i] == logTopics_[i])) {
                expected = false;
            }
        }

        // Same for the data filter: none, the word really at that position, or an unrelated value.
        uint8 dataWord = reactive.NO_DATA_MATCH();
        bytes32 dataValue;
        uint256 dataChoice = (seed_ >> 6) & 3;

        if (dataChoice != 0) {
            dataWord = uint8((seed_ >> 8) % 4);
            uint256 start = uint256(dataWord) * 32;
            bool hasWord = data_.length >= start + 32;
            bytes32 actual;

            if (hasWord) {
                assembly ("memory-safe") {
                    actual := mload(add(add(data_, 0x20), start))
                }
            }

            dataValue = dataChoice == 1 ? actual : otherValue_;

            if (!hasWord || dataValue != actual) {
                expected = false;
            }
        }

        vm.prank(alice);
        reactive.addTripwire(_custom(filters[0], filters[1], filters[2], dataWord, dataValue));

        bytes32[] memory topics = new bytes32[](topicCount_);
        topics[0] = keccak256("Custom(uint256,uint256,uint256,bytes)");

        for (uint256 i = 1; i < topicCount_; ++i) {
            topics[i] = bytes32(logTopics_[i - 1]);
        }

        _react(_record(ETHEREUM_SEPOLIA, sister, topics, data_));

        assertEq(system.callbackCount(), expected ? 1 : 0);
    }
}
