// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PLEA} from "src/PLEA.sol";
import {Seasons} from "src/Seasons.sol";
import {PleaDistributor} from "src/PleaDistributor.sol";
import {SeasonResults, SeasonWallSink} from "./utils/SeasonModel.sol";

contract SelectivePrizeAsset is ERC20 {
    address public blocked;
    bool public returnFalse;

    constructor() ERC20("Selective quote", "Q") {}

    function mint(address who, uint256 amount) external {
        _mint(who, amount);
    }

    function blockRecipient(address who, bool falseReturn) external {
        blocked = who;
        returnFalse = falseReturn;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blocked) {
            if (returnFalse) return false;
            revert("recipient blocked");
        }
        return super.transfer(to, amount);
    }
}

/// forge-config: default.fuzz.runs = 256
contract SeasonAdversarialTest is Test {
    PLEA internal token;
    Seasons internal seasons;
    SeasonResults internal results;
    SeasonWallSink internal wall;
    SelectivePrizeAsset internal quote;
    address internal alice = makeAddr("prize alice");
    address internal bob = makeAddr("prize bob");

    function setUp() public {
        vm.warp(1791817200);
        token = new PLEA(address(this));
        results = new SeasonResults();
        quote = new SelectivePrizeAsset();
        seasons = new Seasons(address(token), address(results), address(quote));
        PleaDistributor drop = new PleaDistributor(address(token), address(this));
        wall = new SeasonWallSink(quote);
        token.setLauncher(address(results), address(seasons), address(drop));
        // Seasons now includes redeemable IMD claims in its assets, so its manager must be live.
        token.init(address(wall), deployCode("PoolManager.sol:PoolManager", abi.encode(address(this))));
    }

    function approve(uint256 id, address seller, uint8 score) internal {
        results.setResult(id, seller, score, true, uint64(vm.getBlockTimestamp()));
    }

    function ready() internal {
        vm.warp(uint256(results.startedAt()) + 18000 + 1 hours);
    }

    function test_closeBeforeGraceRollsBackItsBatchRecording() public {
        approve(1, alice, 45);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.warp(uint256(results.startedAt()) + 18000 + 1 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(Seasons.NotReady.selector, uint256(0)));
        seasons.closeSeason(ids);
        assertFalse(seasons.recorded(1));
        assertFalse(seasons.closed(0));
        assertEq(seasons.nextToClose(), 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        seasons.closeSeason(ids);
        assertTrue(seasons.recorded(1));
        assertTrue(seasons.closed(0));
    }

    function test_batchIgnoresUnknownDeniedAndRepeatedIdsButCannotReopenASeason() public {
        approve(1, alice, 45);
        approve(2, alice, 45);
        results.setResult(3, bob, 45, false, uint64(vm.getBlockTimestamp()));
        uint256[] memory ids = new uint256[](5);
        (ids[0], ids[1], ids[2], ids[3], ids[4]) = (1, 1, 3, 999, 2);
        quote.mint(address(seasons), 100e18);
        seasons.checkpoint();
        ready();
        seasons.closeSeason(ids);
        assertEq(quote.balanceOf(alice), 25e18);
        assertFalse(seasons.recorded(3));
        assertFalse(seasons.recorded(999));
        vm.expectRevert(abi.encodeWithSelector(Seasons.NotReady.selector, uint256(1)));
        seasons.closeSeason(ids);
        assertEq(quote.balanceOf(alice), 25e18);
        assertEq(seasons.nextToClose(), 1);
    }

    function test_recordRejectsDenialsDuplicatesAndLateApprovals() public {
        results.setResult(1, alice, 44, false, uint64(vm.getBlockTimestamp()));
        vm.expectRevert(abi.encodeWithSelector(Seasons.NotApproved.selector, uint256(1)));
        seasons.record(1);
        approve(2, alice, 45);
        seasons.record(2);
        vm.expectRevert(abi.encodeWithSelector(Seasons.AlreadyRecorded.selector, uint256(2)));
        seasons.record(2);
        approve(3, bob, 45);
        ready();
        seasons.closeSeason(new uint256[](0));
        vm.expectRevert(abi.encodeWithSelector(Seasons.SeasonClosed.selector, uint256(0)));
        seasons.record(3);
        assertFalse(seasons.recorded(3));
    }

    function testFuzz_failedPrizeDoesNotBlockOthersAndUnpaidShareReachesWall(bool falseReturn) public {
        approve(1, alice, 45);
        approve(2, alice, 45);
        approve(3, bob, 45);
        approve(4, bob, 45);
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            ids[i] = i + 1;
        }
        quote.mint(address(seasons), 100e18);
        seasons.checkpoint();
        quote.blockRecipient(alice, falseReturn);
        vm.warp(uint256(results.startedAt()) + 18000);
        results.die(); // no season starts at the exact death boundary
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        seasons.closeSeason(ids);
        assertEq(quote.balanceOf(alice), 0);
        assertEq(quote.balanceOf(bob), 18e18);
        assertEq(seasons.pot(), 82e18);
        assertTrue(seasons.finished());
        seasons.flushToWall();
        assertEq(wall.received(), 82e18);
        assertEq(seasons.pot(), 0);
        seasons.flushToWall();
        assertEq(wall.received(), 82e18, "flush is idempotent with no new funding");
        quote.mint(address(seasons), 1);
        seasons.flushToWall();
        assertEq(wall.received(), 82e18 + 1);
    }

    function testFuzz_prizeRoundingConservesAnOddSizedPot(uint256 rawPot) public {
        uint256 pot = bound(rawPot, 1, 1_000_000_000e18);
        quote.mint(address(seasons), pot);
        seasons.checkpoint();
        uint256[] memory ids = new uint256[](20);
        address[10] memory actors;
        for (uint256 i; i < 10; ++i) {
            actors[i] = makeAddr(string.concat("rounding wallet ", vm.toString(i)));
            approve(2 * i + 1, actors[i], 45);
            approve(2 * i + 2, actors[i], 45);
            ids[2 * i] = 2 * i + 1;
            ids[2 * i + 1] = 2 * i + 2;
        }
        ready();
        seasons.closeSeason(ids);
        uint256[10] memory percent = [uint256(25), 18, 14, 11, 9, 7, 6, 4, 3, 3];
        uint256 paid;
        for (uint256 i; i < 10; ++i) {
            assertEq(quote.balanceOf(actors[i]), pot * percent[i] / 100);
            paid += quote.balanceOf(actors[i]);
        }
        assertEq(paid + seasons.pot(), pot);
        assertLt(seasons.pot(), 10, "at most nine wei of rounding dust for ten paid shares");
    }

    function test_prizesRequireSixtyPoints() public {
        approve(1, alice, 30);
        approve(2, alice, 29);
        approve(3, bob, 30);
        approve(4, bob, 30);
        uint256[] memory ids = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            ids[i] = i + 1;
        }
        quote.mint(address(seasons), 100e18);
        seasons.checkpoint();
        ready();
        seasons.closeSeason(ids);
        assertEq(quote.balanceOf(alice), 0);
        assertEq(quote.balanceOf(bob), 25e18);
        assertEq(seasons.pot(), 75e18);
    }

    function test_flushBeforeFinalCloseCannotMoveAnyFunds() public {
        quote.mint(address(seasons), 100e18);
        vm.expectRevert(Seasons.NotFinished.selector);
        seasons.flushToWall();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        results.die();
        vm.expectRevert(Seasons.NotFinished.selector);
        seasons.flushToWall();
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        seasons.closeSeason(new uint256[](0));
        seasons.flushToWall();
        assertEq(quote.balanceOf(address(wall)), 100e18);
    }
}
