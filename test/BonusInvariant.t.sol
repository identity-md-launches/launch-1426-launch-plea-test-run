// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PLEA} from "../src/PLEA.sol";
import {Seasons} from "../src/Seasons.sol";
import {PleaDistributor} from "../src/PleaDistributor.sol";
import {MockIMD} from "./utils/Mocks.sol";

/// @dev A gate stand-in with free scores, a settable death and the real `restricted` rule.
contract BonusGate {
    uint256 public constant SEASON = 18000;
    uint64 public immutable startedAt;
    uint64 public diedAt;

    struct Result {
        address seller;
        uint8 score;
        bool approved;
        uint64 verdictAt;
    }

    mapping(uint256 => Result) public result;

    constructor(uint64 startedAt_) {
        startedAt = startedAt_;
    }

    function approve(uint256 id, address wallet, uint8 score) external {
        result[id] = Result(wallet, score, true, uint64(block.timestamp));
    }

    function die() external {
        diedAt = uint64(block.timestamp);
    }

    function cabalAlive() external view returns (bool) {
        return diedAt == 0;
    }

    function restricted() external view returns (bool) {
        return diedAt == 0;
    }
}

/// @dev Stand-in hook: receives the 87% and any IMD the final flush sends to the wall.
contract BonusWall {
    MockIMD public immutable imd;

    constructor(MockIMD imd_) {
        imd = imd_;
    }

    function fundWall(uint256 amount) external {
        imd.transferFrom(msg.sender, address(this), amount);
    }
}

abstract contract BonusFixture is Test {
    uint256 constant BONUS = 5_000_000e18;
    uint256 constant BONUS_TOTAL = 30_000_000e18;
    uint64 constant T0 = 1_792_162_800;

    BonusGate gate;
    Seasons seasons;
    MockIMD imd;
    PLEA plea;
    BonusWall wall;
    PleaDistributor distributor;
    address pm;

    function setUp() public virtual {
        vm.warp(T0);
        gate = new BonusGate(T0);
        imd = new MockIMD();
        pm = deployCode("PoolManager.sol:PoolManager", abi.encode(address(this)));
        plea = new PLEA(address(this));
        seasons = new Seasons(address(plea), address(gate), address(imd));
        distributor = new PleaDistributor(address(plea), address(this));
        wall = new BonusWall(imd);
        plea.setLauncher(address(gate), address(seasons), address(distributor));
        plea.init(address(wall), pm);
    }

    function share(uint256 rank) internal pure returns (uint256) {
        uint16[10] memory bps = [2500, 1800, 1400, 1100, 900, 700, 600, 400, 300, 300];
        return BONUS * bps[rank] / 10_000;
    }

    function close() internal {
        seasons.closeSeason(new uint256[](0));
    }

    function atSeasonClose(uint256 season) internal {
        vm.warp(T0 + (season + 1) * gate.SEASON() + 1 hours);
    }
}

/// @notice Drives Seasons through random approvals, closes, deaths, donations and flushes, and
/// checks every close against what the ranking says it must pay.
contract BonusHandler is Test {
    uint256 constant BONUS = 5_000_000e18;

    BonusGate public gate;
    Seasons public seasons;
    PLEA public plea;
    address public distributor;

    address[] public actors;
    uint256 public nextId = 1;
    uint256 public donated;
    uint256 public bonusClosed; // bonus seasons closed (0..6)
    bool public flushed;
    uint256 public maxPerWallet;
    uint256 public calls;

    constructor(BonusGate gate_, Seasons seasons_, PLEA plea_, address distributor_) {
        gate = gate_;
        seasons = seasons_;
        plea = plea_;
        distributor = distributor_;
        for (uint256 i; i < 13; ++i) {
            actors.push(makeAddr(string.concat("bonus actor ", vm.toString(i))));
        }
        // A seller whose PLEA transfer reverts while the Cabal watches: the gate itself.
        actors.push(address(gate_));
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function approve(uint256 actorSeed, uint256 scoreSeed) external {
        ++calls;
        if (gate.diedAt() != 0) return;
        address who = actors[bound(actorSeed, 0, actors.length - 1)];
        uint8 score = uint8(bound(scoreSeed, 0, 45));
        uint256 id = nextId++;
        gate.approve(id, who, score);
        seasons.record(id);
    }

    function advance(uint256 raw) external {
        ++calls;
        skip(bound(raw, 1, 2 * gate.SEASON()));
    }

    function die() external {
        ++calls;
        if (gate.diedAt() == 0) gate.die();
    }

    function donate(uint256 raw) external {
        ++calls;
        uint256 amount = bound(raw, 1, 1_000e18);
        if (plea.balanceOf(distributor) < amount) return;
        vm.prank(distributor); // an exempt sender
        plea.transfer(address(seasons), amount);
        donated += amount;
    }

    function close() external {
        ++calls;
        uint256 season = seasons.nextToClose();
        (bool exists,, uint64 end, bool ended) = seasons.seasonBounds(season);
        if (!exists || !ended || block.timestamp < uint256(end) + seasons.CLOSE_GRACE()) {
            vm.expectRevert(abi.encodeWithSelector(Seasons.NotReady.selector, season));
            seasons.closeSeason(new uint256[](0));
            return;
        }
        Seasons.Entry[10] memory t = seasons.topOf(season);
        bool restricted = plea.restricted();
        uint256[10] memory before;
        for (uint256 i; i < 10; ++i) {
            if (t[i].wallet != address(0)) before[i] = plea.balanceOf(t[i].wallet);
        }
        uint256 held = plea.balanceOf(address(seasons));
        uint256 burned = seasons.bonusBurned();

        seasons.closeSeason(new uint256[](0));

        uint256 paid;
        for (uint256 i; i < 10; ++i) {
            address w = t[i].wallet;
            if (w == address(0)) continue;
            uint256 expected;
            if (season < 6 && t[i].points >= 60 && !(restricted && w == address(gate))) {
                expected = BONUS * _bps(i) / 10_000;
            }
            assertEq(plea.balanceOf(w) - before[i], expected, "bonus share");
            paid += expected;
        }
        if (season < 6) {
            ++bonusClosed;
            assertEq(held - plea.balanceOf(address(seasons)), BONUS, "a bonus season spends exactly its bonus");
            assertEq(seasons.bonusBurned() - burned, BONUS - paid, "the unpaid rest is burned");
        } else {
            assertEq(plea.balanceOf(address(seasons)), held, "later seasons pay no PLEA");
            assertEq(seasons.bonusBurned(), burned);
        }
        for (uint256 i; i < actors.length; ++i) {
            if (actors[i] == address(gate)) continue;
            uint256 b = plea.balanceOf(actors[i]);
            if (b > maxPerWallet) maxPerWallet = b;
        }
    }

    function flush() external {
        ++calls;
        if (!seasons.finished()) {
            vm.expectRevert(Seasons.NotFinished.selector);
            seasons.flushToWall();
            return;
        }
        uint256 held = plea.balanceOf(address(seasons));
        uint256 burned = seasons.bonusBurned();
        uint256 supply = plea.totalSupply();
        seasons.flushToWall();
        flushed = true;
        assertEq(plea.balanceOf(address(seasons)), 0, "flush leaves no PLEA");
        assertEq(seasons.bonusBurned() - burned, held, "flush burns all it held");
        assertEq(supply - plea.totalSupply(), held);
    }

    /// Nobody but Seasons' own logic can take its PLEA: no approval, no withdraw path.
    function pull(uint256 actorSeed, uint256 raw) external {
        ++calls;
        address who = actors[bound(actorSeed, 0, actors.length - 1)];
        uint256 amount = bound(raw, 1, BONUS);
        assertEq(plea.allowance(address(seasons), who), 0);
        vm.prank(who);
        vm.expectRevert();
        plea.transferFrom(address(seasons), who, amount);
    }

    function _bps(uint256 rank) internal pure returns (uint256) {
        uint16[10] memory bps = [2500, 1800, 1400, 1100, 900, 700, 600, 400, 300, 300];
        return bps[rank];
    }

    function sumActorBalances() external view returns (uint256 s) {
        for (uint256 i; i < actors.length; ++i) {
            s += plea.balanceOf(actors[i]);
        }
    }
}

contract BonusInvariantTest is BonusFixture {
    BonusHandler handler;
    uint256 distributorStart;

    function setUp() public override {
        super.setUp();
        handler = new BonusHandler(gate, seasons, plea, address(distributor));
        distributorStart = plea.balanceOf(address(distributor));
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = BonusHandler.approve.selector;
        selectors[1] = BonusHandler.advance.selector;
        selectors[2] = BonusHandler.die.selector;
        selectors[3] = BonusHandler.donate.selector;
        selectors[4] = BonusHandler.close.selector;
        selectors[5] = BonusHandler.flush.selector;
        selectors[6] = BonusHandler.pull.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// The handler reaches paid closes, burns, death and the final flush.
    function test_handlerReachesPaidClosesDeathAndFlush() public {
        handler.approve(0, 45);
        handler.approve(0, 45);
        handler.approve(13, 45); // the gate as a seller
        handler.approve(13, 45);
        handler.donate(500e18);
        handler.advance(gate.SEASON() + 1 hours);
        handler.close();
        assertEq(handler.bonusClosed(), 1);
        assertEq(plea.balanceOf(handler.actors(0)), share(0));
        handler.die();
        handler.advance(2 hours);
        handler.flush(); // season 1 still open
        assertFalse(handler.flushed());
        handler.close();
        assertTrue(seasons.finished());
        handler.flush();
        assertTrue(handler.flushed());
        handler.pull(0, 1);
        invariant_bonusIsHeldPaidOrBurned();
        invariant_supplyFallsOnlyByTheBurnedBonus();
        invariant_openBonusSeasonsStayFunded();
        invariant_flushedSeasonsStayFinished();
    }

    /// Every bonus PLEA is still held by Seasons, was paid to a ranked wallet, or was burned.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_bonusIsHeldPaidOrBurned() public view {
        assertEq(
            plea.balanceOf(address(seasons)) + handler.sumActorBalances() + seasons.bonusBurned(),
            BONUS_TOTAL + handler.donated()
        );
        assertEq(distributorStart - plea.balanceOf(address(distributor)), handler.donated());
    }

    /// The fixed supply only falls, and only by what Seasons burned.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_supplyFallsOnlyByTheBurnedBonus() public view {
        assertEq(plea.totalSupply(), plea.TOTAL_SUPPLY() - seasons.bonusBurned());
        assertLe(seasons.bonusBurned(), BONUS_TOTAL + handler.donated());
    }

    /// Until the final flush, every bonus season not yet closed is still fully funded.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_openBonusSeasonsStayFunded() public view {
        uint256 closedBonus = seasons.nextToClose() < 6 ? seasons.nextToClose() : 6;
        assertEq(closedBonus, handler.bonusClosed());
        if (!handler.flushed()) {
            assertGe(plea.balanceOf(address(seasons)), (6 - closedBonus) * BONUS);
        }
        // A wallet earns at most first place in each of the six bonus seasons.
        assertLe(handler.maxPerWallet(), 6 * share(0));
    }

    /// Once flushed, Seasons holds no PLEA unless someone donated since, and it never reopens.
    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 64
    function invariant_flushedSeasonsStayFinished() public view {
        if (handler.flushed()) {
            assertTrue(seasons.finished());
            assertLe(plea.balanceOf(address(seasons)), handler.donated());
        }
    }
}

/// @notice Edge cases of the bonus split pinned as plain and fuzzed unit tests.
contract BonusEdgeTest is BonusFixture {
    address[10] wallets;

    function setUp() public override {
        super.setUp();
        for (uint256 i; i < 10; ++i) {
            wallets[i] = makeAddr(string.concat("edge ", vm.toString(i)));
        }
    }

    uint256 id = 1;

    function give(address who, uint8 score) internal {
        gate.approve(id, who, score);
        seasons.record(id++);
    }

    function test_tenQualifiersReceiveTheWholeBonusAndNothingBurns() public {
        for (uint256 i; i < 10; ++i) {
            give(wallets[i], 45);
            give(wallets[i], uint8(44 - i)); // 89..80 points, distinct ranks
        }
        atSeasonClose(0);
        close();
        uint256 total;
        for (uint256 i; i < 10; ++i) {
            assertEq(plea.balanceOf(wallets[i]), share(i), "rank share");
            total += share(i);
        }
        assertEq(total, BONUS, "shares sum to the bonus");
        assertEq(seasons.bonusBurned(), 0);
        assertEq(plea.balanceOf(address(seasons)), 5 * BONUS);
    }

    function test_sixtyPointsQualifiesFiftyNineDoesNot() public {
        give(wallets[0], 20);
        give(wallets[0], 20);
        give(wallets[0], 20); // 60
        give(wallets[1], 20);
        give(wallets[1], 20);
        give(wallets[1], 19); // 59
        atSeasonClose(0);
        close();
        assertEq(plea.balanceOf(wallets[0]), share(0));
        assertEq(plea.balanceOf(wallets[1]), 0, "59 points earns no bonus");
        assertEq(seasons.bonusBurned(), BONUS - share(0));
    }

    function test_onlyTheBestThreePleasCount() public {
        for (uint256 i; i < 10; ++i) {
            give(wallets[0], 19); // ten weak pleas: 57 points, not 190
        }
        atSeasonClose(0);
        close();
        assertEq(plea.balanceOf(wallets[0]), 0);
        assertEq(seasons.bonusBurned(), BONUS);
    }

    function test_eleventhWalletIsNotPaidAndCannotDisplaceRankTen() public {
        for (uint256 i; i < 10; ++i) {
            give(wallets[i], 45);
            give(wallets[i], 30);
        }
        address late = makeAddr("eleventh");
        give(late, 45);
        give(late, 30); // equal points, later plea: ranks after the ten
        atSeasonClose(0);
        close();
        assertEq(plea.balanceOf(late), 0);
        assertEq(plea.balanceOf(wallets[9]), share(9));
        assertEq(seasons.bonusBurned(), 0);
    }

    function test_closingTwiceCannotPayASeasonsBonusTwice() public {
        give(wallets[0], 45);
        give(wallets[0], 45);
        atSeasonClose(0);
        close();
        vm.expectRevert(abi.encodeWithSelector(Seasons.NotReady.selector, 1));
        close();
        assertEq(plea.balanceOf(wallets[0]), share(0));
        assertEq(plea.balanceOf(address(seasons)), 5 * BONUS);
    }

    function test_closeWithinTheGraceHourIsRefused() public {
        give(wallets[0], 45);
        give(wallets[0], 45);
        vm.warp(T0 + gate.SEASON() + 1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(Seasons.NotReady.selector, 0));
        close();
        assertEq(plea.balanceOf(address(seasons)), BONUS_TOTAL);
        skip(1);
        close();
        assertEq(plea.balanceOf(wallets[0]), share(0));
    }

    function test_lateApprovalListedAtCloseStillEarnsTheBonus() public {
        gate.approve(77, wallets[0], 45);
        gate.approve(78, wallets[0], 45);
        gate.approve(79, wallets[1], 45); // approved in season 0, never recorded
        atSeasonClose(0);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 77;
        ids[1] = 78;
        seasons.closeSeason(ids);
        assertEq(plea.balanceOf(wallets[0]), share(0));
        vm.expectRevert(abi.encodeWithSelector(Seasons.AlreadyRecorded.selector, 77));
        seasons.record(77);
        vm.expectRevert(abi.encodeWithSelector(Seasons.SeasonClosed.selector, 0));
        seasons.record(79); // too late: the season's bonus is settled
        assertEq(plea.balanceOf(wallets[1]), 0);
    }

    function test_deathBeforeTradingSeasonZeroEndsBurnsEverythingButSeasonZero() public {
        give(wallets[0], 45);
        give(wallets[0], 45);
        skip(10);
        gate.die();
        skip(1 hours);
        close();
        assertTrue(seasons.finished());
        assertEq(plea.balanceOf(address(seasons)), 5 * BONUS);
        seasons.flushToWall();
        assertEq(plea.balanceOf(address(seasons)), 0);
        assertEq(seasons.bonusBurned(), BONUS_TOTAL - share(0));
        assertEq(plea.totalSupply(), plea.TOTAL_SUPPLY() - BONUS_TOTAL + share(0));
        // flush is idempotent once empty
        seasons.flushToWall();
        assertEq(seasons.bonusBurned(), BONUS_TOTAL - share(0));
    }

    function test_bonusPaidAfterDeathIsFreelyTransferable() public {
        give(wallets[0], 45);
        give(wallets[0], 45);
        skip(10);
        gate.die();
        skip(1 hours);
        close();
        vm.prank(wallets[0]);
        plea.transfer(pm, share(0)); // no Cabal, no restriction, even to the PoolManager
        assertEq(plea.balanceOf(pm), share(0));
    }

    function test_gateAsSellerForfeitsWhileWatchedButIsPaidAfterDeath() public {
        give(address(gate), 45);
        give(address(gate), 45);
        atSeasonClose(0);
        close(); // restricted: direct sends to the gate revert, so the share is burned
        assertEq(plea.balanceOf(address(gate)), 0);
        assertEq(seasons.bonusBurned(), BONUS);
        give(address(gate), 45);
        give(address(gate), 45);
        skip(10);
        gate.die();
        skip(1 hours);
        close();
        assertEq(plea.balanceOf(address(gate)), share(0));
    }

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_anyRankingPaysPlusBurnsExactlyTheBonus(uint256 seed) public {
        uint256 n = bound(seed, 0, 15);
        address[] memory ws = new address[](n);
        for (uint256 i; i < n; ++i) {
            ws[i] = makeAddr(string.concat("fz ", vm.toString(i)));
            uint256 pleas = bound(uint256(keccak256(abi.encode(seed, i))), 1, 4);
            for (uint256 k; k < pleas; ++k) {
                give(ws[i], uint8(uint256(keccak256(abi.encode(seed, i, k))) % 46));
            }
        }
        atSeasonClose(0);
        uint256 supply = plea.totalSupply();
        close();
        uint256 paid;
        for (uint256 i; i < n; ++i) {
            paid += plea.balanceOf(ws[i]);
        }
        assertEq(paid + seasons.bonusBurned(), BONUS);
        assertEq(supply - plea.totalSupply(), seasons.bonusBurned());
        assertEq(plea.balanceOf(address(seasons)), 5 * BONUS);
        // Every payee qualified and is ranked.
        Seasons.Entry[10] memory t = seasons.topOf(0);
        for (uint256 i; i < 10; ++i) {
            if (t[i].wallet == address(0)) continue;
            uint256 expected = t[i].points >= 60 ? share(i) : 0;
            assertEq(plea.balanceOf(t[i].wallet), expected);
        }
    }
}
