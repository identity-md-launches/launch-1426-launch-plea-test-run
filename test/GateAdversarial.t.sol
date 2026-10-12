// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SepoliaFixture} from "./utils/SepoliaFixture.sol";
import {CabalGate} from "src/CabalGate.sol";
import {OracleAttestation, OracleAttestationConsumer} from "src/OracleAttestation.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// forge-config: default.fuzz.runs = 256
contract GateAdversarialTest is SepoliaFixture {
    function setUp() public override {
        super.setUp();
        buy(alice, 50e18);
        buy(bob, 50e18);
    }

    function test_pendingAndExecutionDeadlinesAreInclusive() public {
        uint256 amount = plea.balanceOf(alice) / 10;
        uint256 id = plead(alice, amount);
        vm.warp(uint256(gate.getPlea(id).submittedAt) + 20 minutes);
        vm.expectRevert(CabalGate.NotStale.selector);
        gate.expire(id);
        assertTrue(answer(id, 45));
        vm.warp(uint256(gate.getPlea(id).verdictAt) + 7 minutes);
        vm.prank(alice);
        gate.executeSell(1);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        assertEq(gate.lastExecutedAt(alice), vm.getBlockTimestamp());
    }

    function test_latePendingCannotConsumeSignatureOrExtendHeartbeat() public {
        uint256 id = plead(alice, 1e18);
        bytes32 request = intakeIdOf(id);
        uint64 heartbeat = gate.lastVerdictAt();
        vm.warp(uint256(gate.getPlea(id).submittedAt) + 20 minutes + 1);
        OracleAttestation.Attestation memory a = attestation(45, keccak256("late result"));
        bytes memory signature = sign(a);
        vm.prank(address(intake));
        vm.expectRevert(CabalGate.TooLate.selector);
        gate.onOracleResult(request, a, signature);
        assertFalse(gate.consumed(a.requestId));
        assertEq(gate.lastVerdictAt(), heartbeat);
        gate.expire(id);
        assertEq(gate.pendingOf(alice), 0);
        assertEq(gate.pleaOfIntake(request), 0);
        vm.expectRevert(CabalGate.NotPending.selector);
        gate.expire(id);
    }

    function test_approvedWindowOnlyClearsAfterTheLastSecond() public {
        uint256 id = plead(alice, 1e18);
        assertTrue(answer(id, 45));
        uint256 verdictAt = gate.getPlea(id).verdictAt;
        vm.warp(verdictAt + 7 minutes);
        vm.prank(alice);
        vm.expectRevert(CabalGate.PendingExists.selector);
        gate.submitSell(1e18, "another plea");
        vm.warp(vm.getBlockTimestamp() + 1);
        uint256 feeBalance = oimd.balanceOf(alice);
        vm.expectRevert(abi.encodeWithSelector(CabalGate.Cooldown.selector, verdictAt + 4 hours));
        plead(alice, 1e18);
        assertEq(gate.pendingOf(alice), id, "failed submission must roll back stale clearing");
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Approved));
        assertEq(oimd.balanceOf(alice), feeBalance);
        vm.prank(alice);
        vm.expectRevert(CabalGate.WindowLapsed.selector);
        gate.executeSell(0);
        vm.warp(verdictAt + 4 hours);
        uint256 next = plead(alice, 1e18);
        assertEq(gate.pendingOf(alice), next);
        assertEq(gate.lastLapsedAt(alice), verdictAt);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Lapsed));
        (,, bool approved,) = gate.result(id);
        assertTrue(approved, "lapsed approvals still earn season points");
    }

    function test_denialCooldownEndsExactlyAtFourHours() public {
        uint256 id = plead(alice, 1e18);
        assertTrue(answer(id, 0));
        uint256 until = gate.lastDeniedAt(alice) + 4 hours;
        vm.warp(until - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CabalGate.Cooldown.selector, until));
        gate.submitSell(1e18, "too soon");
        vm.warp(until);
        uint256 next = plead(alice, 1e18);
        assertGt(next, id);
    }

    function test_appealIsAcceptedAtItsLastSecondAndCannotBeStolen() public {
        uint256 id = plead(alice, 1e18);
        assertTrue(answer(id, 0));
        vm.prank(bob);
        vm.expectRevert(CabalGate.NotSeller.selector);
        gate.appeal(id, 1e18, "not my plea");
        vm.warp(uint256(gate.getPlea(id).verdictAt) + 4 hours);
        uint256 before = hook.retainedImd();
        vm.prank(alice);
        uint256 appealId = gate.appeal(id, 1e18, "my final second");
        assertTrue(gate.getPlea(id).appealed);
        assertTrue(gate.getPlea(appealId).isAppeal);
        assertEq(hook.retainedImd(), before + 0.35e18);
    }

    function test_appealOracleFeeFailureRollsBackWallFundingAndOriginalFlag() public {
        uint256 id = plead(alice, 1e18);
        assertTrue(answer(id, 0));
        uint256 next = gate.nextId();
        uint256 reserve = hook.retainedImd();
        uint256 wallBalance = imd.balanceOf(address(hook));
        uint256 balance = imd.balanceOf(alice);
        vm.prank(alice);
        oimd.approve(address(gate), 0);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(gate), uint256(0), 0.5e18)
        );
        gate.appeal(id, 1e18, "retryable appeal");
        assertFalse(gate.getPlea(id).appealed);
        assertEq(gate.nextId(), next);
        assertEq(gate.pendingOf(alice), 0);
        assertEq(hook.retainedImd(), reserve);
        assertEq(imd.balanceOf(address(hook)), wallBalance);
        assertEq(imd.balanceOf(alice), balance);
        vm.startPrank(alice);
        oimd.approve(address(gate), 0.5e18);
        assertEq(gate.appeal(id, 1e18, "retryable appeal"), next);
        vm.stopPrank();
    }

    function test_slippageRevertRestoresApprovalSupplyAndAllFeeState() public {
        uint256 id = plead(alice, plea.balanceOf(alice) / 10);
        assertTrue(answer(id, 45));
        bytes32 before = sellState(alice);
        vm.prank(alice);
        vm.expectPartialRevert(CabalGate.SlippageExceeded.selector);
        gate.executeSell(type(uint256).max);
        assertEq(sellState(alice), before, "failed sell must roll back the nested pool swap and fees");
        assertEq(gate.pendingOf(alice), id);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Approved));
        assertEq(gate.lastExecutedAt(alice), 0);
        vm.prank(alice);
        assertGt(gate.executeSell(1), 0);
        vm.prank(alice);
        vm.expectRevert(CabalGate.NotApproved.selector);
        gate.executeSell(0);
    }

    function test_missingSellAllowanceDoesNotConsumeTheApprovedPlea() public {
        uint256 id = plead(alice, 1e18);
        assertTrue(answer(id, 45));
        vm.prank(alice);
        plea.approve(address(gate), 0);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(gate), uint256(0), 1e18)
        );
        gate.executeSell(0);
        assertEq(gate.pendingOf(alice), id);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Approved));
        assertEq(plea.balanceOf(address(gate)), 0);
    }

    function test_amountLimitsFailBeforeChargingAndOneWeiCanBeSubmitted() public {
        uint256 before = oimd.balanceOf(alice);
        uint256[4] memory amounts =
            [uint256(0), 2_500_000e18 + 1, plea.balanceOf(alice) * 35 / 100 + 1, type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(CabalGate.AmountTooLarge.selector);
            gate.submitSell(amounts[i], "invalid size");
            assertEq(oimd.balanceOf(alice), before);
            assertEq(gate.pendingOf(alice), 0);
        }
        uint256 id = plead(alice, 1);
        assertEq(gate.getPlea(id).amount, 1);
        assertEq(oimd.balanceOf(alice), before - 0.5e18);
    }

    function test_gateUnlockCallbackCannotBeInvokedOutsideItsOwnSale() public {
        bytes memory raw = abi.encode(alice, 1e18);
        vm.expectRevert(CabalGate.NotPoolManager.selector);
        gate.unlockCallback(raw);
        vm.prank(address(pm));
        vm.expectRevert(CabalGate.CallbackNotExpected.selector);
        gate.unlockCallback(raw);
        assertEq(plea.balanceOf(address(gate)), 0);
    }

    function testFuzz_panelAndAnswerValidationCannotConsumeRequests(uint8 seed) public {
        uint256 id = plead(alice, 1e18);
        bytes32 rid = intakeIdOf(id);
        OracleAttestation.Attestation memory a = attestation(45, keccak256("invalid then valid"));
        uint256 field = bound(seed, 0, 6);
        bytes memory reason = abi.encodeWithSelector(CabalGate.WrongPanel.selector);
        if (field == 0) a.chainId = 11155111;
        if (field == 1) a.panelSize = 29;
        if (field == 2) a.quorum = 16;
        if (field == 3) a.agreed = 16;
        if (field == 4) {
            a.answerType = OracleAttestation.ANSWER_BOOL;
            reason = abi.encodeWithSelector(OracleAttestationConsumer.WrongAnswerType.selector, uint8(3), uint8(0));
        }
        if (field == 5) {
            a.answer = abi.encode(uint256(46));
            reason = abi.encodeWithSelector(CabalGate.ScoreOutOfRange.selector, uint256(46));
        }
        if (field == 6) {
            a.expiresAt = uint64(vm.getBlockTimestamp() - 1);
            reason = abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt);
        }
        uint64 heartbeat = gate.lastVerdictAt();
        bytes memory signature = sign(a);
        vm.prank(address(intake));
        vm.expectRevert(reason);
        gate.onOracleResult(rid, a, signature);
        assertFalse(gate.consumed(a.requestId));
        assertEq(gate.lastVerdictAt(), heartbeat);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Pending));
        a = attestation(45, a.requestId);
        assertTrue(deliver(rid, a));
        assertTrue(gate.consumed(a.requestId));
    }

    /// @dev Meeting our minimum 17 votes does not meet a larger quorum declared by the signed panel.
    function testFuzz_signedQuorumMustBeReached(uint16 rawQuorum, bool approved) public {
        uint256 id = plead(alice, 1e18);
        bytes32 rid = intakeIdOf(id);
        uint64 heartbeat = gate.lastVerdictAt();
        skip(1);
        OracleAttestation.Attestation memory a = attestation(approved ? 45 : 0, keccak256("signed quorum"));
        a.quorum = uint16(bound(rawQuorum, 18, 30));
        a.agreed = a.quorum - 1; // still at least the gate's minimum of 17
        bytes memory signature = sign(a);
        vm.prank(address(intake));
        vm.expectRevert(CabalGate.WrongPanel.selector);
        gate.onOracleResult(rid, a, signature);
        assertFalse(gate.consumed(a.requestId));
        assertEq(gate.pleaOfIntake(rid), id);
        assertEq(gate.pendingOf(alice), id);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Pending));
        assertEq(gate.getPlea(id).verdictAt, 0);
        assertEq(gate.lastVerdictAt(), heartbeat);
        assertEq(gate.lastDeniedAt(alice), 0);

        // Exactly reaching that same signed quorum is sufficient, within the Intake's stipend.
        a.agreed = a.quorum;
        assertTrue(deliver(rid, a));
        assertTrue(gate.consumed(a.requestId));
        assertEq(uint8(gate.getPlea(id).status), uint8(approved ? CabalGate.Status.Approved : CabalGate.Status.Denied));
        assertLt(intake.lastCallbackGasUsed(), 200_000);
    }

    function test_futureIssuanceAndExpiredAttestationsRejectAtExactBoundaries() public {
        uint256 id = plead(alice, 1e18);
        bytes32 rid = intakeIdOf(id);
        OracleAttestation.Attestation memory a = attestation(45, keccak256("time bounds"));
        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes + 1);
        bytes memory signature = sign(a);
        vm.prank(address(intake));
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        gate.onOracleResult(rid, a, signature);
        assertFalse(gate.consumed(a.requestId));
        a.issuedAt = uint64(vm.getBlockTimestamp() + 5 minutes);
        assertTrue(deliver(rid, a));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Approved));

        uint256 second = plead(bob, 1e18);
        a = attestation(45, keccak256("inclusive expiration"));
        a.expiresAt = uint64(vm.getBlockTimestamp());
        assertTrue(deliver(intakeIdOf(second), a));
        assertEq(uint8(gate.getPlea(second).status), uint8(CabalGate.Status.Approved));
    }

    function test_changingSignedAnswerOrConsumerChainInvalidatesSignature() public {
        uint256 id = plead(alice, 1e18);
        bytes32 rid = intakeIdOf(id);
        OracleAttestation.Attestation memory a = attestation(0, keccak256("tamper"));
        bytes memory signature = sign(a);
        a.answer = abi.encode(uint256(45));
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        gate.onOracleResult(rid, a, signature);
        a.answer = abi.encode(uint256(0));
        vm.chainId(1);
        vm.prank(address(intake));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        gate.onOracleResult(rid, a, signature);
        vm.chainId(11155111);
        assertFalse(gate.consumed(a.requestId));
        assertTrue(intake.complete(rid, 0, abi.encode(rid, a, signature)));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Denied));
    }

    function test_deadManExpiresAtTheExactSecondAndNeverAcceptsANewVerdict() public {
        vm.warp(uint256(gate.lastVerdictAt()) + 118800 - 1);
        assertTrue(gate.cabalAlive());
        uint256 id = plead(alice, 1e18);
        uint64 expectedDeath = gate.lastVerdictAt() + 118800;
        vm.warp(expectedDeath);
        assertFalse(gate.cabalAlive());
        assertFalse(plea.restricted());
        assertEq(gate.diedAt(), expectedDeath);
        assertFalse(answer(id, 45));
        assertEq(gate.diedAt(), expectedDeath);
        vm.prank(alice);
        vm.expectRevert(CabalGate.CabalNotWatching.selector);
        gate.submitSell(1, "cannot revive");
    }

    function testFuzz_printablePleaRoundTripsThroughQuestionJson(uint256 seed, uint16 rawLength) public {
        uint256 length = bound(rawLength, 1, 280);
        bytes memory text = new bytes(length);
        for (uint256 i; i < length; ++i) {
            uint8 c = uint8(32 + uint256(keccak256(abi.encode(seed, i))) % 95);
            text[i] = c == uint8(bytes1("[")) ? bytes1("(") : bytes1(c);
        }
        uint256 id = plead(alice, 1e18, string(text));
        assertEq(gate.pleaText(id), string(text));
        assertEq(vm.parseJsonString(gate.body(id), ".question"), gate.question(id));
        assertEq(vm.parseJsonUint(gate.body(id), ".panelSize"), 30);
        assertEq(vm.parseJsonUint(gate.body(id), ".quorum"), 17);
    }

    function test_malformedUtf8AndHiddenControlsFailWithoutCharging() public {
        bytes[12] memory bad = [
            bytes(hex"80"),
            hex"c080",
            hex"c1bf",
            hex"e08080",
            hex"eda080",
            hex"f4908080",
            hex"f0808080",
            hex"e282",
            hex"c280",
            hex"c2ad",
            hex"efbbbf",
            hex"7f"
        ];
        uint256 balance = oimd.balanceOf(alice);
        for (uint256 i; i < bad.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(CabalGate.BadPleaText.selector);
            gate.submitSell(1e18, string(bad[i]));
            assertEq(oimd.balanceOf(alice), balance);
            assertEq(gate.pendingOf(alice), 0);
        }
    }

    function sellState(address actor) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                plea.totalSupply(),
                plea.balanceOf(actor),
                imd.balanceOf(actor),
                imd.balanceOf(OWNER),
                imd.balanceOf(address(seasons)),
                simd.balanceOf(actor),
                hook.totalBurned(),
                hook.totalCashback(),
                hook.totalOwnerFees(),
                hook.totalPrize(),
                hook.totalPoolFees(),
                hook.retainClaims(),
                hook.inventoryCap(),
                hook.currentSqrtPriceX96()
            )
        );
    }
}
