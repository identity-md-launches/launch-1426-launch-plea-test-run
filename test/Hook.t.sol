// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {BuyRouter} from "./utils/Mocks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract HookTest is Fixture {
    using StateLibrary for IPoolManager;

    function test_everyFeeIsPaidInTheSameSwap() public {
        buy(bob, 50e18); // IMD in the pool
        uint256 ownerBefore = imd.balanceOf(OWNER);
        uint256 prizeBefore = imd.balanceOf(address(seasons));
        uint256 claimsBefore = hook.retainClaims();
        uint256 supplyBefore = plea.totalSupply();
        uint256 amt = 100e18;
        uint256 fill = amt - amt * 150 / 10_150;
        buy(alice, 100e18);
        uint256 cashback = fill * 50 / 10_000;
        assertApproxEqAbs(imd.balanceOf(OWNER) - ownerBefore, cashback, 1);
        assertApproxEqAbs(imd.balanceOf(address(seasons)) - prizeBefore, fill * 25 / 10_000, 1);
        assertApproxEqAbs(hook.retainClaims() - claimsBefore, fill * 25 / 10_000, 2);
        assertApproxEqAbs(simd.byProject(alice, address(hook)), cashback, 1); // stacked as sIMD
        assertEq(imd.balanceOf(address(hook)), 0); // nothing parked
        assertLt(plea.totalSupply(), supplyBefore); // 0.25% burned
        (uint256 spent, uint256 held, uint256 t) = hook.basisOf(alice);
        assertEq(spent, 100e18);
        assertEq(held, plea.balanceOf(alice));
        assertEq(t, vm.getBlockTimestamp());
    }

    function test_firstBuyWithAnEmptyPoolSendsPayoutsToLiquidity() public {
        // Fresh fixture state: no IMD has ever entered the PoolManager.
        assertEq(imd.balanceOf(address(pm)), 0);
        vm.expectEmit(false, false, false, false, address(hook));
        emit PleaHook.PayoutsToPool(0);
        buy(alice, 10e18);
        assertGt(plea.balanceOf(alice), 0);
        assertGt(hook.retainClaims(), 0);
    }

    function test_aBuyMustAffordTheCredit() public {
        buy(bob, 50e18);
        bytes memory call = abi.encodeCall(BuyRouter.buyExactIn, (10e18, abi.encode(alice)));
        vm.prank(alice);
        (bool ok,) = address(router).call{gas: 400_000}(call);
        assertFalse(ok); // NotEnoughGas: the estimate can never pick a no-cashback path
        vm.prank(alice);
        (ok,) = address(router).call{gas: 2_000_000}(call);
        assertTrue(ok);
        assertGt(simd.byProject(alice, address(hook)), 0);
    }

    function test_plainImdOnlyWhenTheCreditReverts() public {
        buy(bob, 50e18);
        simd.setPaused(true);
        uint256 before = imd.balanceOf(alice);
        buy(alice, 10e18);
        assertEq(simd.balanceOf(alice), 0);
        uint256 amt = 10e18;
        uint256 fill = amt - amt * 150 / 10_150;
        assertApproxEqAbs(imd.balanceOf(alice), before - 10e18 + fill * 50 / 10_000, 1);
    }

    function test_sellsAndExactOutputOnlyThroughTheGateWhileAlive() public {
        buy(alice, 50e18);
        vm.prank(alice);
        vm.expectRevert();
        router.sellExactIn(1e18, abi.encode(alice));
        vm.prank(alice);
        vm.expectRevert();
        router.buyExactOut(1e18, abi.encode(alice));
        vm.prank(alice);
        vm.expectRevert();
        router.buyExactIn(1e18, ""); // no recipient
    }

    function test_freeTradingWhenTheCabalSleeps() public {
        buy(alice, 50e18);
        skip(DEADMAN);
        vm.startPrank(alice);
        plea.approve(address(router), type(uint256).max);
        uint256 out = router.sellExactIn(plea.balanceOf(alice) / 2, abi.encode(alice));
        vm.stopPrank();
        assertGt(out, 0);
    }

    function test_rebalanceRedeemsClaimsIntoTheWall() public {
        for (uint256 i; i < 5; ++i) {
            buy(alice, 400e18);
            buy(bob, 400e18);
        }
        assertGt(hook.retainClaims(), 1e18);
        uint256 claims = hook.retainClaims();
        vm.prank(keeper);
        hook.rebalance();
        assertEq(hook.retainClaims(), 0);
        (,, uint128 liq) = hook.wall();
        assertGt(liq, 0);
        assertGt(hook.wallImd(), claims / 2);
    }

    function test_avgBuyTimeIsBuyWeighted() public {
        buy(alice, 10e18);
        (,, uint256 t1) = hook.basisOf(alice);
        skip(10 days);
        // Keep the Cabal awake is irrelevant for buys; a second, equal-size buy halves the hold time.
        (, uint256 h1,) = hook.basisOf(alice);
        buy(alice, 10e18);
        (, uint256 h2, uint256 t2) = hook.basisOf(alice);
        uint256 expected = (t1 * h1 + vm.getBlockTimestamp() * (h2 - h1)) / h2;
        assertEq(t2, expected);
        assertGt(t2, t1);
    }

    function test_factScoreUsesCheckpointsNotSpot() public {
        buy(alice, 50e18);
        skip(1 hours);
        buy(bob, 10e18); // first trade of the hour sets the checkpoint
        uint256 latest = hook.latestPrice();
        buy(bob, 2_000e18); // a big pump in the same hour
        assertEq(hook.latestPrice(), latest);
        assertGt(hook.priceX96(), latest);
    }

    function test_hourlyCheckpointIsNotSetByTheTradeThatOpensTheHour() public {
        buy(alice, 100e18);
        skip(1 hours);
        uint256 found = hook.priceX96();
        buy(bob, 1e18); // the hour's first trade records the price it found, not the one it made
        assertEq(hook.latestPrice(), found);
        uint256 left = hook.priceX96(); // what bob's trade left: the next hour's checkpoint, nobody else's
        assertGt(left, found);
        skip(24 hours);
        assertEq(hook.price24hAgo(), found);
        uint256 amount = plea.balanceOf(alice) / 10;
        uint8 before = gate.factScore(alice, amount);
        // A pump as the first trade of a later hour: the hour's checkpoint is still the price before it.
        buy(carol, 100e18);
        assertEq(hook.latestPrice(), left);
        assertEq(hook.price24hAgo(), found);
        assertGt(hook.priceX96(), left * 102 / 100);
        assertEq(gate.factScore(alice, amount), before, "a same-hour trade moved the fact score");
    }

    function test_stackerIsApprovedOnlyForTheCashbackBeingCredited() public {
        assertEq(imd.allowance(address(hook), address(stacker)), 0);
        vm.startPrank(alice);
        imd.approve(address(hook), type(uint256).max);
        hook.fundWall(1_000e18);
        vm.stopPrank();
        vm.prank(address(stacker));
        vm.expectRevert();
        imd.transferFrom(address(hook), bob, 1e18); // the wall reserve is out of the Stacker's reach
        buy(bob, 50e18);
        buy(alice, 10e18);
        assertGt(simd.byProject(alice, address(hook)), 0);
        assertEq(imd.allowance(address(hook), address(stacker)), 0); // consumed by the credit
        assertEq(imd.balanceOf(address(hook)), 1_000e18);
        simd.setPaused(true);
        buy(alice, 10e18); // the credit reverts: plain IMD, and no allowance left behind
        assertEq(imd.allowance(address(hook), address(stacker)), 0);
        assertEq(imd.balanceOf(address(hook)), 1_000e18);
    }

    function test_wallGuardIgnoresTheEmptyPoolsPriceLimit() public {
        buy(alice, 100e18);
        skip(DEADMAN + 1); // the Cabal is dead: sells are free
        int24 g0 = hook.wallGuardTick();
        vm.prank(address(distributor));
        plea.transfer(alice, 50_000_000e18);
        vm.startPrank(alice);
        plea.approve(address(router), type(uint256).max);
        router.sellExactIn(50_000_000e18, abi.encode(alice)); // exact-in at the pool's price limit
        vm.stopPrank();
        int24 drained = hook.currentTick();
        assertTrue(drained <= hook.minTick() || drained >= hook.maxTick(), "the sell did not drain the pool");
        assertEq(hook.wallGuardTick(), g0, "an empty pool's price limit is not a traded price");
        vm.roll(vm.getBlockNumber() + 1);
        skip(1 hours);
        buy(bob, 50e18);
        vm.roll(vm.getBlockNumber() + 1);
        skip(12 hours);
        vm.startPrank(alice);
        imd.approve(address(hook), type(uint256).max);
        hook.fundWall(10e18);
        vm.stopPrank();
        assertTrue(hook.pendingRebalance());
        vm.prank(keeper);
        hook.rebalance();
        (int24 lo, int24 hi, uint128 liq) = hook.wall();
        assertGt(liq, 0, "no wall deployed");
        // The wall's near edge sits just below spot, not at the price limit the drain stopped at.
        int256 gap = _pleaPriceTick(hook.currentTick()) - _pleaPriceTick(hook.pleaIsZero() ? hi : lo);
        assertGe(gap, 0);
        assertLt(gap, 1_000);
    }

    function test_wallGuardIgnoresASellerChosenLimitReachedThroughAnEmptyPool() public {
        buy(alice, 100e18);
        skip(DEADMAN + 1); // the Cabal is dead: sells are free and the seller picks the price limit
        int24 g0 = hook.wallGuardTick();
        vm.prank(address(distributor));
        plea.transfer(alice, 50_000_000e18);
        // One tick spacing inside the usable range: strictly inside (minTick, maxTick), yet reached only
        // after the market band's IMD is gone, through the region where no liquidity is active.
        bool pz = hook.pleaIsZero();
        int24 limitTick = pz ? hook.minTick() + 60 : hook.maxTick() - 60;
        vm.startPrank(alice);
        plea.approve(address(router), type(uint256).max);
        router.sellExactInLimit(50_000_000e18, abi.encode(alice), TickMath.getSqrtPriceAtTick(limitTick));
        vm.stopPrank();
        assertEq(hook.currentTick(), limitTick, "the sell did not stop at the seller's limit");
        assertEq(IPoolManager(address(pm)).getLiquidity(hook.poolId()), 0, "liquidity is active at the limit");
        assertEq(hook.wallGuardTick(), g0, "the guard adopted a price limit reached through an empty pool");
        // Spot comes back with the next buy; the wall is then placed against the market, not the limit.
        vm.roll(vm.getBlockNumber() + 1);
        skip(1 hours);
        buy(bob, 50e18);
        vm.roll(vm.getBlockNumber() + 1);
        skip(12 hours);
        vm.startPrank(alice);
        imd.approve(address(hook), type(uint256).max);
        hook.fundWall(10e18);
        vm.stopPrank();
        assertTrue(hook.pendingRebalance());
        vm.prank(keeper);
        hook.rebalance();
        (int24 lo, int24 hi, uint128 liq) = hook.wall();
        assertGt(liq, 0, "no wall deployed");
        int256 gap = _pleaPriceTick(hook.currentTick()) - _pleaPriceTick(pz ? hi : lo);
        assertGe(gap, 0);
        assertLt(gap, 1_000);
    }

    function test_wallGuardStillDropsAtOnceToASellerChosenLimitInsideTheBand() public {
        buy(alice, 3_000e18);
        // Hold the pump for weeks so the guard catches up with the price (as the drop test does).
        for (uint256 i; i < 30; ++i) {
            skip(1 days);
            for (uint256 k; k < 3; ++k) {
                vm.roll(vm.getBlockNumber() + 1);
                buy(bob, 1e18);
            }
        }
        int24 g0 = hook.wallGuardTick();
        int24 spot0 = hook.currentTick();
        assertApproxEqAbs(_pleaPriceTick(g0), _pleaPriceTick(spot0), 20);
        // The Cabal is long dead. A sell with the seller's own limit that stops inside the market band,
        // where liquidity is active: PLEA really traded down to that price, and the guard follows it.
        bool pz = hook.pleaIsZero();
        int24 limitTick = pz ? spot0 - 600 : spot0 + 600;
        vm.startPrank(alice);
        plea.approve(address(router), type(uint256).max);
        router.sellExactInLimit(plea.balanceOf(alice), abi.encode(alice), TickMath.getSqrtPriceAtTick(limitTick));
        vm.stopPrank();
        assertGt(IPoolManager(address(pm)).getLiquidity(hook.poolId()), 0, "the sell left the band");
        int24 spot1 = hook.currentTick();
        assertEq(spot1, limitTick, "the sell did not stop at the seller's limit");
        assertLt(_pleaPriceTick(hook.wallGuardTick()), _pleaPriceTick(g0), "the guard did not drop");
        assertEq(_pleaPriceTick(hook.wallGuardTick()), _pleaPriceTick(pz ? spot1 : spot1 + 1));
    }

    function test_capDecayIsSetSoTheFloorIsReachableIn25Days() public view {
        uint256 cap = hook.inventoryCap();
        assertEq(hook.capDecayPerDay(), (cap - hook.CAP_FLOOR()) / 25);
    }

    function test_capFollowsBuysAtMostOneDayOfDecayPerDay() public {
        buy(alice, 3_000e18); // takes far more than one day's allowance out of the market
        uint256 held = hook.pleaInMarket();
        uint256 cap0 = hook.inventoryCap();
        assertGt(cap0 - held, hook.capDecayPerDay()); // the cap cannot jump to the holdings at once
        skip(1 days);
        buy(bob, 1e18);
        uint256 cap1 = hook.inventoryCap();
        assertApproxEqAbs(cap0 - cap1, hook.capDecayPerDay(), hook.capDecayPerDay() / 1000);
        skip(30 days);
        buy(bob, 1e18);
        assertEq(hook.inventoryCap(), hook.pleaInMarket()); // caught up, never below the holdings
    }

    function test_aSellAboveTheCapIsTrimmedAndBurned() public {
        buy(alice, 3_000e18);
        skip(30 days);
        buy(bob, 1e18); // cap catches up with the market
        skip(DEADMAN); // free trading
        uint256 supplyBefore = plea.totalSupply();
        uint256 claimsBefore = hook.retainClaims();
        vm.startPrank(alice);
        plea.approve(address(router), type(uint256).max);
        uint256 sold = plea.balanceOf(alice) / 4;
        router.sellExactIn(sold, abi.encode(alice));
        vm.stopPrank();
        assertApproxEqRel(plea.totalSupply() + sold, supplyBefore, 0.01e18); // ~the sold PLEA burned
        assertGt(hook.retainClaims(), claimsBefore); // and IMD moved to the wall reserve
    }

    function _pleaPriceTick(int24 t) internal view returns (int256) {
        return hook.pleaIsZero() ? int256(t) : -int256(t);
    }

    function test_wallGuardLagsAPumpAndCapsTheWall() public {
        int24 g0 = hook.wallGuardTick();
        for (uint256 i; i < 40; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            skip(12);
            buy(bob, 300e18); // a pump held over many blocks drags refTick along
        }
        int24 spot = hook.currentTick();
        int24 g1 = hook.wallGuardTick();
        // The guard moved at most 400 ticks a day toward the higher PLEA price (8 minutes: ~2 ticks).
        assertLe(_pleaPriceTick(g1) - _pleaPriceTick(g0), 3);
        assertGt(_pleaPriceTick(spot) - _pleaPriceTick(g1), 1_000);
        vm.prank(keeper);
        hook.rebalance();
        (int24 lo, int24 hi,) = hook.wall();
        // The wall's edge nearest the price is no higher a PLEA price than the guard.
        if (hook.pleaIsZero()) assertLe(hi, g1);
        else assertGe(lo, g1);
    }

    function test_wallGuardDropsAtOnceAndRisesFourPercentADay() public {
        buy(alice, 3_000e18);
        // Hold the price for weeks: the guard climbs ~400 ticks a day until it reaches the price.
        for (uint256 i; i < 30; ++i) {
            skip(1 days);
            for (uint256 k; k < 3; ++k) {
                vm.roll(vm.getBlockNumber() + 1); // refTick follows ~200 ticks per traded block
                buy(bob, 1e18);
            }
        }
        int24 g0 = hook.wallGuardTick();
        assertApproxEqAbs(_pleaPriceTick(g0), _pleaPriceTick(hook.currentTick()), 20); // caught up to the last block close
        // The Cabal is long dead (no verdicts), so trading is free and we can push the price down.
        vm.startPrank(alice);
        plea.approve(address(router), type(uint256).max);
        router.sellExactIn(plea.balanceOf(alice) / 2, abi.encode(alice));
        vm.stopPrank();
        int24 g1 = hook.wallGuardTick();
        assertEq(_pleaPriceTick(g1), _pleaPriceTick(hook.pleaIsZero() ? hook.currentTick() : hook.currentTick() + 1));
        assertLe(_pleaPriceTick(g1), _pleaPriceTick(g0));
        // A day later, with the price held higher, the guard has risen by at most 400 ticks.
        for (uint256 i; i < 3; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            skip(8 hours);
            buy(bob, 1_000e18);
        }
        int24 g2 = hook.wallGuardTick();
        assertLe(_pleaPriceTick(g2) - _pleaPriceTick(g1), 401);
        assertGt(_pleaPriceTick(g2), _pleaPriceTick(g1));
    }
}
