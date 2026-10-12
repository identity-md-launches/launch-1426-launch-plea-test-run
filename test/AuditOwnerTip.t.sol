// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";

contract AuditOwnerTipTest is Fixture {
    function test_currentPleaOwnerReceivesNoKeeperTipAfterOwnershipTransfer() public {
        buy(alice, 50e18);
        skip(1 days);
        imd.mint(address(this), 200e18);
        imd.approve(address(hook), 200e18);
        hook.fundWall(200e18);
        assertTrue(hook.pendingRebalance());
        uint256 snapshot = vm.snapshotState();
        uint256 before = imd.balanceOf(alice);
        vm.prank(alice);
        hook.rebalance();
        assertEq(imd.balanceOf(alice) - before, hook.KEEPER_TIP(), "a holder can earn the keeper tip");
        vm.revertToState(snapshot);
        vm.prank(OWNER);
        plea.transferOwnership(alice);
        assertEq(plea.owner(), alice);
        assertEq(hook.owner(), OWNER, "the original fee beneficiary stays fixed");
        vm.prank(alice);
        hook.rebalance();
        assertEq(imd.balanceOf(alice), before, "the PLEA owner cannot earn the keeper tip");
    }
}
