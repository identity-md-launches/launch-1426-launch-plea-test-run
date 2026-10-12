// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PLEA} from "src/PLEA.sol";
import {Seasons} from "src/Seasons.sol";
import {PleaDistributor} from "src/PleaDistributor.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {MockIMD} from "./utils/Mocks.sol";
import {SeasonResults, SeasonWallSink, SeasonModel} from "./utils/SeasonModel.sol";

contract SeasonHandler is Test {
    Seasons public seasons;
    SeasonResults public results;
    SeasonWallSink public wall;
    MockIMD public imd;
    IPoolManager public pm;
    address[12] public actors;
    SeasonModel.Approval[] internal approvals;
    mapping(uint256 => bytes32) public frozenRankings;
    uint256 public funded;
    uint256 public paid;
    uint256 public flushed;
    uint256 public closes;
    // Input-derived ghost ledger: a late close may spend only its own funding and prior leftovers.
    mapping(uint256 => uint256) public funding;
    uint256 public unobserved;
    uint256 public expectedRollover;
    uint256 public claimFunded;

    constructor(
        Seasons seasons_,
        SeasonResults results_,
        SeasonWallSink wall_,
        MockIMD imd_,
        IPoolManager pm_,
        address[12] memory actors_
    ) {
        seasons = seasons_;
        results = results_;
        wall = wall_;
        imd = imd_;
        pm = pm_;
        actors = actors_;
    }

    function approvePlea(uint256 actorSeed, uint256 scoreSeed, bool recordNow) external {
        if (results.diedAt() != 0) return;
        uint256 id = approvals.length + 1;
        uint256 season = (vm.getBlockTimestamp() - results.startedAt()) / 18000;
        uint8 score = uint8(bound(scoreSeed, 15, 45)); // actual approved scores can reach 70 - 55
        uint256 actor = actorSeed % 12;
        results.setResult(id, actors[actor], score, true, uint64(vm.getBlockTimestamp()));
        approvals.push(SeasonModel.Approval(id, season, actor, score, recordNow));
        if (recordNow) seasons.record(id);
    }

    function record(uint256 seed) external {
        if (approvals.length == 0) return;
        SeasonModel.Approval storage a = approvals[seed % approvals.length];
        bool already = a.recorded;
        bool closed = seasons.closed(a.season);
        if (already) vm.expectRevert(abi.encodeWithSelector(Seasons.AlreadyRecorded.selector, a.id));
        else if (closed) vm.expectRevert(abi.encodeWithSelector(Seasons.SeasonClosed.selector, a.season));
        seasons.record(a.id);
        if (!already && !closed) a.recorded = true;
    }

    function donate(uint256 raw) external {
        _donate(raw);
        checkpoint();
    }

    function donateWithoutCheckpoint(uint256 raw) external {
        _donate(raw);
    }

    function _donate(uint256 raw) internal {
        uint256 amount = bound(raw, 0, 1_000_000e18);
        imd.mint(address(this), amount);
        imd.transfer(address(seasons), amount);
        funded += amount;
        unobserved += amount;
    }

    function donateClaims(uint256 raw) external {
        uint256 amount = bound(raw, 0, 1_000_000e18);
        imd.mint(address(this), amount);
        pm.unlock(abi.encode(amount));
        funded += amount;
        claimFunded += amount;
        unobserved += amount;
        _observeFunding();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "manager only");
        uint256 amount = abi.decode(data, (uint256));
        pm.mint(address(seasons), uint256(uint160(address(imd))), amount);
        // Exercise the hook's ordering: allocate/checkpoint claims before their cash settles.
        seasons.checkpoint();
        pm.sync(Currency.wrap(address(imd)));
        imd.transfer(address(pm), amount);
        pm.settle();
        return "";
    }

    function checkpoint() public {
        seasons.checkpoint();
        _observeFunding();
    }

    function _observeFunding() internal {
        uint256 observedAt = results.diedAt() == 0 ? vm.getBlockTimestamp() : results.diedAt() - 1;
        uint256 season = (observedAt - results.startedAt()) / 18000;
        if (season < closes) expectedRollover += unobserved;
        else funding[season] += unobserved;
        unobserved = 0;
    }

    function closeOldest() external {
        uint256 season = seasons.nextToClose();
        (bool exists,, uint64 end, bool ended) = seasons.seasonBounds(season);
        bool ready = exists && ended && vm.getBlockTimestamp() >= uint256(end) + 1 hours;
        if (!ready) {
            vm.expectRevert(abi.encodeWithSelector(Seasons.NotReady.selector, season));
            seasons.closeSeason(new uint256[](0));
            return;
        }
        (SeasonModel.Approval[] memory list, uint256 n) = SeasonModel.sorted(approvals, season);
        SeasonModel.Wallet[12] memory ranking = SeasonModel.wallets(list, n);
        uint256[12] memory before;
        for (uint256 i; i < 12; ++i) {
            before[i] = imd.balanceOf(actors[i]);
        }
        uint256 pot = seasons.pot();
        _observeFunding(); // close also observes donations, in the running/final season
        uint256 budget = funding[season] + expectedRollover;
        uint256[10] memory percentages = [uint256(25), 18, 14, 11, 9, 7, 6, 4, 3, 3];
        seasons.closeSeason(new uint256[](0));
        uint256 expectedPaid;
        for (uint256 i; i < 12; ++i) {
            uint256 payout = i < 10 && ranking[i].points >= 60 ? budget * percentages[i] / 100 : 0;
            assertEq(
                imd.balanceOf(actors[ranking[i].actor]),
                before[ranking[i].actor] + payout,
                "prize recipient or share differs from batch model"
            );
            expectedPaid += payout;
        }
        assertEq(imd.balanceOf(address(seasons)), pot - expectedPaid);
        assertEq(pm.balanceOf(address(seasons), uint256(uint160(address(imd)))), 0);
        funding[season] = 0;
        expectedRollover = budget - expectedPaid;
        paid += expectedPaid;
        frozenRankings[season] = keccak256(abi.encode(seasons.topOf(season)));
        ++closes;
        assertEq(seasons.nextToClose(), closes);
    }

    function advance(uint256 raw) external {
        vm.warp(vm.getBlockTimestamp() + bound(raw, 1, 5 hours));
    }

    function endCabal() external {
        if (results.diedAt() == 0) {
            // A real dead-man transition requires time to pass: live fees/verdicts cannot occur
            // at the death timestamp. In particular, do not invent a live season at that boundary.
            vm.warp(vm.getBlockTimestamp() + 1);
            results.die();
        }
    }

    function flush() external {
        if (!seasons.finished()) {
            vm.expectRevert(Seasons.NotFinished.selector);
            seasons.flushToWall();
            return;
        }
        uint256 pot = seasons.pot();
        seasons.flushToWall();
        _observeFunding();
        expectedRollover = 0;
        flushed += pot;
        assertEq(imd.balanceOf(address(seasons)), 0);
        assertEq(imd.allowance(address(seasons), address(wall)), 0);
    }

    function assertFunding() external view {
        uint256 total = unobserved + expectedRollover;
        uint256 current = (vm.getBlockTimestamp() - results.startedAt()) / 18000;
        for (uint256 season; season <= current; ++season) {
            assertEq(seasons.seasonFees(season), funding[season], "fees moved between seasons");
            total += funding[season];
        }
        assertEq(seasons.rollover(), expectedRollover, "only unpaid shares may roll forward");
        assertEq(seasons.pot(), total, "every asset belongs to a bucket or awaits observation");
        assertEq(
            imd.balanceOf(address(pm)),
            pm.balanceOf(address(seasons), uint256(uint160(address(imd)))),
            "claims retain exact cash backing across redemptions"
        );
    }

    function assertRankings() external view {
        uint256 current = (vm.getBlockTimestamp() - results.startedAt()) / 18000;
        for (uint256 season; season <= current; ++season) {
            if (season < closes) {
                assertTrue(seasons.closed(season));
                assertEq(keccak256(abi.encode(seasons.topOf(season))), frozenRankings[season]);
            } else {
                assertFalse(seasons.closed(season));
            }
            (SeasonModel.Approval[] memory list, uint256 n) = SeasonModel.sorted(approvals, season);
            SeasonModel.Wallet[12] memory ranking = SeasonModel.wallets(list, n);
            Seasons.Entry[10] memory actual = seasons.topOf(season);
            for (uint256 i; i < 10; ++i) {
                if (ranking[i].points == 0) assertEq(actual[i].wallet, address(0));
                else assertEq(actual[i].wallet, actors[ranking[i].actor]);
                assertEq(actual[i].points, ranking[i].points);
                assertEq(actual[i].pleaId, ranking[i].newest);
            }
        }
        for (uint256 i; i < approvals.length; ++i) {
            assertEq(seasons.recorded(approvals[i].id), approvals[i].recorded);
        }
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SeasonInvariantTest is Test {
    PLEA internal token;
    Seasons internal seasons;
    SeasonResults internal results;
    SeasonWallSink internal wall;
    MockIMD internal imd;
    SeasonHandler internal handler;
    address[12] internal actors;

    function setUp() public {
        vm.warp(1791817200);
        token = new PLEA(address(this));
        results = new SeasonResults();
        imd = new MockIMD();
        seasons = new Seasons(address(token), address(results), address(imd));
        PleaDistributor drop = new PleaDistributor(address(token), address(this));
        wall = new SeasonWallSink(imd);
        token.setLauncher(address(results), address(seasons), address(drop));
        IPoolManager pm = IPoolManager(deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
        token.init(address(wall), address(pm));
        for (uint256 i; i < 12; ++i) {
            actors[i] = makeAddr(string.concat("season actor ", vm.toString(i)));
        }
        handler = new SeasonHandler(seasons, results, wall, imd, pm, actors);
        // Start with a contested, payable leaderboard. Later actions add and record in any order.
        for (uint256 i; i < 12; ++i) {
            handler.approvePlea(i, 45, true);
            handler.approvePlea(i, 30 + i, true);
        }
        handler.donate(10_000e18);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.approvePlea.selector;
        selectors[1] = handler.record.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.closeOldest.selector;
        selectors[4] = handler.advance.selector;
        selectors[5] = handler.endCabal.selector;
        selectors[6] = handler.flush.selector;
        selectors[7] = handler.donateClaims.selector;
        selectors[8] = handler.donateWithoutCheckpoint.selector;
        selectors[9] = handler.checkpoint.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_prizeMoneyIsPaidOnceOrRemainsInThePotOrWall() public view {
        uint256 balances;
        for (uint256 i; i < 12; ++i) {
            balances += imd.balanceOf(actors[i]);
        }
        assertEq(balances, handler.paid());
        assertEq(imd.balanceOf(address(wall)), handler.flushed());
        assertEq(wall.received(), handler.flushed());
        assertEq(balances + imd.balanceOf(address(wall)) + seasons.pot(), handler.funded());
        assertEq(imd.totalSupply(), handler.funded());
        assertEq(seasons.nextToClose(), handler.closes());
        handler.assertFunding();
    }

    function invariant_rankingsMatchAllRecordedApprovalsAndClosedSeasonsNeverChange() public view {
        handler.assertRankings();
    }

    function test_modelCoversPayableClosesRolloverAndFinalFlush() public {
        handler.advance(5 hours);
        handler.advance(1 hours);
        handler.donateClaims(20_000e18);
        handler.closeOldest();
        assertEq(handler.closes(), 1);
        assertGt(handler.paid(), 0);
        assertEq(seasons.seasonFees(1), 20_000e18, "future fees survive the earlier payout");
        invariant_prizeMoneyIsPaidOnceOrRemainsInThePotOrWall();
        handler.approvePlea(0, 45, false);
        handler.record(24);
        handler.endCabal();
        handler.advance(1 hours);
        handler.closeOldest();
        handler.flush();
        assertTrue(seasons.finished());
        assertEq(seasons.pot(), 0);
        invariant_prizeMoneyIsPaidOnceOrRemainsInThePotOrWall();
        invariant_rankingsMatchAllRecordedApprovalsAndClosedSeasonsNeverChange();
    }

    function test_modelCoversDelayedDonationsAndPostFlushClaims() public {
        handler.donateWithoutCheckpoint(123e18);
        handler.advance(5 hours);
        handler.checkpoint();
        assertEq(seasons.seasonFees(0), 10_000e18);
        assertEq(seasons.seasonFees(1), 123e18);
        handler.checkpoint(); // observing the same assets twice must not create revenue
        handler.advance(1);
        handler.endCabal();
        handler.advance(1 hours);
        handler.closeOldest();
        handler.closeOldest();
        handler.flush();
        handler.donateClaims(456e18);
        assertEq(seasons.rollover(), 456e18);
        invariant_prizeMoneyIsPaidOnceOrRemainsInThePotOrWall();
        handler.flush();
        uint256 flushed = handler.flushed();
        handler.flush();
        assertEq(handler.flushed(), flushed);
        assertGt(handler.claimFunded(), 0);
        invariant_prizeMoneyIsPaidOnceOrRemainsInThePotOrWall();
    }
}
