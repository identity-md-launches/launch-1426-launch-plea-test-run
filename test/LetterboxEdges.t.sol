// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Fixture} from "./utils/Fixture.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {PLEA} from "../src/PLEA.sol";
import {Letterbox} from "../src/Letterbox.sol";
import {MockIMD} from "./utils/Mocks.sol";

/// @notice The Letterbox and the gate's Letterbox-only entry points at their edges: the exact
/// boundary of every clock (the 7-minute window, the 20-minute expiry, the 4-hour cooldown), the
/// 10% fee-share cap, the 1% / 50% / 2.5M amount limits as the site's auto-sell sees them, bad flags
/// sent by the Letterbox itself, a finished escrow that must never reopen, PLEA.setLetterbox's
/// lifecycle, and the gate state a lapsed letter leaves behind.
contract LetterboxEdgesTest is Fixture {
    uint256 constant TIP = 0.25e18;
    uint256 constant AUTO_SELL_FEE = 0.35e18;
    uint256 constant WINDOW = 7 minutes;
    uint256 constant PENDING_EXPIRY = 20 minutes;
    uint256 constant COOLDOWN = 4 hours;
    string constant TEXT = "A fifth for the vet bill; the other four fifths stay with the Cabal.";

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

    function letter(address who, string memory text) internal returns (uint256 id) {
        (bool ok, bytes memory ret) = send(who, bytes(text));
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

    function isOpen(uint256 id) internal view returns (bool open) {
        (, open,,) = letterbox.escrowOf(id);
    }

    function openCount() internal view returns (uint256 n) {
        (, n) = letterbox.openOf(address(0));
    }

    // ================================================================ the window's exact edges

    /// At the last second of the window the plea still sells and cannot be settled; one second
    /// later it cannot sell and settles, and its approval still counts for the season.
    function test_approvedEscrowAtTheWindowsLastSecondSellsAndCannotSettle() public {
        uint256 id = letter(alice, TEXT);
        answer(id, 45);
        uint64 verdictAt = gate.getPlea(id).verdictAt;
        vm.warp(verdictAt + WINDOW);
        vm.expectRevert(abi.encodeWithSelector(Letterbox.NotSettleable.selector, id));
        letterbox.settle(id);
        uint256 before = imd.balanceOf(alice);
        vm.prank(keeper);
        uint256 out = letterbox.deliver(id);
        assertGt(out, 0);
        assertEq(imd.balanceOf(alice) - before, out, "the writer gets the sale less the fee");
        assertEq(imd.balanceOf(keeper), TIP);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        assertTrue(seasons.recorded(id), "the sale records the points");
    }

    function test_approvedEscrowOneSecondAfterTheWindowSettlesAndStillCounts() public {
        uint256 id = letter(alice, TEXT);
        answer(id, 45);
        uint64 verdictAt = gate.getPlea(id).verdictAt;
        vm.warp(uint256(verdictAt) + WINDOW + 1);
        vm.prank(keeper);
        vm.expectRevert(CabalGate.WindowLapsed.selector);
        letterbox.deliver(id);
        assertEq(imd.balanceOf(keeper), 0, "a failed delivery earns nothing");
        uint256 pleaBefore = plea.balanceOf(alice);
        uint256 imdBefore = imd.balanceOf(alice);
        (,, uint256 amount,) = letterbox.escrowOf(id);
        vm.prank(keeper);
        letterbox.settle(id);
        assertEq(plea.balanceOf(alice) - pleaBefore, amount, "the whole escrow comes back");
        assertEq(imd.balanceOf(alice) - imdBefore, TIP, "and the unspent tip");
        assertTrue(seasons.recorded(id), "a lapsed approval is recorded first");
        assertEq(plea.balanceOf(address(letterbox)), 0);
        assertEq(imd.balanceOf(address(letterbox)), 0);
        // The gate still says Approved until the writer's next plea clears it: `settle` never
        // touches the gate's state for an approval, so nothing else can sell it either.
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Approved));
        vm.prank(alice);
        vm.expectRevert(CabalGate.UseLetterbox.selector);
        gate.executeSell(0);
    }

    /// A lapsed letter leaves the gate's Approved status behind; the writer's next letter clears
    /// it into Lapsed, and that starts the 4-hour cooldown from the verdict, not from the letter.
    function test_aLapsedLetterStartsTheCooldownFromItsVerdict() public {
        uint256 id = letter(alice, TEXT);
        answer(id, 45);
        uint64 verdictAt = gate.getPlea(id).verdictAt;
        vm.warp(uint256(verdictAt) + WINDOW + 1);
        letterbox.settle(id);
        assertLetterReverts(
            alice, bytes(TEXT), abi.encodeWithSelector(CabalGate.Cooldown.selector, uint256(verdictAt) + COOLDOWN)
        );
        // The refusal reverted the gate's clearing too: nothing changed, the escrow stays closed.
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Approved), "a refused letter changes nothing");
        assertEq(gate.lastLapsedAt(alice), 0);
        assertFalse(isOpen(id), "the escrow does not reopen");
        assertEq(plea.balanceOf(address(letterbox)), 0, "and the refused letter moved nothing");
        vm.warp(uint256(verdictAt) + COOLDOWN);
        uint256 next = letter(alice, TEXT);
        assertGt(next, id);
        assertTrue(isOpen(next));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Lapsed), "the accepted letter cleared it");
        assertEq(gate.lastLapsedAt(alice), verdictAt);
        assertEq(gate.pendingOf(alice), next);
    }

    // ================================================================ the expiry's exact edges

    function test_pendingEscrowSettlesOnlyOnceStale() public {
        uint256 id = letter(alice, TEXT);
        uint64 submittedAt = gate.getPlea(id).submittedAt;
        vm.warp(uint256(submittedAt) + PENDING_EXPIRY);
        vm.expectRevert(CabalGate.NotStale.selector);
        letterbox.settle(id);
        // The writer's next letter cannot end it either while a verdict can still come.
        assertLetterReverts(alice, bytes(TEXT), abi.encodeWithSelector(Letterbox.PendingExists.selector, id));
        vm.warp(uint256(submittedAt) + PENDING_EXPIRY + 1);
        uint256 pleaBefore = plea.balanceOf(alice);
        (,, uint256 amount,) = letterbox.escrowOf(id);
        uint256 bobImd = imd.balanceOf(bob);
        uint256 bobPlea = plea.balanceOf(bob);
        vm.prank(bob);
        letterbox.settle(id);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
        assertEq(plea.balanceOf(alice) - pleaBefore, amount);
        assertEq(imd.balanceOf(bob), bobImd, "the settling stranger earns nothing");
        assertEq(plea.balanceOf(bob), bobPlea);
        // A late verdict is refused by the gate: the escrow it would have sold is gone.
        assertFalse(answer(id, 45), "a verdict after the expiry is not delivered");
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
        assertFalse(isOpen(id));
    }

    /// The Intake completing without a verdict makes the escrow settleable at once, before the
    /// 20 minutes, and the next letter of the same writer settles it in passing.
    function test_aFailedRequestSettlesBeforeTheTwentyMinutes() public {
        uint256 id = letter(alice, TEXT);
        assertTrue(intake.fail(intakeIdOf(id), 2, bytes32("no quorum"), 12, 30));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
        skip(1 minutes);
        uint256 pleaBefore = plea.balanceOf(alice);
        uint256 imdBefore = imd.balanceOf(alice);
        (,, uint256 amount,) = letterbox.escrowOf(id);
        uint256 next = letter(alice, TEXT);
        assertFalse(isOpen(id));
        assertTrue(isOpen(next));
        assertEq(openCount(), 1);
        (,, uint256 nextAmount,) = letterbox.escrowOf(next);
        // The refund landed before the new letter was measured: 20% of the restored balance.
        assertEq(imd.balanceOf(alice) - imdBefore, TIP, "the old tip came back");
        assertLt(plea.balanceOf(alice), pleaBefore + amount, "the new escrow and fee were taken");
        assertEq(nextAmount, (pleaBefore + amount) / 5, "the next letter pleads a fifth of the restored balance");
    }

    // ================================================================ an escrow ends exactly once

    /// Whatever ended an escrow, every later `deliver`, `settle` and `SELL` finds it closed, and
    /// the Letterbox's holdings do not move.
    function testFuzz_aFinishedEscrowNeverReopens(uint8 endingSeed) public {
        uint256 ending = bound(endingSeed, 0, 3);
        uint256 id = letter(alice, TEXT);
        if (ending == 0) {
            answer(id, 45);
            vm.prank(keeper);
            letterbox.deliver(id);
        } else if (ending == 1) {
            answer(id, 45);
            vm.prank(alice);
            (bool ok,) = address(letterbox).call("SELL");
            assertTrue(ok);
        } else if (ending == 2) {
            answer(id, 0);
            letterbox.settle(id);
        } else {
            answer(id, 45);
            vm.warp(uint256(gate.getPlea(id).verdictAt) + WINDOW + 1);
            letterbox.settle(id);
        }
        assertFalse(isOpen(id));
        assertEq(openCount(), 0);
        uint256 heldPlea = plea.balanceOf(address(letterbox));
        uint256 heldImd = imd.balanceOf(address(letterbox));
        assertEq(heldPlea, 0);
        assertEq(heldImd, 0);
        vm.expectRevert(abi.encodeWithSelector(Letterbox.NotOpen.selector, id));
        letterbox.deliver(id);
        vm.expectRevert(abi.encodeWithSelector(Letterbox.NotOpen.selector, id));
        letterbox.settle(id);
        assertLetterReverts(alice, "SELL", abi.encodeWithSelector(Letterbox.NotOpen.selector, 0));
        // An id that never existed is just as closed.
        vm.expectRevert(abi.encodeWithSelector(Letterbox.NotOpen.selector, id + 7));
        letterbox.settle(id + 7);
        assertEq(plea.balanceOf(address(letterbox)), heldPlea);
        assertEq(imd.balanceOf(address(letterbox)), heldImd);
    }

    // ================================================================ the fee-share cap

    /// A wallet whose appeal fees (0.6 IMD + 10%) would take more than 10% of its PLEA is refused
    /// with `FeeTooHigh`, and nothing moves. Its plea went through the gate by hand, since a letter's
    /// fifth would have been worth less than 0.70 IMD; the APPEAL letter then clamps to 50%.
    function test_appealFeesAboveTenPercentOfTheBalanceAreRefused() public {
        address poor = makeAddr("poor");
        fund(poor);
        buy(poor, 3e18);
        keepAlive(bob); // a verdict now, so the extra day of holding does not kill the Cabal
        skip(1 days);
        uint256 bal = plea.balanceOf(poor);
        uint256 id = plead(poor, bal / 2, TEXT);
        answer(id, 0);
        (uint256 feeImd, uint256 maxFeePlea) = letterbox.feesFor(true);
        assertEq(feeImd, TIP + 0.35e18 + (oracleFeeToken() == imd ? 0.5e18 : 0), "tip, wall share, bought oracle fee");
        assertGt(maxFeePlea * 10, bal, "the appeal's fees exceed a tenth of the balance");
        assertLetterReverts(
            poor, "APPEAL the bill is still due", abi.encodeWithSelector(Letterbox.FeeTooHigh.selector, maxFeePlea, bal)
        );
        assertEq(plea.balanceOf(poor), bal);
        assertEq(plea.balanceOf(address(letterbox)), 0);
        assertEq(gate.lastPleaOf(poor), id, "no appeal was opened");
        // The gate's own appeal still works for that wallet: the cap is the Letterbox's.
        vm.prank(poor);
        uint256 a = gate.appeal(id, bal / 2, "By hand, the same bill.");
        assertEq(gate.getPlea(a).flags, 0);
    }

    /// The fee swap never spends more than the cap, and the refund of the unspent PLEA is exact:
    /// writer + escrow + fee == balance before, with the fee at most maxFeePlea, for any size of
    /// buyer.
    function testFuzz_feeSwapStaysUnderTheCapAndRefundsTheRest(uint256 imdInSeed) public {
        // From 12 IMD (below ~8.25 IMD the mainnet path's 0.825 IMD of fees exceed the 10% share
        // cap and the letter is refused, which `test_appealFeesAboveTenPercentOfTheBalanceAreRefused`
        // covers) up to a buyer whose fifth hits the 2.5M PLEA cap.
        uint256 imdIn = bound(imdInSeed, 12e18, 2_000e18);
        address w = makeAddr("writer");
        fund(w);
        buy(w, imdIn);
        keepAlive(bob);
        skip(1 days);
        uint256 bal = plea.balanceOf(w);
        (, uint256 maxFeePlea) = letterbox.feesFor(false);
        uint256 expected = bal / 5;
        if (expected > gate.MAX_SELL()) expected = gate.MAX_SELL();
        uint256 id = letter(w, TEXT);
        (address writer, bool open, uint256 amount,) = letterbox.escrowOf(id);
        assertEq(writer, w);
        assertTrue(open);
        assertEq(amount, expected);
        uint256 fee = bal - amount - plea.balanceOf(w);
        assertGt(fee, 0);
        assertLe(fee, maxFeePlea);
        assertEq(plea.balanceOf(address(letterbox)), amount, "no unspent fee PLEA stays behind");
        assertEq(imd.balanceOf(address(letterbox)), TIP);
        assertEq(plea.balanceOf(address(gate)), 0, "the gate keeps no PLEA from the fee swap");
    }

    // ================================================================ the site's amount limits

    /// `plead(amount)` at the exact limits: 1% in, 1% minus one wei out, 50% in, 50% plus one wei
    /// out, zero out.
    function test_siteAmountLimitsAtTheirBoundaries() public {
        address w = makeAddr("site");
        fund(w);
        buy(w, 400e18); // 1% is worth well over the 0.70 IMD minimum
        keepAlive(bob);
        skip(1 days);
        uint256 bal = plea.balanceOf(w);
        vm.prank(w);
        vm.expectRevert(abi.encodeWithSelector(Letterbox.LetterTooSmall.selector, 0));
        letterbox.plead(0, TEXT);
        vm.prank(w);
        vm.expectRevert(CabalGate.AmountTooSmall.selector);
        letterbox.plead(bal / 100 - 1, TEXT);
        vm.prank(w);
        vm.expectRevert(CabalGate.AmountTooLarge.selector);
        letterbox.plead(bal / 2 + 1, TEXT);
        assertEq(plea.balanceOf(w), bal, "refusals move nothing");
        vm.prank(w);
        uint256 id = letterbox.plead(bal / 100, TEXT);
        assertEq(gate.getPlea(id).amount, bal / 100);
        assertEq(gate.getPlea(id).flags, 2);
        answer(id, 0);
        skip(COOLDOWN);
        // The 50% is of the balance before the escrow, read before anything moved.
        uint256 bal2 = plea.balanceOf(w);
        assertEq(gate.factScore(w, bal2 / 5) - gate.factScore(w, bal2 / 2), 13, "20% is the top band, 50% the lowest");
        // The most a plea may be: 50% of the balance, or 2.5M PLEA when that is less.
        uint256 most = bal2 / 2 > gate.MAX_SELL() ? gate.MAX_SELL() : bal2 / 2;
        vm.prank(w);
        vm.expectRevert(CabalGate.AmountTooLarge.selector);
        letterbox.plead(most + 1, TEXT);
        uint8 atMost = gate.factScore(w, most);
        vm.prank(w);
        uint256 id2 = letterbox.plead(most, TEXT);
        assertEq(gate.getPlea(id2).amount, most);
        assertEq(gate.getPlea(id2).factScore, atMost, "scored on the balance before the escrow moved");
        (,, uint256 held,) = letterbox.escrowOf(id2);
        assertEq(held, most, "a cap-sized escrow fits its slot");
    }

    /// The share bands: 18 points up to 20%, 11 up to 35%, 5 above, with the boundaries inclusive.
    function test_shareBandsAt20And35Percent() public view {
        uint256 bal = plea.balanceOf(alice);
        // The share is measured in whole basis points: one wei over 20% is still 2000 bps.
        uint8 at20 = gate.factScore(alice, bal / 5);
        assertEq(gate.factScore(alice, bal / 5 + 1), at20, "a wei over 20% rounds to 2000 bps");
        uint8 over20 = gate.factScore(alice, bal * 2_001 / 10_000 + 1);
        uint8 at35 = gate.factScore(alice, bal * 3_500 / 10_000);
        uint8 over35 = gate.factScore(alice, bal * 3_501 / 10_000 + 1);
        uint8 at50 = gate.factScore(alice, bal / 2);
        assertEq(at20 - over20, 7, "18 to 11 past 20%");
        assertEq(over20, at35, "one band from 20% to 35%");
        assertEq(at35 - over35, 6, "11 to 5 past 35%");
        assertEq(over35, at50, "one band above 35%");
        assertEq(gate.factScore(alice, 1), at20, "one wei is the top band");
    }

    // ================================================================ bad flags from the Letterbox

    /// Even the Letterbox cannot open a plea without the auto-sell flag, with unknown flag bits, or
    /// sell an approval the gate did not flag auto-sell.
    function test_theGateRefusesBadFlagsAndUnflaggedSalesEvenFromTheLetterbox() public {
        uint256 bal = plea.balanceOf(alice);
        uint8[4] memory bad = [0, 1, 4, 7];
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(address(letterbox));
            vm.expectRevert(CabalGate.BadFlags.selector);
            gate.submitFor(alice, bal / 5, bal, TEXT, bad[i], 0, 0);
            vm.prank(address(letterbox));
            vm.expectRevert(CabalGate.BadFlags.selector);
            gate.appealFor(alice, 1, bal / 5, bal, TEXT, bad[i], 0, 0);
        }
        // A plea made by hand, approved: the Letterbox may not sell it (it holds no escrow for it).
        uint256 id = plead(alice, bal / 10, TEXT);
        answer(id, 45);
        vm.prank(address(letterbox));
        vm.expectRevert(CabalGate.NotApproved.selector);
        gate.executeSellFor(id, 0);
        // The hand plea still sells by hand.
        vm.prank(alice);
        assertGt(gate.executeSell(0), 0);
        // A denied letter cannot be sold through the Letterbox's entry point either.
        skip(COOLDOWN);
        uint256 denied = letter(alice, TEXT);
        answer(denied, 0);
        vm.prank(address(letterbox));
        vm.expectRevert(CabalGate.NotApproved.selector);
        gate.executeSellFor(denied, 0);
        vm.prank(keeper);
        vm.expectRevert(CabalGate.NotApproved.selector);
        letterbox.deliver(denied);
    }

    /// `PleaFlags` is emitted for every Letterbox plea with exactly its flags, and `pleaFlags`
    /// reads it back; hand pleas carry none.
    function test_pleaFlagsAreEmittedAndReadable() public {
        uint256 next = gate.nextId();
        vm.expectEmit(true, false, false, true, address(gate));
        emit CabalGate.PleaFlags(next, 3);
        uint256 id = letter(alice, TEXT);
        assertEq(id, next);
        assertEq(gate.pleaFlags(id), 3);
        uint256 hand = plead(bob, plea.balanceOf(bob) / 10, TEXT);
        assertEq(gate.pleaFlags(hand), 0);
        assertEq(gate.lastPleaOf(bob), hand, "lastPleaOf tracks hand pleas too");
        assertEq(gate.lastPleaOf(alice), id);
    }

    // ================================================================ APPEAL after a hand plea

    /// An APPEAL letter may appeal a plea made by hand: the escrow holds the original amount (or
    /// 50% of the balance when that is less), the wall share and tip are bought with PLEA, and the
    /// hand plea's lack of an escrow does not confuse `settle`.
    function test_appealLetterAppealsAHandPleaAndEscrowsOnlyTheAppeal() public {
        uint256 bal = plea.balanceOf(alice);
        uint256 id = plead(alice, bal / 10, TEXT);
        answer(id, 0);
        (, uint256 maxFeePlea) = letterbox.feesFor(true);
        uint256 wallBefore = imd.balanceOf(address(hook));
        uint256 a = letter(alice, "APPEAL the bill did not go away");
        CabalGate.Plea memory p = gate.getPlea(a);
        assertTrue(p.isAppeal);
        assertEq(p.originalId, id);
        assertEq(p.amount, bal / 10, "the original amount");
        assertEq(p.flags, 3);
        (, bool open, uint256 amount,) = letterbox.escrowOf(a);
        assertTrue(open);
        assertEq(amount, bal / 10);
        assertFalse(isOpen(id), "the hand plea has no escrow");
        assertEq(openCount(), 1);
        uint256 fee = bal - amount - plea.balanceOf(alice);
        assertGt(fee, 0);
        assertLe(fee, maxFeePlea);
        assertGe(imd.balanceOf(address(hook)) - wallBefore, 0.35e18, "the wall share reached the hook");
        // Settling the hand plea's id finds nothing; the appeal's escrow is untouched.
        vm.expectRevert(abi.encodeWithSelector(Letterbox.NotOpen.selector, id));
        letterbox.settle(id);
        assertTrue(isOpen(a));
        // Upheld: the escrow comes back, and APPEAL again finds the upheld appeal, not the original.
        answer(a, 0);
        assertLetterReverts(alice, "APPEAL once more", abi.encodeWithSelector(CabalGate.AlreadyAppealed.selector));
        assertTrue(isOpen(a), "a refused letter reverts the settle it began with");
        letterbox.settle(a);
        assertFalse(isOpen(a));
        assertEq(plea.balanceOf(alice) + fee, bal, "everything but the fee is back");
    }

    function test_appealLetterRefusesAnExecutedPleaAndAClosedWindow() public {
        uint256 id = letter(alice, TEXT);
        answer(id, 45);
        vm.prank(keeper);
        letterbox.deliver(id);
        assertLetterReverts(alice, "APPEAL I sold already", abi.encodeWithSelector(CabalGate.NotDenied.selector));
        skip(COOLDOWN);
        uint256 denied = letter(bob, TEXT);
        answer(denied, 0);
        vm.warp(uint256(gate.getPlea(denied).verdictAt) + COOLDOWN + 1);
        assertLetterReverts(bob, "APPEAL too late", abi.encodeWithSelector(CabalGate.AppealClosed.selector));
        assertTrue(isOpen(denied), "the refused letter did not settle the denied escrow");
        letterbox.settle(denied);
        assertEq(imd.balanceOf(address(letterbox)), 0);
        // `appealAuto` of a stranger's plea, or of nothing, is refused before any PLEA moves.
        vm.prank(alice);
        vm.expectRevert(CabalGate.NotSeller.selector);
        letterbox.appealAuto(denied, "not mine");
        vm.prank(alice);
        vm.expectRevert(Letterbox.NothingToAppeal.selector);
        letterbox.appealAuto(0, "nothing");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Letterbox.TooSmallForTheFee.selector, 0));
        letterbox.appealAuto(999, "no such plea");
    }

    // ================================================================ PLEA.setLetterbox and courtTake

    /// A fresh PLEA: only the launcher sets the Letterbox, never zero, exactly once; `courtTake`
    /// is refused before it is set, by anyone but the Letterbox after, and cannot exceed a balance.
    function test_setLetterboxLifecycleOnAFreshPlea() public {
        PLEA fresh = new PLEA(OWNER);
        address lb = makeAddr("lb");
        vm.prank(alice);
        vm.expectRevert(PLEA.NotLetterbox.selector);
        fresh.courtTake(bob, 1);
        // Not yet launched: no launcher, so nobody may set it.
        vm.expectRevert(PLEA.NotLauncher.selector);
        fresh.setLetterbox(lb);
        // Same transaction as the deployment: the transient flag is set. The live gate answers
        // `restricted()` (true), so `courtTake` runs the Cabal's transfer rule.
        fresh.setLauncher(address(gate), makeAddr("s"), makeAddr("d"));
        assertEq(fresh.launcher(), address(this));
        vm.prank(alice);
        vm.expectRevert(PLEA.NotLauncher.selector);
        fresh.setLetterbox(lb);
        vm.expectRevert(PLEA.ZeroAddress.selector);
        fresh.setLetterbox(address(0));
        fresh.setLetterbox(lb);
        assertEq(fresh.letterbox(), lb);
        vm.expectRevert(PLEA.AlreadySet.selector);
        fresh.setLetterbox(makeAddr("other"));
        vm.expectRevert(PLEA.AlreadySet.selector);
        fresh.setLetterbox(lb);
        // courtTake: only the Letterbox, only what the wallet has.
        vm.expectRevert(PLEA.NotLetterbox.selector);
        fresh.courtTake(bob, 0);
        vm.prank(lb);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1));
        fresh.courtTake(bob, 1);
    }

    /// The live Letterbox cannot be replaced or re-registered, and the launcher's registration
    /// is used up.
    function test_theLiveLetterboxCannotBeReplaced() public {
        vm.prank(address(launch));
        vm.expectRevert(PLEA.AlreadySet.selector);
        plea.setLetterbox(alice);
        vm.prank(OWNER);
        vm.expectRevert(PLEA.NotLauncher.selector);
        plea.setLetterbox(alice);
        assertEq(plea.letterbox(), address(letterbox));
        assertEq(launch.letterbox(), address(letterbox));
        assertEq(launch.predictLetterbox(), address(letterbox));
    }

    // ================================================================ the fee goes to the pot

    /// The auto-sell fee is checkpointed into the running season's pot in the delivery itself,
    /// not left for a later checkpoint, and a hand sale pays no such fee.
    function test_autoSellFeeIsCheckpointedIntoTheRunningSeason() public {
        (, uint256 season,) = seasons.currentSeason();
        uint256 feesBefore = seasons.seasonFees(season);
        uint256 potBefore = imd.balanceOf(address(seasons));
        uint256 id = letter(alice, TEXT);
        answer(id, 45);
        vm.prank(keeper);
        letterbox.deliver(id);
        uint256 added = imd.balanceOf(address(seasons)) - potBefore;
        assertGe(added, AUTO_SELL_FEE, "the fee reached Seasons (plus the sale's own prize fee)");
        assertEq(seasons.seasonFees(season) - feesBefore, added, "and was accounted to the running season");
        // A hand sale of the same size: no 0.35 IMD leaves the sale.
        skip(COOLDOWN);
        uint256 hand = plead(bob, plea.balanceOf(bob) / 5, TEXT);
        answer(hand, 45);
        uint256 bobBefore = imd.balanceOf(bob);
        uint256 potMid = imd.balanceOf(address(seasons));
        vm.prank(bob);
        uint256 out = gate.executeSell(0);
        assertEq(imd.balanceOf(bob) - bobBefore, out, "the hand seller keeps the whole sale");
        assertLt(imd.balanceOf(address(seasons)) - potMid, AUTO_SELL_FEE, "only the swap's prize fee, no auto-sell fee");
    }

    // ================================================================ a dead Cabal

    /// Once the Cabal is dead no letter opens, `APPEAL`/`SELL` fail, but the escrows settle and
    /// names still work.
    function test_deadCabalStillSettlesAndNames() public {
        uint256 id = letter(alice, TEXT);
        vm.warp(block.timestamp + DEADMAN + 1);
        assertFalse(gate.cabalAlive());
        assertLetterReverts(bob, bytes(TEXT), abi.encodeWithSelector(CabalGate.CabalNotWatching.selector));
        uint256 tenth = plea.balanceOf(bob) / 10;
        vm.prank(bob);
        vm.expectRevert(CabalGate.CabalNotWatching.selector);
        letterbox.plead(tenth, TEXT);
        (,, uint256 amount,) = letterbox.escrowOf(id);
        uint256 before = plea.balanceOf(alice);
        letterbox.settle(id);
        assertEq(plea.balanceOf(alice) - before, amount);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
        vm.prank(alice);
        (bool ok,) = address(letterbox).call("NAME still_here");
        assertTrue(ok);
        assertEq(letterbox.nameOf(alice), "still_here");
        assertEq(letterbox.status(alice), "The Cabal is dead. PLEA trades freely.");
        assertEq(letterbox.leaderboard(), "No season is running: the Cabal is dead or trading has not opened.");
    }
}

/// The same edges on the mainnet path, where the oracle fee is bought with PLEA too: the fee cap
/// is larger (0.75 IMD + 10% for a plea, 1.1 IMD + 10% for an appeal) and the `FeeTooHigh` and
/// boundary tests must still hold.
contract LetterboxEdgesMainnetTest is LetterboxEdgesTest {
    function oracleFeeToken() internal view override returns (MockIMD) {
        return imd;
    }

    function test_feesForBuysTheOracleFeeToo() public view {
        (uint256 feeImd,) = letterbox.feesFor(false);
        assertEq(feeImd, 0.25e18 + 0.5e18);
        (uint256 appealImd,) = letterbox.feesFor(true);
        assertEq(appealImd, 0.25e18 + 0.35e18 + 0.5e18);
    }
}
