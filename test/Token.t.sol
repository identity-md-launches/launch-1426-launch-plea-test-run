// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {PLEA} from "../src/PLEA.sol";

contract TokenTest is Fixture {
    function setUp() public override {
        super.setUp();
        buy(alice, 50e18);
    }

    function test_walletsCannotSendWhileTheCabalWatches() public {
        uint256 bal = plea.balanceOf(alice);
        vm.startPrank(alice);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(bob, 1);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(address(pm), 1);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(address(gate), 1); // direct sends to the gate are refused
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(address(hook), 1);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.burn(1);
        plea.approve(bob, type(uint256).max);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transferFrom(alice, bob, 1);
        assertEq(plea.balanceOf(alice), bal);
    }

    function test_distributorAndAllowlistMaySend() public {
        vm.prank(address(distributor));
        plea.transfer(bob, 1e18);
        vm.prank(alice);
        vm.expectRevert();
        plea.allow(alice);
        vm.prank(OWNER);
        plea.allow(alice);
        vm.prank(alice);
        plea.transfer(bob, 1e18);
    }

    function test_freeForeverOnceTheCabalDies() public {
        skip(DEADMAN);
        vm.prank(alice);
        plea.transfer(bob, 1e18);
        skip(365 days);
        assertFalse(plea.restricted());
        vm.prank(bob);
        plea.transfer(carol, 1e18);
        // No verdict can bring it back: pleading is closed.
        vm.prank(alice);
        vm.expectRevert();
        gate.submitSell(1e18, "come back");
    }

    function test_launcherAndInitAreOneShot() public {
        vm.expectRevert(PLEA.AlreadySet.selector);
        plea.setLauncher(alice, alice, alice);
        vm.expectRevert(PLEA.NotLauncher.selector);
        plea.init(alice, alice);
        vm.prank(address(launch));
        vm.expectRevert(PLEA.AlreadySet.selector);
        plea.init(alice, alice);
        // A fresh PLEA in a later block cannot be wired by anyone.
        PLEA p = new PLEA(OWNER);
        vm.roll(vm.getBlockNumber() + 1);
        // forge keeps transient storage within a test, so clear the flag as a new transaction would.
        vm.store(address(p), bytes32(0), bytes32(0));
        assertEq(p.totalSupply(), 0);
        assertLe(plea.totalSupply(), 1_000_000_000e18 - hook.totalBurned());
        assertGt(plea.totalSupply(), 999_000_000e18);
        assertEq(plea.balanceOf(address(distributor)), 100_000_000e18);
    }
}
