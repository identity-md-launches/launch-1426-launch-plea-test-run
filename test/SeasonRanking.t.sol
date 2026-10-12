// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PLEA} from "../src/PLEA.sol";
import {Seasons} from "../src/Seasons.sol";
import {PleaDistributor} from "../src/PleaDistributor.sol";
import {MockIMD} from "./utils/Mocks.sol";

/// @dev Approved results only; isolates permissionless ranking from swaps and oracle delivery.
contract RankingResults {
    uint256 public constant SEASON = 18000;
    uint64 public constant startedAt = 1_800_000_000;

    struct Result {
        address seller;
        uint8 score;
        bool approved;
        uint64 verdictAt;
    }

    mapping(uint256 => Result) public result;

    function approve(uint256 id, address seller, uint8 score) external {
        result[id] = Result(seller, score, true, startedAt);
    }

    function restricted() external pure returns (bool) {
        return true;
    }

    function diedAt() external pure returns (uint64) {
        return 0;
    }
}

contract SeasonRankingTest is Test {
    RankingResults gate;
    Seasons seasons;
    MockIMD imd;
    address alice = makeAddr("ranking alice");
    address bob = makeAddr("ranking bob");

    function setUp() public {
        gate = new RankingResults();
        vm.warp(gate.startedAt());
        PLEA plea = new PLEA(address(this));
        imd = new MockIMD();
        seasons = new Seasons(address(plea), address(gate), address(imd));
        PleaDistributor distributor = new PleaDistributor(address(plea), address(this));
        plea.setLauncher(address(gate), address(seasons), address(distributor));
    }

    function test_walletTieUsesNewestCountedPleaNotLastRecordedPlea() public {
        gate.approve(1, alice, 45);
        gate.approve(2, bob, 45);
        gate.approve(3, bob, 45);
        gate.approve(4, alice, 45);
        seasons.record(4);
        seasons.record(1);
        seasons.record(3);
        seasons.record(2);
        Seasons.Entry[10] memory top = seasons.topOf(0);
        assertEq(top[0].wallet, bob, "reverse recording stole a tied wallet's rank");
        assertEq(top[0].points, 90);
        assertEq(top[0].pleaId, 3);
        assertEq(top[1].wallet, alice);
        assertEq(top[1].pleaId, 4);
    }

    function test_earlierEqualScoreCanReplaceACountedPleaWithoutChangingPoints() public {
        for (uint256 id = 1; id <= 4; ++id) {
            gate.approve(id, alice, 40);
        }
        seasons.record(4);
        seasons.record(3);
        seasons.record(2);
        seasons.record(1);
        assertEq(seasons.topOf(0)[0].points, 120);
        assertEq(seasons.topOf(0)[0].pleaId, 3, "tie key includes a displaced plea");
    }

    function test_replacingALowerScoreRemovesItsIdFromTheTieKey() public {
        gate.approve(1, alice, 45);
        gate.approve(2, alice, 44);
        gate.approve(3, alice, 43);
        gate.approve(4, alice, 35);
        seasons.record(4);
        seasons.record(3);
        seasons.record(2);
        seasons.record(1);
        assertEq(seasons.topOf(0)[0].points, 132);
        assertEq(seasons.topOf(0)[0].pleaId, 3, "maximum over discarded pleas is not the tie key");
    }

    function test_closeSeasonUsesTheSameTiesForPrizes() public {
        gate.approve(1, alice, 45);
        gate.approve(2, bob, 45);
        gate.approve(3, bob, 45);
        gate.approve(4, alice, 45);
        uint256[] memory ids = new uint256[](4);
        (ids[0], ids[1], ids[2], ids[3]) = (4, 1, 3, 2);
        imd.mint(address(seasons), 1000e18);
        seasons.checkpoint();
        vm.warp(uint256(gate.startedAt()) + gate.SEASON() + 1 hours);
        seasons.closeSeason(ids);
        assertEq(imd.balanceOf(bob), 250e18, "wrong wallet received first prize");
        assertEq(imd.balanceOf(alice), 180e18);
        assertEq(seasons.pot(), 570e18);
    }

    /// @dev Independent batch model: sort all 60 results, take each wallet's first three, then
    /// compare with the contract's online top ten after a random recording permutation.
    function testFuzz_rankingsMatchSortedResultsInAnyRecordOrder(uint256 seed) public {
        uint256 count = 60;
        uint8[] memory scores = new uint8[](count);
        uint256[] memory sorted = new uint256[](count);
        uint256[] memory order = new uint256[](count);
        address[12] memory wallets;
        for (uint256 w; w < 12; ++w) {
            wallets[w] = makeAddr(string.concat("rank wallet ", vm.toString(w)));
        }
        for (uint256 i; i < count; ++i) {
            scores[i] = uint8(35 + uint256(keccak256(abi.encode(seed, i))) % 11);
            gate.approve(i + 1, wallets[i % 12], scores[i]);
            order[i] = i;
            uint256 at = i;
            while (at > 0 && scores[sorted[at - 1]] < scores[i]) {
                sorted[at] = sorted[at - 1];
                --at;
            }
            sorted[at] = i; // stable sorting preserves older ids for equal scores
        }
        for (uint256 i = count; i > 1; --i) {
            uint256 j = uint256(keccak256(abi.encode(seed, "shuffle", i))) % i;
            (order[i - 1], order[j]) = (order[j], order[i - 1]);
        }
        for (uint256 i; i < count; ++i) {
            seasons.record(order[i] + 1);
        }

        Seasons.Entry[12] memory expected;
        uint8[12] memory taken;
        for (uint256 i; i < count; ++i) {
            uint256 id = sorted[i];
            uint256 w = id % 12;
            if (taken[w] == 3) continue;
            ++taken[w];
            expected[w].wallet = wallets[w];
            expected[w].points += scores[id];
            if (id + 1 > expected[w].pleaId) expected[w].pleaId = uint64(id + 1);
        }
        for (uint256 i; i < 12; ++i) {
            for (uint256 j = i + 1; j < 12; ++j) {
                if (
                    expected[j].points > expected[i].points
                        || (expected[j].points == expected[i].points && expected[j].pleaId < expected[i].pleaId)
                ) (expected[i], expected[j]) = (expected[j], expected[i]);
            }
        }
        Seasons.Entry[10] memory top = seasons.topOf(0);
        for (uint256 i; i < 10; ++i) {
            assertEq(top[i].wallet, expected[i].wallet, "wallet order");
            assertEq(top[i].points, expected[i].points, "points");
            assertEq(top[i].pleaId, expected[i].pleaId, "wallet tie key");
        }
    }
}
