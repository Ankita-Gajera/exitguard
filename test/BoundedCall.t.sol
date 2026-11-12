// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";

import { ExitGuard } from "../src/ExitGuard.sol";
import { ExitGuardReactive } from "../src/ExitGuardReactive.sol";
import { BoundedCall } from "../src/libraries/BoundedCall.sol";

contract BoundedCallHarness {
    function staticUint(address target_, bytes memory data_) external view returns (bool, uint256) {
        return BoundedCall.staticUint(target_, data_);
    }

    function callUint(address target_, bytes memory data_, uint256 gas_, uint256 maxRevertBytes_)
        external
        returns (bool, uint256, bytes memory)
    {
        return BoundedCall.callUint(target_, data_, gas_, maxRevertBytes_);
    }
}

contract Target {
    error Nope(uint256 code);

    uint256 public counter;

    function one() external pure returns (uint256) {
        return 1;
    }

    function bump() external returns (uint256) {
        return ++counter;
    }

    function short() external pure {
        assembly ("memory-safe") {
            mstore(0, 0xff)
            return(0, 0x10)
        }
    }

    function fail() external pure {
        revert Nope(42);
    }
}

/// @notice An owner that cannot receive native tokens.
contract StubbornOwner { }

contract BoundedCallTest is Test {
    BoundedCallHarness internal harness = new BoundedCallHarness();
    Target internal target = new Target();

    function test_StaticUint_ReadsOneWord() public view {
        (bool ok, uint256 value) = harness.staticUint(address(target), abi.encodeCall(Target.one, ()));

        assertTrue(ok);
        assertEq(value, 1);
    }

    function test_StaticUint_FailsOnMissingCodeRevertsAndShortReturns() public {
        (bool ok, uint256 value) = harness.staticUint(makeAddr("empty"), abi.encodeCall(Target.one, ()));
        assertFalse(ok);
        assertEq(value, 0);

        (ok, value) = harness.staticUint(address(target), abi.encodeCall(Target.fail, ()));
        assertFalse(ok);
        assertEq(value, 0);

        (ok, value) = harness.staticUint(address(target), abi.encodeCall(Target.short, ()));
        assertFalse(ok, "sixteen bytes are not a word");
        assertEq(value, 0);
    }

    function test_CallUint_ReturnsValueAndKeepsStateChanges() public {
        (bool ok, uint256 value, bytes memory revertData) =
            harness.callUint(address(target), abi.encodeCall(Target.bump, ()), 100_000, 256);

        assertTrue(ok);
        assertEq(value, 1);
        assertEq(revertData.length, 0);
        assertEq(target.counter(), 1);
    }

    function test_CallUint_ReportsRevertData() public {
        (bool ok, uint256 value, bytes memory revertData) =
            harness.callUint(address(target), abi.encodeCall(Target.fail, ()), 100_000, 256);

        assertFalse(ok);
        assertEq(value, 0);
        assertEq(revertData, abi.encodeWithSelector(Target.Nope.selector, 42));
    }

    function test_CallUint_TruncatesRevertData() public {
        (bool ok,, bytes memory revertData) =
            harness.callUint(address(target), abi.encodeCall(Target.fail, ()), 100_000, 4);

        assertFalse(ok);
        assertEq(revertData, abi.encodePacked(Target.Nope.selector));
    }

    function test_CallUint_FailsOnMissingCode() public {
        (bool ok, uint256 value, bytes memory revertData) =
            harness.callUint(makeAddr("empty"), abi.encodeCall(Target.bump, ()), 100_000, 256);

        assertFalse(ok);
        assertEq(value, 0);
        assertEq(revertData.length, 0);
    }

    function test_CallUint_SucceedsWithZeroValueOnShortReturn() public {
        (bool ok, uint256 value,) = harness.callUint(address(target), abi.encodeCall(Target.short, ()), 100_000, 256);

        assertTrue(ok);
        assertEq(value, 0);
    }

    // The withdrawal paths of both contracts report a failed transfer instead of losing track of the funds.

    function test_Guard_WithdrawFailsLoudlyWhenOwnerCannotReceive() public {
        StubbornOwner owner = new StubbornOwner();
        ExitGuard guard = new ExitGuard{ value: 1 ether }(
            IPayable(payable(makeAddr("proxy"))), makeAddr("reactive"), address(owner)
        );

        vm.prank(address(owner));
        vm.expectRevert(ExitGuard.WithdrawFailed.selector);
        guard.withdrawGasFunds(1 ether);

        assertEq(address(guard).balance, 1 ether);
    }

    function test_Reactive_WithdrawFailsLoudlyWhenOwnerCannotReceive() public {
        StubbornOwner owner = new StubbornOwner();
        ExitGuardReactive reactive = new ExitGuardReactive{ value: 1 ether }(address(owner), 84532);

        vm.prank(address(owner));
        vm.expectRevert(ExitGuardReactive.WithdrawFailed.selector);
        reactive.withdraw(1 ether);

        assertEq(address(reactive).balance, 1 ether);
    }
}
