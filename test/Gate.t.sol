// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {PLEA} from "../src/PLEA.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MockIntake} from "./utils/Mocks.sol";

contract GateTest is Fixture {
    function setUp() public virtual override {
        super.setUp();
        buy(alice, 50e18);
        buy(bob, 50e18);
    }

    function test_pleaPaysTheIntakeAndNamesTheCallback() public {
        uint256 before = oimd.balanceOf(alice);
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        assertEq(oimd.balanceOf(alice), before - 0.5e18);
        assertEq(oimd.balanceOf(intake.PAY_TO()), 0.5e18);
        assertEq(oimd.balanceOf(address(gate)), 0);
        bytes32 rid = intakeIdOf(id);
        (address payer, address target, bytes4 sel, bool done) = intake.requests(rid);
        assertEq(payer, address(gate));
        assertEq(target, address(gate));
        assertEq(sel, bytes4(0x510379c7));
        assertFalse(done);
        assertEq(gate.pleaOfIntake(rid), id);
    }

    function test_bodyIsTheNumericPanelQuestion() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10, 'I "quote" and \\ escape');
        string memory body = string(intake.bodyOf(intakeIdOf(id)));
        assertEq(body, gate.body(id));
        assertEq(vm.parseJsonString(body, ".answerType"), "uint256");
        assertEq(vm.parseJsonString(body, ".evidence"), "panel");
        assertEq(vm.parseJsonUint(body, ".panelSize"), 30);
        assertEq(vm.parseJsonUint(body, ".quorum"), 17);
        assertEq(vm.parseJsonUint(body, ".toleranceBps"), 1500);
        assertEq(vm.parseJsonString(body, ".guards.max"), "45");
        assertEq(vm.parseJsonUint(body, ".consumer.chainId"), 11155111);
        assertEq(vm.parseJsonAddress(body, ".consumer.verifyingContract"), address(gate));
        string memory q = vm.parseJsonString(body, ".question");
        assertEq(q, gate.question(id));
        assertTrue(bytes(q).length <= 2000);
        // Rules v2: plea, stories, content, manipulation, answer, each within IMD's 512-character limit.
        string[] memory keys = vm.parseJsonKeys(body, ".definitions");
        assertEq(keys.length, 5);
        assertTrue(vm.contains(vm.parseJsonString(body, ".definitions.stories"), "need not be"));
        assertTrue(vm.contains(vm.parseJsonString(body, ".definitions.content"), "own story"));
        assertTrue(vm.contains(vm.parseJsonString(body, ".definitions.manipulation"), "weigh my honesty"));
        for (uint256 i; i < keys.length; ++i) {
            string memory v = vm.parseJsonString(body, string.concat(".definitions.", keys[i]));
            assertLe(bytes(v).length, 512, keys[i]);
        }
    }

    function test_approvedScoreOpensTheSellWindow() public {
        uint256 amount = plea.balanceOf(alice) / 10;
        uint256 id = plead(alice, amount);
        CabalGate.Plea memory p = gate.getPlea(id);
        assertEq(p.factScore, gate.factScore(alice, amount));
        assertEq(p.need, 70 - p.factScore);
        uint8 need = p.need;
        assertTrue(answer(id, need));
        p = gate.getPlea(id);
        assertEq(uint8(p.status), uint8(CabalGate.Status.Approved));
        assertEq(p.score, need);
        assertEq(gate.lastVerdictAt(), vm.getBlockTimestamp());
        uint256 imdBefore = imd.balanceOf(alice);
        vm.prank(alice);
        uint256 out = gate.executeSell(1);
        assertGt(out, 0);
        assertEq(imd.balanceOf(alice), imdBefore + out);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
    }

    function test_scoreBelowNeedDenies() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        assertTrue(answer(id, gate.getPlea(id).need - 1));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Denied));
        assertEq(gate.pendingOf(alice), 0);
        uint256 amt101 = small(alice);
        vm.expectRevert();
        plead(alice, amt101);
        vm.prank(alice);
        vm.expectRevert(CabalGate.NotApproved.selector);
        gate.executeSell(0);
    }

    function test_sellWindowLapses() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        answer(id, 40);
        skip(7 minutes + 1);
        vm.prank(alice);
        vm.expectRevert(CabalGate.WindowLapsed.selector);
        gate.executeSell(0);
        skip(4 hours);
        plead(alice, small(alice)); // the lapsed plea is cleared
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Lapsed));
    }

    function test_appealWithinFourHoursForNoMore() public {
        uint256 amount = plea.balanceOf(alice) / 10;
        uint256 id = plead(alice, amount);
        answer(id, 10);
        uint256 wallBefore = hook.retainedImd();
        vm.prank(alice);
        vm.expectRevert(CabalGate.AmountTooLarge.selector);
        gate.appeal(id, amount + 1, "please");
        vm.prank(alice);
        uint256 a = gate.appeal(id, amount / 2, "Reconsider: I mis-spoke, and I halve my ask.");
        assertEq(hook.retainedImd(), wallBefore + 0.35e18);
        CabalGate.Plea memory p = gate.getPlea(a);
        assertTrue(p.isAppeal);
        assertEq(p.originalId, id);
        assertTrue(gate.getPlea(id).appealed);
        string memory q = gate.question(a);
        assertTrue(vm.contains(q, "This is an APPEAL of plea #1"));
        answer(a, 45);
        vm.prank(alice);
        gate.executeSell(1);
    }

    function test_appealClosesAfterFourHoursAndOnlyOnce() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        answer(id, 0);
        skip(4 hours + 1);
        uint256 amt1 = small(alice);
        vm.prank(alice);
        vm.expectRevert(CabalGate.AppealClosed.selector);
        gate.appeal(id, amt1, "late");

        uint256 id2 = plead(bob, plea.balanceOf(bob) / 10);
        answer(id2, 0);
        uint256 amt2 = small(bob);
        vm.prank(bob);
        uint256 a = gate.appeal(id2, amt2, "first");
        answer(a, 0);
        uint256 amt3 = small(bob);
        vm.prank(bob);
        vm.expectRevert(CabalGate.AlreadyAppealed.selector);
        gate.appeal(id2, amt3, "second");
        uint256 amt4 = small(bob);
        vm.prank(bob);
        vm.expectRevert(CabalGate.AlreadyAppealed.selector);
        gate.appeal(a, amt4, "appeal of an appeal");
    }

    function test_cannotPassIsRefusedBeforePaying() public {
        // A fresh small buyer selling 40% (within the 2.5M cap): share 5 (over 35%), hold 0, P/L 14,
        // 24h 5 -> need 46.
        address fresh = makeAddr("fresh");
        fund(fresh);
        buy(fresh, 1e18);
        uint256 amount = plea.balanceOf(fresh) * 40 / 100;
        assertLt(amount, gate.MAX_SELL());
        uint256 need = 70 - gate.factScore(fresh, amount);
        assertGt(need, 45);
        vm.prank(fresh);
        vm.expectRevert(abi.encodeWithSelector(CabalGate.CannotPass.selector, need));
        gate.submitSell(amount, "x");
    }

    function test_callbackOnlyFromIntakeAndOnlyForAPendingPlea() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        OracleAttestation.Attestation memory a = attestation(40, keccak256("r"));
        bytes memory sig = sign(a);
        bytes32 rid = intakeIdOf(id);
        vm.expectRevert(CabalGate.NotIntake.selector);
        gate.onOracleResult(rid, a, sig);
        // An attacker pays the Intake for their own body naming the gate's callback: unknown id.
        vm.startPrank(alice);
        oimd.approve(address(intake), 1e18);
        bytes32 rogue =
            intake.request(bytes32(0), "{}", MockIntake.Callback(address(gate), 0x510379c7), address(oimd), 0.5e18);
        vm.stopPrank();
        assertFalse(intake.complete(rogue, 0, abi.encode(rogue, a, sig)));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Pending));
    }

    function test_badAttestationsAreNotDelivered() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        bytes32 rid = intakeIdOf(id);
        OracleAttestation.Attestation memory a = attestation(40, keccak256("r"));
        a.agreed = 16;
        assertFalse(deliverOnce(rid, a));
    }

    function test_scoreAboveRangeOrWrongTypeIsRefused() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        OracleAttestation.Attestation memory a = attestation(46, keccak256("r"));
        assertFalse(deliver(intakeIdOf(id), a));
        uint256 id2 = plead(bob, plea.balanceOf(bob) / 10);
        a = attestation(40, keccak256("r2"));
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(true);
        assertFalse(deliver(intakeIdOf(id2), a));
    }

    function test_wrongSignerIsRefused() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        OracleAttestation.Attestation memory a = attestation(40, keccak256("r"));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBEEF, gate.attestationDigest(a));
        bytes32 rid = intakeIdOf(id);
        assertFalse(intake.complete(rid, 0, abi.encode(rid, a, abi.encodePacked(r, s, v))));
    }

    function test_noVerdictIsClearedAtOnceWhenTheIntakeCompletes() public {
        intake.setFailureHooks(false); // a completion without a failure call: `expire` is the fallback
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        vm.expectRevert(CabalGate.NotStale.selector);
        gate.expire(id);
        intake.complete(intakeIdOf(id), 2, ""); // the panel disagreed: no callback
        gate.expire(id);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
        plead(alice, small(alice)); // may plead again, no cooldown
    }

    function test_pendingExpiresAfterTwentyMinutesAndLateCallbacksFail() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        skip(20 minutes + 1);
        assertFalse(answer(id, 45));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Pending));
        uint256 id2 = plead(alice, small(alice)); // clears the expired one
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
        assertGt(id2, id);
    }

    function test_onePendingPleaPerWallet() public {
        plead(alice, small(alice));
        uint256 amt5 = small(alice);
        vm.prank(alice);
        vm.expectRevert(CabalGate.PendingExists.selector);
        gate.submitSell(amt5, "again");
    }

    function test_cooldownAfterExecutedSell() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        answer(id, 45);
        vm.prank(alice);
        gate.executeSell(1);
        uint256 amt6 = small(alice);
        vm.prank(alice);
        vm.expectRevert();
        gate.submitSell(amt6, "again");
        skip(4 hours);
        plead(alice, small(alice));
    }

    function test_textFilter() public {
        string[9] memory bad = [
            "",
            "line\nbreak",
            string(hex"7a65726fe2808b7769647468"), // U+200B
            string(hex"62696469e280ae"), // U+202E
            string(hex"78e281a678"), // U+2066
            string(hex"78efb88f"), // U+FE0F
            string(hex"78f3a08181"), // U+E0041 tag
            "fake [plea] marker",
            "close [/PLEA marker"
        ];
        for (uint256 i; i < bad.length; ++i) {
            uint256 amt7 = small(alice);
            vm.prank(alice);
            vm.expectRevert(CabalGate.BadPleaText.selector);
            gate.submitSell(amt7, bad[i]);
        }
        uint256 amt8 = small(alice);
        vm.prank(alice);
        vm.expectRevert(CabalGate.BadPleaText.selector);
        gate.submitSell(amt8, string(new bytes(281)));
        plead(alice, small(alice), unicode"Arabic سلام and ✓ are fine");
    }

    function test_callbackFitsTheStipend() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        assertTrue(answer(id, 40));
        emit log_named_uint("approve callback gas", intake.lastCallbackGasUsed());
        assertLt(intake.lastCallbackGasUsed(), 120_000);
        uint256 id2 = plead(bob, plea.balanceOf(bob) / 10);
        assertTrue(answer(id2, 1));
        emit log_named_uint("deny callback gas", intake.lastCallbackGasUsed());
        assertLt(intake.lastCallbackGasUsed(), 120_000);
    }

    function test_noPleasWhileTheCabalSleeps() public {
        skip(33 hours);
        assertFalse(gate.cabalAlive());
        uint256 amt9 = small(alice);
        vm.prank(alice);
        vm.expectRevert(CabalGate.CabalNotWatching.selector);
        gate.submitSell(amt9, "x");
    }

    function deliverOnce(bytes32 rid, OracleAttestation.Attestation memory a) internal returns (bool) {
        return intake.complete(rid, 0, abi.encode(rid, a, sign(a)));
    }

    /// @dev The signer key gains an EIP-7702 delegation (code): its plain signatures still verify.
    function test_signerWithDelegationCodeStillVerifies() public {
        vm.etch(SIGNER, hex"ef0100ca11bde05977b3631167028862be2a173976ca11");
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        assertTrue(answer(id, 40));
    }

    // ---------------------------------------------------------------- Intake v2 failure function

    function test_pleaAsksWithTheFailureFunction() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        assertEq(intake.failureOf(intakeIdOf(id)), gate.onPleaFailure.selector);
    }

    function test_failureClearsThePendingPleaWithoutCooldownOrClock() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        uint64 clock = gate.lastVerdictAt();
        uint256 bal = plea.balanceOf(alice);
        vm.expectEmit(true, false, false, true, address(gate));
        emit CabalGate.PleaExpired(id);
        vm.expectEmit(true, false, false, true, address(gate));
        emit CabalGate.PleaFailed(id, 2, bytes32("disagreed"), 13, 28);
        assertTrue(intake.fail(intakeIdOf(id), 2, bytes32("disagreed"), 13, 28));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
        assertEq(gate.pendingOf(alice), 0);
        assertEq(gate.pleaOfIntake(intakeIdOf(id)), 0);
        assertEq(gate.lastVerdictAt(), clock, "a failure is not a verdict");
        assertEq(gate.lastDeniedAt(alice), 0);
        assertEq(plea.balanceOf(alice), bal, "no value moves");
        plead(alice, small(alice)); // may plead again at once
    }

    function test_refusalClearsThePleaToo() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        assertTrue(intake.fail(intakeIdOf(id), 1, bytes32("body_refused"), 0, 0));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
    }

    function test_failedAppealCanBeRetried() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        assertTrue(answer(id, 0));
        uint256 amt10 = small(alice);
        vm.prank(alice);
        uint256 a = gate.appeal(id, amt10, "Please reconsider.");
        assertTrue(intake.fail(intakeIdOf(a), 2, bytes32("disagreed"), 12, 30));
        assertFalse(gate.getPlea(id).appealed);
        uint256 amt11 = small(alice);
        vm.prank(alice);
        gate.appeal(id, amt11, "Asking once more.");
    }

    function test_failureOnlyFromTheIntake() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        bytes32 rid = intakeIdOf(id);
        vm.expectRevert(CabalGate.NotIntake.selector);
        gate.onPleaFailure(rid, 2, bytes32("disagreed"), 0, 0, "");
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Pending));
    }

    function test_failureForAnUnknownOrSettledRequestDoesNothing() public {
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(CabalGate.UnknownRequest.selector, bytes32("x")));
        gate.onPleaFailure(bytes32("x"), 2, bytes32("failed"), 0, 0, "");
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        bytes32 rid = intakeIdOf(id);
        assertTrue(answer(id, 45)); // approved
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(CabalGate.UnknownRequest.selector, rid));
        gate.onPleaFailure(rid, 2, bytes32("failed"), 0, 0, "");
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Approved));
    }

    function test_failureAfterExpireIsRefused() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        bytes32 rid = intakeIdOf(id);
        skip(20 minutes + 1);
        gate.expire(id);
        assertFalse(intake.fail(rid, 2, bytes32("failed"), 0, 0));
    }

    function test_failureFitsTheMainnetGas() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        assertTrue(intake.fail(intakeIdOf(id), 2, bytes32("disagreed"), 13, 28));
        assertLt(intake.lastCallbackGasUsed(), 100_000);
    }

    // ---------------------------------------------------------------- prize PLEA and the fact score

    /// A season winner who bought a week earlier and then receives prize PLEA: selling up to the
    /// bought amount keeps the hold-time and P&L points, and the larger balance only helps the
    /// share-of-balance points. Selling more than was bought loses those two parts.
    function test_prizePleaOnTopOfAWeekOldBuy() public {
        buy(alice, 50e18);
        skip(7 days + 1);
        buy(bob, 1e18); // fresh hourly price checkpoint
        (, uint256 tracked,) = hook.basisOf(alice);
        uint256 bal = plea.balanceOf(alice);
        uint256 part = bal * 3 / 10; // 30% of the balance, all of it bought
        assertLe(part, tracked);
        uint8 before = gate.factScore(alice, part);
        deal(address(plea), alice, bal * 3); // prize PLEA on top (no buy record)
        uint8 withPrize = gate.factScore(alice, part);
        assertGe(withPrize, before, "a prize never lowers the score for bought tokens");
        assertEq(withPrize - before, 7, "share of balance 30% -> under 20%: 11 -> 18 points");
        uint8 beyond = gate.factScore(alice, tracked + 1);
        assertLt(beyond, withPrize, "selling more than was bought drops hold-time and P&L points");
    }
}
