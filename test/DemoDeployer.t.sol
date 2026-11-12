// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/Test.sol";

import { DemoDeployer } from "../src/demo/DemoDeployer.sol";
import { DemoVault } from "../src/demo/DemoVault.sol";

contract DemoDeployerTest is Test {
    address internal you = makeAddr("you");
    address internal bob = makeAddr("bob");

    function test_SetsTheWholeStageInOneTransaction() public {
        DemoDeployer demo = new DemoDeployer(120, you, bob);
        DemoVault vault = demo.vault();

        // An ERC-4626 vault for the test dollars, running V1, owned by the timelock.
        assertEq(vault.asset(), address(demo.usd()));
        assertEq(vault.version(), "1");
        assertEq(vault.owner(), address(demo.timelock()));
        assertEq(demo.vaultV2().version(), "2");

        // The timelock has the requested delay, and `you` is its only proposer and executor.
        assertEq(demo.timelock().getMinDelay(), 120);
        assertTrue(demo.timelock().hasRole(demo.timelock().PROPOSER_ROLE(), you));
        assertTrue(demo.timelock().hasRole(demo.timelock().EXECUTOR_ROLE(), you));
        assertFalse(demo.timelock().hasRole(demo.timelock().PROPOSER_ROLE(), bob));

        // Both depositors hold 1,000 test dollars' worth of shares; the deployer kept nothing.
        assertEq(vault.balanceOf(you), demo.DEPOSIT());
        assertEq(vault.balanceOf(bob), demo.DEPOSIT());
        assertEq(vault.totalAssets(), 2 * demo.DEPOSIT());
        assertEq(demo.usd().balanceOf(address(demo)), 0);
        assertEq(vault.balanceOf(address(demo)), 0);

        // Depositors can leave while V1 is live.
        uint256 deposit = demo.DEPOSIT();

        vm.prank(bob);
        vault.redeem(deposit, bob, bob);
        assertEq(demo.usd().balanceOf(bob), deposit);
    }
}
