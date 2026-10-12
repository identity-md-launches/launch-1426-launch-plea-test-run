// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Seasons} from "../src/Seasons.sol";

contract SeasonsTest is Fixture {
    address[] players;

    function setUp() public virtual override {
        super.setUp();
        for (uint256 i; i < 12; ++i) {
            address p = makeAddr(string.concat("player", vm.toString(i)));
            fund(p);
            players.push(p);
        }
        for (uint256 i; i < users.length; ++i) {
            buy(users[i], buySize());
        }
        for (uint256 i; i < players.length; ++i) {
            buy(players[i], buySize());
        }
    }

    // ---------------------------------------------------------------- helpers

    function buySize() internal virtual returns (uint256) {
        return 50e18;
    }

    /// @dev Pleads and approves with `score`, then observes the cooldown on lapsed approvals.
    function scored(address who, uint256 score) internal virtual returns (uint256 id) {
        id = approvedPlea(who, score);
        skip(4 hours);
    }

    /// @dev Advances to `t`, delivering a denial often enough that the Cabal never goes silent.
    function liveUntil(uint256 t) internal {
        uint256 i = 1;
        keepAlive(players[0]);
        uint256 step = DEADMAN * 9 / 10;
        while (vm.getBlockTimestamp() + step < t) {
            skip(step);
            keepAlive(players[i % players.length]);
            ++i;
        }
        vm.warp(t);
    }

    function t0() internal view returns (uint256) {
        return gate.startedAt();
    }

    function transferWorks(address from, address to) internal returns (bool ok) {
        vm.prank(from);
        (ok,) = address(plea).call(abi.encodeCall(plea.transfer, (to, 1e18)));
    }

    // ---------------------------------------------------------------- the clock

    function test_aliveFromSeedDeadAfterSilenceForever() public {
        assertTrue(gate.cabalAlive());
        assertFalse(transferWorks(alice, bob));
        vm.warp(t0() + DEADMAN - 1);
        assertTrue(gate.cabalAlive());
        skip(1);
        assertFalse(gate.cabalAlive());
        assertEq(gate.diedAt(), t0() + DEADMAN);
        assertTrue(transferWorks(alice, bob));
        skip(1000 days);
        assertFalse(gate.cabalAlive());
        assertTrue(transferWorks(alice, bob));
    }

    function test_aLateCallbackCannotRevive() public {
        vm.warp(t0() + DEADMAN - 1);
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        skip(1);
        assertFalse(answer(id, 45));
        assertFalse(gate.cabalAlive());
    }

    function test_verdictsKeepItAliveAcrossManySeasons() public {
        liveUntil(t0() + 3 * SEASON + 1 hours);
        assertTrue(gate.cabalAlive());
        (bool live, uint256 s,) = seasons.currentSeason();
        assertTrue(live);
        assertEq(s, 3);
    }

    // ---------------------------------------------------------------- points

    function test_bestThreeCountAndTopTenOrder() public {
        uint256[4] memory s = [uint256(40), 41, 42, 43];
        for (uint256 i; i < 4; ++i) {
            seasons.record(scored(alice, s[i]));
        }
        assertEq(seasons.bestOf(0, alice)[0] + seasons.bestOf(0, alice)[1] + seasons.bestOf(0, alice)[2], 126);
        seasons.record(scored(bob, 45));
        seasons.record(scored(carol, 40));
        seasons.record(scored(carol, 40));
        Seasons.Entry[10] memory t = seasons.topOf(0);
        assertEq(t[0].wallet, alice);
        assertEq(t[0].points, 126);
        assertEq(t[1].wallet, carol);
        assertEq(t[1].points, 80);
        assertEq(t[2].wallet, bob);
        assertEq(t[2].points, 45);
        vm.expectRevert();
        seasons.record(1);
    }

    function test_onlyApprovedPleasScore() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        vm.expectRevert(abi.encodeWithSelector(Seasons.NotApproved.selector, id));
        seasons.record(id);
        answer(id, 0);
        vm.expectRevert(abi.encodeWithSelector(Seasons.NotApproved.selector, id));
        seasons.record(id);
    }

    function test_tenthPlaceIsEvictedByABetterWallet() public {
        for (uint256 i; i < 11; ++i) {
            seasons.record(scored(players[i], 35 + (i % 10)));
        }
        Seasons.Entry[10] memory t = seasons.topOf(0);
        assertEq(t[0].points, 44);
        // players[10] scored 35 and ties players[0]'s 35: the earlier plea keeps tenth place.
        assertEq(t[9].wallet, players[0]);
        seasons.record(scored(players[11], 36));
        t = seasons.topOf(0);
        // players[11] ties players[1] at 36 but pleaded later: it ranks just below, players[0] is out.
        assertEq(t[8].wallet, players[1]);
        assertEq(t[9].wallet, players[11]);
        for (uint256 i = 1; i < 10; ++i) {
            assertGe(t[i - 1].points, t[i].points);
        }
    }

    // ---------------------------------------------------------------- closing

    function test_closeSeasonPaysTheTopTen() public {
        // alice 3 x 42 = 126 points; carol 2 x 40 = 80; bob 45 (below 60: no prize).
        for (uint256 i; i < 3; ++i) {
            scored(alice, 42);
        }
        scored(carol, 40);
        scored(carol, 40);
        scored(bob, 45);
        assertGt(hook.totalPrize(), 0); // the hook's prize fee feeds the pot
        imd.mint(address(seasons), 1_000e18);
        seasons.checkpoint(); // attribute this direct donation before the season ends

        liveUntil(t0() + SEASON);
        vm.expectRevert(abi.encodeWithSelector(Seasons.NotReady.selector, 0));
        seasons.closeSeason(new uint256[](0));
        skip(1 hours);

        uint256[] memory ids = new uint256[](6);
        for (uint256 i; i < 6; ++i) {
            ids[i] = i + 1;
        }
        uint256 pot = seasons.pot();
        uint256 a0 = imd.balanceOf(alice);
        uint256 c0 = imd.balanceOf(carol);
        uint256 b0 = imd.balanceOf(bob);
        seasons.closeSeason(ids);
        assertEq(imd.balanceOf(alice) - a0, pot * 2500 / 10_000);
        assertEq(imd.balanceOf(carol) - c0, pot * 1800 / 10_000);
        assertEq(imd.balanceOf(bob), b0);
        assertEq(imd.balanceOf(address(seasons)), pot - pot * 2500 / 10_000 - pot * 1800 / 10_000);
        assertTrue(seasons.closed(0));
        assertEq(seasons.nextToClose(), 1);

        vm.expectRevert(abi.encodeWithSelector(Seasons.AlreadyRecorded.selector, 1));
        seasons.record(1);
    }

    function test_secondSeasonScoresSeparately() public {
        liveUntil(t0() + SEASON + 1 hours);
        seasons.record(scored(alice, 44));
        assertEq(seasons.bestOf(1, alice)[0], 44);
        assertEq(seasons.bestOf(0, alice)[0], 0);
        seasons.closeSeason(new uint256[](0)); // season 0 is over
        assertEq(seasons.nextToClose(), 1);
    }

    function test_deathEndsTheLastSeasonAndTheRestGoesToTheWall() public {
        seasons.record(scored(alice, 42));
        scored(alice, 42);
        scored(alice, 42);
        vm.expectRevert(Seasons.NotFinished.selector);
        seasons.flushToWall();
        skip(DEADMAN + 1 hours);
        assertFalse(gate.cabalAlive());
        seasons.closeSeason(new uint256[](0)); // records nothing new; pays alice's 25%
        assertEq(seasons.nextToClose(), 1);
        vm.expectRevert(abi.encodeWithSelector(Seasons.NotReady.selector, 1));
        seasons.closeSeason(new uint256[](0)); // no season after the death
        assertTrue(seasons.finished());
        // Trading goes on: the prize share now goes to pool liquidity, not the pot.
        uint256 potBefore = seasons.pot();
        buy(bob, 10e18);
        assertEq(seasons.pot(), potBefore);
        uint256 wall = hook.retainedImd();
        seasons.flushToWall();
        assertEq(seasons.pot(), 0);
        assertEq(hook.retainedImd(), wall + potBefore);
    }

    // ---------------------------------------------------------------- guards

    function test_mainnetGuardRefusesShortTimings() public {
        vm.chainId(1);
        vm.expectRevert(CabalGate.BelowAgreedTiming.selector);
        new CabalGate(address(plea), address(intake), address(oimd), address(imd), SIGNER, 5 hours, 33 hours);
        vm.expectRevert(CabalGate.BelowAgreedTiming.selector);
        new CabalGate(address(plea), address(intake), address(oimd), address(imd), SIGNER, 15 days, 27 minutes);
        new CabalGate(address(plea), address(intake), address(oimd), address(imd), SIGNER, 15 days, 33 hours);
    }
}

/// @dev Sepolia's fast clock: 1 day = 20 minutes. Plea timings stay real.
contract FastClockTest is SeasonsTest {
    uint256 private nextScoredId = 1;

    /// @dev The ranking unit cases require up to four scores from one wallet. That cannot fit in
    /// five hours under the real four-hour cooldown. Supply approved-result fixtures for those
    /// cases; AuditRevisionTest covers real, paced approvals and closing on the manifest's clock.
    function scored(address who, uint256 score) internal override returns (uint256 id) {
        id = nextScoredId++;
        vm.mockCall(
            address(gate),
            abi.encodeCall(gate.result, (id)),
            abi.encode(who, uint8(score), true, uint64(vm.getBlockTimestamp()))
        );
        vm.mockCall(address(gate), abi.encodeCall(gate.pleaText, (id)), abi.encode("Approved ranking fixture."));
    }

    function setTimings() internal override {
        SEASON = 5 hours;
        DEADMAN = 27.5 minutes;
    }

    /// @dev Trading opens with the clock: buys happen inside the 90-minute launch window.
    function afterSeed() internal override {}

    function buySize() internal pure override returns (uint256) {
        return 20e18;
    }

    function test_fastFullCycle() public {
        seasons.record(scored(alice, 40));
        seasons.record(scored(alice, 41));
        liveUntil(t0() + 2 * SEASON);
        skip(1 hours);
        seasons.closeSeason(new uint256[](0));
        seasons.closeSeason(new uint256[](0));
        assertEq(seasons.nextToClose(), 2);
        assertFalse(gate.cabalAlive()); // an hour of silence is past the 27.5-minute dead-man
        skip(1 hours);
        seasons.closeSeason(new uint256[](0)); // season 2 ended at the death
        assertTrue(seasons.finished());
    }
}
