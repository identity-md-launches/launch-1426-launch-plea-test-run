// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {PleaIsZeroFixture} from "./Orientation.t.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/// @dev A seller that names its own price limit (the gate always uses the extreme; a free seller after
/// the Cabal's death can choose any limit).
contract LimitSeller {
    IPoolManager public pm;
    PleaHook public hook;
    IERC20 public imd;
    IERC20 public plea;

    constructor(IPoolManager pm_, PleaHook hook_, IERC20 imd_, IERC20 plea_) {
        pm = pm_;
        hook = hook_;
        imd = imd_;
        plea = plea_;
    }

    function sellExactInLimit(uint256 pleaIn, address trader, uint160 limit) external returns (uint256) {
        return abi.decode(pm.unlock(abi.encode(msg.sender, -int256(pleaIn), abi.encode(trader), limit)), (uint256));
    }

    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (address payer, int256 amountSpecified, bytes memory hookData, uint160 limit) =
            abi.decode(raw, (address, int256, bytes, uint160));
        bool pleaIsZero = hook.pleaIsZero();
        BalanceDelta d = pm.swap(
            hook.poolKey(),
            SwapParams({zeroForOne: pleaIsZero, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            hookData
        );
        (int128 pleaDelta, int128 imdDelta) = pleaIsZero ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        uint256 amountIn = uint256(uint128(-pleaDelta));
        uint256 amountOut = uint256(uint128(imdDelta));
        pm.sync(Currency.wrap(address(plea)));
        plea.transferFrom(payer, address(pm), amountIn);
        pm.settle();
        if (amountOut != 0) pm.take(Currency.wrap(address(imd)), payer, amountOut);
        return abi.encode(amountOut);
    }
}

/// @dev A Stacker that tries to pull twice the cashback it is credited with. Etched over the fixture's
/// Stacker (same storage layout: slot 0 is the IMD token).
contract GreedyStacker {
    IERC20 public imd;

    function credit(address, uint256 amount) external {
        imd.transferFrom(msg.sender, address(this), amount * 2);
    }
}

/// @dev Adversarial coverage of the three hook fixes of this revision (hourly checkpoint, Stacker
/// allowance, wall guard), run in both currency orientations.
/// forge-config: default.fuzz.runs = 64
contract HookRevisionTest is Fixture {
    using StateLibrary for IPoolManager;

    function _seller() internal returns (LimitSeller s) {
        s = new LimitSeller(IPoolManager(address(pm)), hook, IERC20(address(imd)), IERC20(address(plea)));
    }

    function _pleaPriceTick(int24 t) internal view returns (int256) {
        return hook.pleaIsZero() ? int256(t) : -int256(t);
    }

    function _killCabal() internal {
        skip(DEADMAN + 1);
        assertFalse(plea.restricted(), "the Cabal should be dead");
    }

    // ------------------------------------------------------------------ hourly checkpoint

    /// @dev Whatever the size of the hour's first trade and however many hours passed, the hour's
    /// checkpoint is the price that trade found; later trades in the hour do not touch it either.
    function testFuzz_theHoursFirstTradeRecordsThePriceItFoundWhateverItsSize(uint256 imdIn, uint256 hoursLater)
        public
    {
        imdIn = bound(imdIn, 1e15, 3_000e18);
        hoursLater = bound(hoursLater, 1, 30);
        buy(alice, 20e18);
        skip(hoursLater * 1 hours);
        uint256 found = hook.priceX96();
        buy(bob, imdIn);
        assertEq(hook.latestPrice(), found, "the opening trade set its own closing price as the checkpoint");
        assertGt(hook.priceX96(), found);
        buy(carol, 1e18);
        assertEq(hook.latestPrice(), found, "a later trade of the hour moved the checkpoint");
        skip(1 hours);
        uint256 left = hook.priceX96();
        buy(carol, 1e18);
        assertEq(hook.latestPrice(), left, "the next hour's checkpoint is the price the previous hour left");
    }

    /// @dev A pump of any size inside the hour a plea is submitted cannot move its fact score.
    function testFuzz_aSameHourPumpCannotMoveAPleasFactScore(uint256 imdIn) public {
        imdIn = bound(imdIn, 1e18, 5_000e18);
        buy(alice, 100e18);
        skip(25 hours);
        buy(bob, 1e18);
        skip(1 hours);
        buy(bob, 1e17); // the hour's first trade: its checkpoint is now the price that trade found
        uint256 amount = plea.balanceOf(alice) / 10;
        uint8 before = gate.factScore(alice, amount);
        uint256 latest = hook.latestPrice();
        uint256 dayAgo = hook.price24hAgo();
        buy(carol, imdIn);
        assertEq(hook.latestPrice(), latest);
        assertEq(hook.price24hAgo(), dayAgo);
        assertEq(gate.factScore(alice, amount), before, "a same-hour pump moved the fact score");
    }

    /// @dev A sell after the Cabal's death opening an hour: the checkpoint is still the pre-trade price.
    function test_anHourOpeningSellRecordsThePriceItFound() public {
        buy(alice, 300e18);
        _killCabal();
        skip(1 hours);
        uint256 found = hook.priceX96();
        LimitSeller seller = _seller();
        vm.startPrank(alice);
        plea.approve(address(seller), type(uint256).max);
        seller.sellExactInLimit(plea.balanceOf(alice) / 2, alice, _extremeLimit());
        vm.stopPrank();
        assertEq(hook.latestPrice(), found);
        assertLt(hook.priceX96(), found);
    }

    function _extremeLimit() internal view returns (uint160) {
        return hook.pleaIsZero() ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    // ------------------------------------------------------------------ Stacker allowance

    /// @dev A credit that burns all its gas: plain IMD cashback, and no allowance left behind.
    function test_aCreditThatBurnsAllItsGasLeavesNoAllowance() public {
        buy(bob, 50e18);
        vm.startPrank(alice);
        imd.approve(address(hook), type(uint256).max);
        hook.fundWall(500e18);
        vm.stopPrank();
        stacker.setBurnAllGas(true);
        uint256 before = imd.balanceOf(alice);
        buy(alice, 10e18);
        assertEq(imd.allowance(address(hook), address(stacker)), 0, "allowance left after a failed credit");
        assertGt(imd.balanceOf(alice), before - 10e18, "no plain cashback paid");
        assertEq(simd.balanceOf(alice), 0);
        assertEq(imd.balanceOf(address(hook)), 500e18, "the wall reserve moved");
        assertEq(hook.retainedImd(), 500e18);
    }

    /// @dev A Stacker that tries to pull more than the credit gets nothing: the reserve stays whole,
    /// the trader is paid in plain IMD and the allowance is back to zero.
    function testFuzz_aGreedyStackerCannotReachTheWallReserve(uint256 imdIn, uint256 reserve) public {
        imdIn = bound(imdIn, 1e16, 2_000e18);
        reserve = bound(reserve, 1, 10_000e18);
        buy(bob, 50e18);
        vm.startPrank(alice);
        imd.approve(address(hook), type(uint256).max);
        hook.fundWall(reserve);
        vm.stopPrank();
        vm.etch(address(stacker), type(GreedyStacker).runtimeCode);
        assertEq(address(GreedyStacker(address(stacker)).imd()), address(imd));
        uint256 stackerBefore = imd.balanceOf(address(stacker));
        uint256 aliceBefore = imd.balanceOf(alice);
        buy(alice, imdIn);
        assertEq(imd.balanceOf(address(stacker)), stackerBefore, "the greedy Stacker pulled IMD");
        assertEq(imd.allowance(address(hook), address(stacker)), 0, "allowance left standing");
        assertEq(imd.balanceOf(address(hook)), reserve, "the wall reserve is not whole");
        assertGt(imd.balanceOf(alice), aliceBefore - imdIn, "no plain cashback paid");
        // Even a direct pull by the Stacker between trades finds nothing to take.
        vm.prank(address(stacker));
        vm.expectRevert();
        imd.transferFrom(address(hook), address(stacker), 1);
    }

    /// @dev Any sequence of successful credits consumes exactly its allowance; nothing accrues.
    function testFuzz_successfulCreditsNeverAccumulateAllowance(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1e16, 1_000e18);
        b = bound(b, 1e16, 1_000e18);
        c = bound(c, 1e16, 1_000e18);
        buy(bob, 10e18); // the very first buy may send its payouts to liquidity
        buy(alice, a);
        assertEq(imd.allowance(address(hook), address(stacker)), 0);
        buy(bob, b);
        assertEq(imd.allowance(address(hook), address(stacker)), 0);
        buy(carol, c);
        assertEq(imd.allowance(address(hook), address(stacker)), 0);
        assertGt(hook.totalCashback(), 0);
        assertGt(simd.byProject(bob, address(hook)) + simd.byProject(alice, address(hook)), 0);
    }

    // ------------------------------------------------------------------ wall guard

    /// @dev Once the guard has climbed to the market, a free sell that stops inside the liquid market
    /// band is a price PLEA traded at: the guard follows it at once and the wall is then placed right
    /// below that price, not beyond it. A sell that stops above the guard leaves it where it is.
    function test_wallGuardFollowsASellThatStopsWhereTheMarketHasLiquidity() public {
        buy(alice, 300e18);
        int24 g0 = hook.wallGuardTick();
        // Let refTick and the guard catch up with the pumped spot (200 ticks a block, 400 a day).
        for (uint256 i; i < 8; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            skip(1 days);
            buy(bob, 1e17);
        }
        int24 spot = hook.currentTick();
        assertGe(_pleaPriceTick(hook.wallGuardTick()), _pleaPriceTick(spot) - 60, "the guard did not catch up");
        assertFalse(plea.restricted(), "the Cabal should be dead by now");
        LimitSeller seller = _seller();
        vm.startPrank(alice);
        plea.approve(address(seller), type(uint256).max);
        // A small sell 30 ticks down: followed at once, since the guard sat at the market.
        seller.sellExactInLimit(
            plea.balanceOf(alice), alice, TickMath.getSqrtPriceAtTick(hook.pleaIsZero() ? spot - 30 : spot + 30)
        );
        int24 stopped1 = hook.currentTick();
        assertEq(hook.wallGuardTick(), hook.pleaIsZero() ? stopped1 : stopped1 + 1, "the guard did not follow");
        // A sell 300 ticks down, still inside the liquid band: the guard follows at once.
        int24 limitTick = hook.pleaIsZero() ? spot - 300 : spot + 300;
        seller.sellExactInLimit(plea.balanceOf(alice), alice, TickMath.getSqrtPriceAtTick(limitTick));
        vm.stopPrank();
        int24 stopped = hook.currentTick();
        assertGt(IPoolManager(address(pm)).getLiquidity(hook.poolId()), 0, "the sell left the liquid band");
        assertLe(_pleaPriceTick(stopped), _pleaPriceTick(spot) - 299);
        assertGt(_pleaPriceTick(stopped), _pleaPriceTick(g0), "the sell went below the seeded price");
        assertEq(hook.wallGuardTick(), hook.pleaIsZero() ? stopped : stopped + 1, "the guard did not follow");
        vm.startPrank(alice);
        imd.approve(address(hook), type(uint256).max);
        hook.fundWall(10e18);
        vm.stopPrank();
        vm.prank(keeper);
        hook.rebalance();
        (int24 lo, int24 hi, uint128 liq) = hook.wall();
        assertGt(liq, 0, "no wall deployed");
        int256 gap = _pleaPriceTick(hook.currentTick()) - _pleaPriceTick(hook.pleaIsZero() ? hi : lo);
        assertGe(gap, 0);
        assertLt(gap, 120, "the wall is not right below the traded price");
    }

    /// @dev Second revision of the guard: a seller's limit anywhere in the liquidity-free region below the
    /// market band (not only one spacing inside the usable range) is reached after the band's IMD is
    /// gone. Whatever the depth, no liquidity is active there, the guard does not move on the drain nor
    /// on the buy that brings the price back, and the wall is then placed against the market.
    function testFuzz_aLimitAnywhereInTheLiquidityFreeRegionNeverMovesTheGuard(uint256 depth, uint256 imdBack) public {
        depth = bound(depth, 60, 700_000);
        imdBack = bound(imdBack, 1e18, 100e18);
        buy(alice, 100e18);
        _killCabal();
        int24 g0 = hook.wallGuardTick();
        vm.prank(address(distributor));
        plea.transfer(alice, 50_000_000e18);
        (int24 marketLower, int24 marketUpper,) = hook.market();
        bool pz = hook.pleaIsZero();
        int24 limitTick = pz ? marketLower - int24(int256(depth)) : marketUpper + int24(int256(depth));
        assertTrue(limitTick > hook.minTick() && limitTick < hook.maxTick(), "limit outside the usable range");
        vm.startPrank(alice);
        plea.approve(address(router), type(uint256).max);
        router.sellExactInLimit(50_000_000e18, abi.encode(alice), TickMath.getSqrtPriceAtTick(limitTick));
        vm.stopPrank();
        assertEq(hook.currentTick(), limitTick, "the sell did not stop at the seller's limit");
        assertEq(IPoolManager(address(pm)).getLiquidity(hook.poolId()), 0, "liquidity is active at the limit");
        assertEq(hook.wallGuardTick(), g0, "a drained tick moved the guard");
        vm.roll(vm.getBlockNumber() + 1);
        skip(1 hours);
        buy(bob, imdBack);
        assertGt(IPoolManager(address(pm)).getLiquidity(hook.poolId()), 0, "the buy did not reach the band");
        assertEq(hook.wallGuardTick(), g0, "the restoring buy moved the guard");
        vm.roll(vm.getBlockNumber() + 1);
        skip(12 hours);
        vm.startPrank(alice);
        imd.approve(address(hook), type(uint256).max);
        hook.fundWall(10e18);
        vm.stopPrank();
        vm.prank(keeper);
        hook.rebalance();
        (int24 lo, int24 hi, uint128 liq) = hook.wall();
        assertGt(liq, 0, "no wall deployed");
        int256 gap = _pleaPriceTick(hook.currentTick()) - _pleaPriceTick(pz ? hi : lo);
        assertGe(gap, 0, "the wall is above spot");
        assertLt(gap, 1_000, "the wall is not placed against the market");
    }

    /// @dev The other side of the same condition: a limit the seller stops at inside the liquid market
    /// band, at any depth the band's IMD reaches, is a price PLEA traded at, and the guard (once at
    /// the market) follows it to exactly that tick.
    function testFuzz_aLimitInsideTheLiquidMarketBandMovesTheGuardToTheStopTick(uint256 depth) public {
        depth = bound(depth, 1, 800);
        buy(alice, 300e18);
        for (uint256 i; i < 8; ++i) {
            vm.roll(vm.getBlockNumber() + 1);
            skip(1 days);
            buy(bob, 1e17);
        }
        int24 spot = hook.currentTick();
        assertGe(_pleaPriceTick(hook.wallGuardTick()), _pleaPriceTick(spot) - 60, "the guard did not catch up");
        assertFalse(plea.restricted(), "the Cabal should be dead by now");
        bool pz = hook.pleaIsZero();
        int24 limitTick = pz ? spot - int24(int256(depth)) : spot + int24(int256(depth));
        LimitSeller seller = _seller();
        vm.startPrank(alice);
        plea.approve(address(seller), type(uint256).max);
        seller.sellExactInLimit(plea.balanceOf(alice), alice, TickMath.getSqrtPriceAtTick(limitTick));
        vm.stopPrank();
        int24 stopped = hook.currentTick();
        assertEq(stopped, limitTick, "the sell did not stop at the seller's limit");
        assertGt(IPoolManager(address(pm)).getLiquidity(hook.poolId()), 0, "the sell left the liquid band");
        assertEq(hook.wallGuardTick(), pz ? stopped : stopped + 1, "the guard did not follow the traded price");
    }

    /// @dev The extreme is ignored however often the pool is drained, and the guard does not drift.
    function testFuzz_repeatedDrainsToTheExtremeNeverMoveTheGuard(uint8 drains) public {
        drains = uint8(bound(drains, 1, 4));
        buy(alice, 100e18);
        _killCabal();
        int24 g0 = hook.wallGuardTick();
        vm.prank(address(distributor));
        plea.transfer(alice, 90_000_000e18);
        vm.prank(alice);
        plea.approve(address(router), type(uint256).max);
        for (uint256 i; i < drains; ++i) {
            vm.prank(alice);
            router.sellExactIn(i == 0 ? 50_000_000e18 : 10_000_000e18, abi.encode(alice));
            int24 t = hook.currentTick();
            assertTrue(t <= hook.minTick() || t >= hook.maxTick(), "not drained");
            assertEq(hook.wallGuardTick(), g0, "the extreme moved the guard");
            vm.roll(vm.getBlockNumber() + 1);
            skip(10 minutes);
            buy(bob, 5e18);
            assertEq(hook.wallGuardTick(), g0, "a buy after the drain moved the guard");
        }
    }

    /// @dev The guard's climb toward the market is paced: never more than 400 ticks per day, however
    /// the idle time is split, and it never passes the reference tick.
    function testFuzz_theGuardClimbsAtMost400TicksADay(uint256 pump, uint256 gapSeconds, uint8 steps) public {
        pump = bound(pump, 500e18, 3_000e18);
        gapSeconds = bound(gapSeconds, 1, 2 days);
        steps = uint8(bound(steps, 1, 6));
        buy(alice, 20e18);
        skip(1 hours);
        int24 g0 = hook.wallGuardTick();
        buy(bob, pump); // a pump: the guard must not follow upward at once
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.wallGuardTick(), g0);
        uint256 start = vm.getBlockTimestamp();
        for (uint256 i; i < steps; ++i) {
            skip(gapSeconds);
            vm.roll(vm.getBlockNumber() + 1);
            buy(carol, 1e17);
            uint256 elapsed = vm.getBlockTimestamp() - start;
            int256 climbed = _pleaPriceTick(hook.wallGuardTick()) - _pleaPriceTick(g0);
            assertGe(climbed, 0, "the guard fell without a lower trade");
            // Each update is capped at one day of idle time, so the bound is per update, not elapsed.
            assertLe(uint256(climbed), 400 * (i + 1) * (gapSeconds > 1 days ? 1 days : gapSeconds) / 1 days + 1);
            assertLe(uint256(climbed), 400 * elapsed / 1 days + 1, "the guard climbed faster than 400 ticks a day");
            assertLe(_pleaPriceTick(hook.wallGuardTick()), _pleaPriceTick(hook.refTick()) + 1, "passed refTick");
        }
    }
}

contract HookRevisionPleaIsZeroTest is PleaIsZeroFixture, HookRevisionTest {
    function deployImd() internal override(Fixture, PleaIsZeroFixture) {
        PleaIsZeroFixture.deployImd();
    }
}
