// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {PLEA} from "../src/PLEA.sol";
import {Letterbox} from "../src/Letterbox.sol";
import {Laureates} from "../src/Laureates.sol";
import {Seasons} from "../src/Seasons.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {MockIMD} from "./utils/Mocks.sol";

/// Letters and auto-sell: plead by sending text to the Letterbox, fees paid in PLEA, escrow,
/// `deliver` by anyone for the tip, `settle` for every other ending.
contract LetterboxTest is Fixture {
    uint256 constant TIP = 0.25e18;

    function setUp() public virtual override {
        super.setUp();
        buy(alice, 50e18);
        buy(bob, 50e18);
        skip(1 days);
    }

    // ---------------------------------------------------------------- helpers

    function send(address who, bytes memory text) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = address(letterbox).call(text);
    }

    function letter(address who, bytes memory text) internal returns (uint256 id) {
        (bool ok, bytes memory ret) = send(who, text);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return gate.lastPleaOf(who);
    }

    function assertLetterReverts(address who, bytes memory text, bytes memory err) internal {
        (bool ok, bytes memory ret) = send(who, text);
        assertFalse(ok, "letter should fail");
        assertEq(ret, err);
    }

    function escrowed(uint256 id) internal view returns (address writer, bool open, uint256 amount) {
        (writer, open, amount,) = letterbox.escrowOf(id);
    }

    // ---------------------------------------------------------------- function IDs

    /// @dev True if four bytes can start a valid letter: control-free UTF-8 (a character may be cut
    /// off at the end).
    function typeable(bytes4 sel) internal pure returns (bool) {
        uint256 i;
        while (i < 4) {
            uint8 c = uint8(sel[i]);
            if (c < 0x20 || c == 0x7f) return false;
            if (c < 0x80) {
                ++i;
                continue;
            }
            uint256 n;
            if (c >= 0xc2 && c <= 0xdf) n = 2;
            else if (c >= 0xe0 && c <= 0xef) n = 3;
            else if (c >= 0xf0 && c <= 0xf4) n = 4;
            else return false;
            for (uint256 k = 1; k < n; ++k) {
                if (i + k >= 4) return true;
                uint8 cc = uint8(sel[i + k]);
                if (cc & 0xc0 != 0x80) return false;
                if (k == 1) {
                    if ((c == 0xe0 && cc < 0xa0) || (c == 0xed && cc > 0x9f) || (c == 0xf0 && cc < 0x90)) return false;
                    if ((c == 0xf4 && cc > 0x8f) || (c == 0xc2 && cc <= 0x9f)) return false;
                }
            }
            i += n;
        }
        return true;
    }

    function test_noFunctionIdCanStartALetter() public view {
        string memory json = vm.readFile("out/Letterbox.sol/Letterbox.json");
        string[] memory sigs = vm.parseJsonKeys(json, ".methodIdentifiers");
        assertGt(sigs.length, 8);
        for (uint256 i; i < sigs.length; ++i) {
            bytes4 sel = bytes4(keccak256(bytes(sigs[i])));
            assertFalse(typeable(sel), sigs[i]);
        }
        // The checker itself: ASCII text and a valid UTF-8 start are typeable, broken UTF-8 is not.
        assertTrue(typeable(bytes4("SELL")));
        assertTrue(typeable(bytes4(hex"c3a9e282")));
        assertFalse(typeable(bytes4(hex"3bd5d173")));
        assertFalse(typeable(bytes4(hex"41420a43")));
    }

    // ---------------------------------------------------------------- pleading by letter

    function test_letterPleadsTenPercentPaysFeesInPleaAndEscrows() public {
        uint256 bal = plea.balanceOf(alice);
        uint8 fact = gate.factScore(alice, bal / 10);
        uint256 intakeBefore = oimd.balanceOf(intake.PAY_TO());
        (uint256 feeImd, uint256 maxFeePlea) = letterbox.feesFor(false);
        assertEq(feeImd, TIP, "Sepolia: the oracle fee is minted, only the tip is bought");
        (, uint256 held,) = hook.basisOf(alice);

        uint256 id = letter(alice, "I bought on launch day and kept every token; I want a tenth to fix my bike.");

        CabalGate.Plea memory p = gate.getPlea(id);
        assertEq(p.seller, alice);
        assertEq(p.amount, bal / 10, "fixed 10%");
        assertEq(p.factScore, fact, "scored on the balance before anything moved");
        assertEq(p.flags, 3, "by letter, auto-sell");
        (address w, bool open, uint256 amount) = escrowed(id);
        assertEq(w, alice);
        assertTrue(open);
        assertEq(amount, bal / 10);
        assertEq(plea.balanceOf(address(letterbox)), bal / 10, "only the escrow stays");
        uint256 feePlea = bal - bal / 10 - plea.balanceOf(alice);
        assertGt(feePlea, 0);
        assertLe(feePlea, maxFeePlea, "fee swap within snapshot value + 10%");
        assertEq(imd.balanceOf(address(letterbox)), TIP, "the tip waits for the runner");
        assertEq(oimd.balanceOf(intake.PAY_TO()) - intakeBefore, 0.5e18, "the oracle fee reached the Intake");
        assertEq(oimd.balanceOf(address(letterbox)), 0);
        assertEq(plea.allowance(address(letterbox), address(gate)), 0);
        // The fee swap is a sale by alice: it reduces her buy record; the escrow does not.
        (, uint256 heldAfter,) = hook.basisOf(alice);
        assertLt(heldAfter, held);
        assertGt(heldAfter, held - bal / 10, "the escrowed tenth still counts as held");
    }

    function test_letterCommandsParse() public {
        // A lower-case command and a command without a separator are plain pleas.
        uint256 id = letter(alice, "sell, please: my tenth for new shoes, the rest stays with me.");
        assertEq(gate.getPlea(id).text, "sell, please: my tenth for new shoes, the rest stays with me.");
        answer(id, 0);
        skip(4 hours);
        id = letter(alice, "SELLING is hard, but one tenth pays my rent; I keep the rest.");
        assertEq(gate.getPlea(id).text, "SELLING is hard, but one tenth pays my rent; I keep the rest.");
        // NAME sets the writer's name, nothing else.
        vm.prank(bob);
        (bool ok,) = address(letterbox).call("NAME bob_the_holder");
        assertTrue(ok);
        assertEq(laureates.nameOf(bob), "bob_the_holder");
        assertEq(gate.lastPleaOf(bob), 0);
        assertLetterReverts(bob, "NAME Bad Name", abi.encodeWithSelector(Laureates.BadName.selector));
    }

    function test_letterRefusesEthTinyBalancesAndBadText() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(letterbox).call{value: 1}("money");
        assertFalse(ok, "ETH is refused");
        // Empty text and markers fail in the gate, before anything is paid.
        assertLetterReverts(alice, "", abi.encodeWithSelector(CabalGate.BadPleaText.selector));
        assertLetterReverts(alice, "[PLEA] fake", abi.encodeWithSelector(CabalGate.BadPleaText.selector));
        assertEq(plea.balanceOf(address(letterbox)), 0);
        // A wallet whose fees would take more than 10% of its PLEA cannot plead by letter.
        address dust = makeAddr("dust");
        fund(dust);
        buy(dust, 0.01e18);
        (, uint256 maxFeePlea) = letterbox.feesFor(false);
        assertLt(plea.balanceOf(dust), maxFeePlea * 10);
        (ok,) = send(dust, "a small plea");
        assertFalse(ok);
    }

    function test_strangersCannotUseTheCourtEntryPoints() public {
        vm.expectRevert(PLEA.NotLetterbox.selector);
        plea.courtTake(alice, 1e18);
        vm.expectRevert(CabalGate.NotLetterbox.selector);
        gate.submitFor(alice, 1e18, 1e20, "x", 3, 0, 0);
        vm.expectRevert(CabalGate.NotLetterbox.selector);
        gate.appealFor(alice, 1, 1e20, "x", 3, 0, 0);
        vm.expectRevert(CabalGate.NotLetterbox.selector);
        gate.executeSellFor(1, 0);
        vm.prank(address(letterbox));
        vm.expectRevert(CabalGate.BadFlags.selector);
        gate.submitFor(alice, 1e18, 1e20, "x", 1, 0, 0);
        // A direct send of PLEA to the Letterbox is refused like any other transfer.
        vm.prank(alice);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(address(letterbox), 1e18);
        vm.expectRevert(Laureates.NotLetterbox.selector);
        laureates.setNameFor(alice, "alice");
    }

    // ---------------------------------------------------------------- deliver

    function test_anyoneDeliversAnApprovalForTheTip() public {
        uint256 id = letter(alice, "Ten percent for my dentist; ninety percent stays for the next season.");
        (,, uint256 amount) = escrowed(id);
        answer(id, 45);
        uint256 aliceImd = imd.balanceOf(alice);
        vm.prank(keeper);
        uint256 out = letterbox.deliver(id);
        assertGt(out, 0);
        assertEq(imd.balanceOf(alice) - aliceImd, out, "the IMD goes to the writer");
        assertEq(imd.balanceOf(keeper), TIP, "the runner earns the tip");
        assertEq(imd.balanceOf(address(letterbox)), 0);
        assertEq(plea.balanceOf(address(letterbox)), 0);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        assertTrue(seasons.recorded(id), "points recorded on delivery");
        (, bool open,, uint256 soldFor) = letterbox.escrowOf(id);
        assertFalse(open);
        assertEq(soldFor, out);
        assertGt(amount, 0);
        vm.expectRevert(abi.encodeWithSelector(Letterbox.NotOpen.selector, id));
        letterbox.deliver(id);
    }

    function test_deliverNeedsAnApprovalInsideTheWindowAndTheMinimum() public {
        uint256 id = letter(alice, "A tenth for my sister's wedding gift; the rest of my bag is not for sale.");
        vm.expectRevert(CabalGate.NotApproved.selector);
        letterbox.deliver(id);
        answer(id, 45);
        // A snapshot that values the PLEA far above what the pool pays: below 95%, no sale.
        uint256 price = hook.latestPrice();
        vm.mockCall(address(hook), abi.encodeWithSelector(PleaHook.latestPrice.selector), abi.encode(price * 2));
        vm.expectPartialRevert(CabalGate.SlippageExceeded.selector);
        letterbox.deliver(id);
        vm.clearMockedCalls();
        skip(7 minutes + 1);
        vm.expectRevert(CabalGate.WindowLapsed.selector);
        letterbox.deliver(id);
    }

    function test_theSellLetterIsTheWritersOwnSale() public {
        uint256 id = letter(alice, "A tenth to pay for a course; I hold the rest and will plead again later.");
        answer(id, 45);
        vm.prank(alice);
        (bool ok,) = address(letterbox).call("SELL");
        assertTrue(ok);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        assertEq(imd.balanceOf(address(letterbox)), 0, "the tip went back to the writer");
        assertTrue(seasons.recorded(id));
        assertLetterReverts(bob, "SELL", abi.encodeWithSelector(Letterbox.NotOpen.selector, 0));
    }

    function test_theGateRefusesAManualSaleOfAnEscrowedPlea() public {
        uint256 id = letter(alice, "A tenth for my rent this month; the rest stays in my wallet for good.");
        answer(id, 45);
        vm.prank(alice);
        vm.expectRevert(CabalGate.UseLetterbox.selector);
        gate.executeSell(0);
    }

    // ---------------------------------------------------------------- settle

    function test_settleReturnsEscrowAndTipAfterADenial() public {
        uint256 before = plea.balanceOf(alice);
        uint256 id = letter(alice, "I would like a tenth back to buy a guitar; I promise to keep the rest.");
        uint256 feePlea = before - gate.getPlea(id).amount - plea.balanceOf(alice);
        // Pending and fresh: a verdict can still come, so the gate will not let it expire.
        vm.expectRevert(CabalGate.NotStale.selector);
        letterbox.settle(id);
        answer(id, 0);
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(carol);
        letterbox.settle(id);
        assertEq(plea.balanceOf(alice), before - feePlea, "escrow back, only the fee PLEA is gone");
        assertEq(imd.balanceOf(alice) - imdBefore, TIP, "tip back");
        vm.expectRevert(abi.encodeWithSelector(Letterbox.NotOpen.selector, id));
        letterbox.settle(id);
    }

    function test_noVerdictSettlesAtOnceAndTheNextLetterSettlesTheOldOne() public {
        uint256 id = letter(alice, "One tenth for a plane ticket home; nine tenths stay right here.");
        assertTrue(intake.fail(intakeIdOf(id), 2, bytes32("disagreed"), 13, 28));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
        // No cooldown after a failure: the next letter settles the old escrow first.
        uint256 next = letter(alice, "Asking again, plainly: one tenth for the ticket, the rest stays.");
        assertGt(next, id);
        (, bool open,) = escrowed(id);
        assertFalse(open);
        (uint256 openId, uint256 count) = letterbox.openOf(alice);
        assertEq(openId, next);
        assertEq(count, 1);
    }

    function test_aLapsedApprovalSettlesAndStillCounts() public {
        uint256 id = letter(alice, "A tenth for my cat's surgery; the rest of the bag is staying.");
        answer(id, 40);
        skip(7 minutes + 1);
        letterbox.settle(id);
        assertTrue(seasons.recorded(id), "a lapsed approval still counts for its season");
        assertEq(plea.balanceOf(address(letterbox)), 0);
        assertEq(imd.balanceOf(address(letterbox)), 0);
    }

    function test_expiredPendingPleaSettlesAfterTwentyMinutes() public {
        uint256 id = letter(alice, "A tenth to pay a friend back; I keep the rest and my word.");
        skip(20 minutes + 1);
        letterbox.settle(id);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
    }

    // ---------------------------------------------------------------- appeals

    function test_appealByLetterUsesTheOriginalAmountAndPaysTheWall() public {
        uint256 id = letter(alice, "A tenth for school books; the rest is not for sale.");
        uint256 amount = gate.getPlea(id).amount;
        answer(id, 0);
        uint256 wall = hook.retainedImd();
        uint256 a = letter(alice, "APPEAL I was too brief: the books cost 40 IMD and I keep the rest.");
        CabalGate.Plea memory p = gate.getPlea(a);
        assertTrue(p.isAppeal);
        assertEq(p.originalId, id);
        assertEq(p.amount, amount);
        assertEq(p.text, "I was too brief: the books cost 40 IMD and I keep the rest.");
        assertEq(hook.retainedImd() - wall, 0.35e18, "the wall share");
        assertEq(imd.balanceOf(address(letterbox)), TIP);
        (, bool openOld,) = escrowed(id);
        assertFalse(openOld, "the denied plea was settled first");
        answer(a, 45);
        letterbox.deliver(a);
        assertEq(uint8(gate.getPlea(a).status), uint8(CabalGate.Status.Executed));
        // No second appeal.
        skip(4 hours);
        assertLetterReverts(alice, "APPEAL again", abi.encodeWithSelector(CabalGate.NotDenied.selector));
    }

    function test_siteAutoSellPleadsAnyValidAmount() public {
        uint256 amount = plea.balanceOf(alice) / 20;
        vm.prank(alice);
        uint256 id = letterbox.plead(amount, "Five percent for a gift; the rest stays.");
        assertEq(gate.getPlea(id).amount, amount);
        assertEq(gate.getPlea(id).flags, 2, "auto-sell, not a letter");
        answer(id, 0);
        vm.prank(alice);
        uint256 a = letterbox.appealAuto(id, "Five percent, still a gift, still keeping the rest.");
        assertEq(gate.getPlea(a).flags, 2);
        uint256 amt101 = plea.balanceOf(bob) / 200;
        vm.prank(bob);
        vm.expectRevert(CabalGate.AmountTooSmall.selector);
        letterbox.plead(amt101, "too small");
    }

    // ---------------------------------------------------------------- status and leaderboard

    function test_statusTellsEachState() public {
        assertEq(letterbox.status(alice), "No plea yet. Next plea possible now.");
        uint256 id = letter(alice, "A tenth for my sister's school trip; the rest stays put.");
        string memory s = letterbox.status(alice);
        assertTrue(vm.contains(s, "PENDING"), s);
        answer(id, 40);
        s = letterbox.status(alice);
        assertTrue(vm.contains(s, "APPROVED (40 vs"), s);
        assertTrue(vm.contains(s, "selling automatically"), s);
        letterbox.deliver(id);
        s = letterbox.status(alice);
        assertTrue(vm.contains(s, "SOLD for "), s);
        assertTrue(vm.contains(s, "+40 points (season 1, rank 1)"), s);
        assertTrue(vm.contains(s, "Cooldown until "), s);
        skip(4 hours);
        uint256 d = letter(alice, "Another tenth, for the trip home this time; the rest stays.");
        answer(d, 0);
        s = letterbox.status(alice);
        assertTrue(vm.contains(s, "DENIED (0 vs"), s);
        assertTrue(vm.contains(s, "send APPEAL <text> before "), s);
        assertTrue(vm.contains(s, "call settle or send a letter"), s);
        letterbox.settle(d);
        assertTrue(vm.contains(letterbox.status(alice), "PLEA and tip returned"), letterbox.status(alice));
    }

    function test_leaderboardListsTheSeason() public {
        uint256 id = letter(alice, "A tenth for my sister's school trip; the rest stays put.");
        answer(id, 40);
        letterbox.deliver(id);
        string memory b = letterbox.leaderboard();
        assertTrue(vm.contains(b, "Season 1"), b);
        assertTrue(vm.contains(b, "+ 5,000,000 PLEA"), b);
        assertTrue(vm.contains(b, "1. 0x"), b);
        assertTrue(vm.contains(b, "40 pts (needs 60)"), b);
        vm.prank(alice);
        laureates.setName("alice_w");
        assertTrue(vm.contains(letterbox.leaderboard(), "1. alice_w"), letterbox.leaderboard());
    }

    function test_deadCabalRefusesLettersButSettles() public {
        uint256 id = letter(alice, "A tenth for my rent; the rest stays with me.");
        vm.warp(uint256(gate.lastVerdictAt()) + gate.DEADMAN());
        assertEq(letterbox.status(alice), "The Cabal is dead. PLEA trades freely.");
        skip(21 minutes);
        letterbox.settle(id);
        (bool ok,) = send(bob, "too late");
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- Laureates

    function test_letterLaureateWearsTheSeal() public {
        uint256 id = letter(alice, "A tenth for my sister's school trip; the rest stays put.");
        answer(id, 44);
        letterbox.deliver(id);
        uint256 site = plead(bob, plea.balanceOf(bob) / 10);
        answer(site, 43);
        vm.prank(bob);
        gate.executeSell(0);
        seasons.record(site);
        // The Cabal dies after 33 silent hours, which ends the season early; then it can close.
        vm.warp(uint256(gate.lastVerdictAt()) + gate.DEADMAN() + 1 hours);
        seasons.closeSeason(new uint256[](0));
        string memory uriLetter = laureates.tokenURI(1);
        string memory uriSite = laureates.tokenURI(2);
        assertTrue(_decodedContains(uriLetter, "By letter"));
        assertFalse(_decodedContains(uriSite, "By letter"));
    }

    function _decodedContains(string memory uri, string memory needle) internal pure returns (bool) {
        bytes memory b = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        bytes memory enc = new bytes(b.length - prefix.length);
        for (uint256 i; i < enc.length; ++i) {
            enc[i] = b[prefix.length + i];
        }
        return vm.contains(string(_b64decode(enc)), needle);
    }

    function _b64decode(bytes memory data) internal pure returns (bytes memory out) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        uint8[128] memory rev;
        for (uint8 i; i < 64; ++i) {
            rev[uint8(table[i])] = i;
        }
        uint256 pad;
        if (data.length > 0 && data[data.length - 1] == "=") ++pad;
        if (data.length > 1 && data[data.length - 2] == "=") ++pad;
        out = new bytes(data.length / 4 * 3 - pad);
        uint256 j;
        for (uint256 i; i < data.length; i += 4) {
            uint256 n = (uint256(rev[uint8(data[i])]) << 18) | (uint256(rev[uint8(data[i + 1])]) << 12)
                | (uint256(rev[uint8(data[i + 2])]) << 6) | uint256(rev[uint8(data[i + 3])]);
            if (j < out.length) out[j++] = bytes1(uint8(n >> 16));
            if (j < out.length) out[j++] = bytes1(uint8(n >> 8));
            if (j < out.length) out[j++] = bytes1(uint8(n));
        }
    }
}

/// The owner of PLEA does not play: no points, prizes, bonus, Laureates or keeper tips.
contract OwnerExclusionTest is Fixture {
    function setUp() public virtual override {
        super.setUp();
        fund(OWNER);
        buy(OWNER, 50e18);
        buy(alice, 50e18);
        skip(1 days);
    }

    function test_ownerPleasEarnNoPoints() public {
        uint256 id = plead(OWNER, plea.balanceOf(OWNER) / 10);
        answer(id, 45);
        vm.expectRevert(Seasons.OwnerExcluded.selector);
        seasons.record(id);
        // closeSeason skips it quietly (the season ends when the Cabal dies, 33 silent hours later).
        vm.warp(uint256(gate.lastVerdictAt()) + gate.DEADMAN() + 1 hours);
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        seasons.closeSeason(ids);
        assertFalse(seasons.recorded(id));
        assertEq(laureates.totalSupply(), 0);
    }

    function _fillWallReserve() internal {
        imd.mint(address(this), 200e18);
        imd.approve(address(hook), 200e18);
        hook.fundWall(200e18);
        assertTrue(hook.pendingRebalance());
    }

    function test_ownerGetsNoKeeperTip() public {
        uint256 snap = vm.snapshotState();
        _fillWallReserve();
        vm.prank(keeper);
        hook.rebalance();
        assertEq(imd.balanceOf(keeper), hook.KEEPER_TIP(), "anyone else is tipped");
        vm.revertToState(snap);
        _fillWallReserve();
        uint256 before = imd.balanceOf(OWNER);
        vm.prank(OWNER);
        hook.rebalance();
        assertEq(imd.balanceOf(OWNER), before, "no tip for the owner");
    }
}

/// The mainnet path: the oracle fee asset is the pool IMD, so a letter buys the oracle fee with PLEA
/// together with the tip (no minting), and the Letterbox refuses to mint on chain id 1.
contract LetterboxMainnetPathTest is Fixture {
    function oracleFeeToken() internal view override returns (MockIMD) {
        return imd;
    }

    function setUp() public virtual override {
        super.setUp();
        buy(alice, 50e18);
        skip(1 days);
    }

    function test_letterBuysTheOracleFeeAndTheTipWithPlea() public {
        (uint256 feeImd, uint256 maxFeePlea) = letterbox.feesFor(false);
        assertEq(feeImd, 0.5e18 + 0.25e18, "oracle fee + tip");
        uint256 bal = plea.balanceOf(alice);
        uint256 intakeBefore = imd.balanceOf(intake.PAY_TO());
        vm.prank(alice);
        (bool ok,) = address(letterbox).call("One tenth for a new phone; nine tenths stay with me all season.");
        assertTrue(ok);
        uint256 id = gate.lastPleaOf(alice);
        assertEq(imd.balanceOf(intake.PAY_TO()) - intakeBefore, 0.5e18, "the Intake was paid in IMD");
        assertEq(imd.balanceOf(address(letterbox)), 0.25e18, "only the tip stays");
        uint256 feePlea = bal - bal / 10 - plea.balanceOf(alice);
        assertLe(feePlea, maxFeePlea);
        (feeImd,) = letterbox.feesFor(true);
        assertEq(feeImd, 0.5e18 + 0.35e18 + 0.25e18, "an appeal also buys the wall share");
        answer(id, 0);
        uint256 wall = hook.retainedImd();
        vm.prank(alice);
        (ok,) = address(letterbox).call("APPEAL The phone is how I work; I keep the rest.");
        assertTrue(ok);
        assertEq(hook.retainedImd() - wall, 0.35e18);
        assertEq(imd.balanceOf(address(letterbox)), 0.25e18);
    }

    function test_mintingTheFeeIsRefusedOnMainnet() public {
        vm.chainId(1);
        vm.expectRevert(Letterbox.MintOnMainnet.selector);
        new Letterbox(
            address(plea), address(gate), address(seasons), address(laureates), address(imd), address(oimd), true
        );
        vm.expectRevert(Letterbox.OracleAssetNotImd.selector);
        new Letterbox(
            address(plea), address(gate), address(seasons), address(laureates), address(imd), address(oimd), false
        );
    }
}
