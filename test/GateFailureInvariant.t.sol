// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./utils/Fixture.sol";
import {MockIMD, MockIntake, BuyRouter} from "./utils/Mocks.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {PLEA} from "../src/PLEA.sol";

/// @notice Random sequences of pleas, signed answers, Intake v2 failures, expiries, appeals and
/// sells. Every failure is checked in place: it clears only its own pending plea and moves nothing.
contract GateFailureHandler is Test {
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    string constant TEXT = "I have held through every candle and need to pay rent; I keep the rest.";

    CabalGate public gate;
    MockIntake public intake;
    PLEA public plea;
    MockIMD public imd;
    MockIMD public oimd;

    address[] public actors;
    address public stranger = makeAddr("stranger");
    mapping(address => uint256) public lastDenied;

    uint256 public asks;
    uint256 public strangerAsks;
    uint64 public ghostLastVerdict;
    uint64 public ghostDiedAt;
    uint256 public failures;
    uint256 public answered;
    uint256 nonce;

    constructor(CabalGate gate_, MockIntake intake_, PLEA plea_, MockIMD imd_, MockIMD oimd_, address[] memory a) {
        gate = gate_;
        intake = intake_;
        plea = plea_;
        imd = imd_;
        oimd = oimd_;
        actors = a;
        ghostLastVerdict = gate_.lastVerdictAt();
        oimd_.mint(stranger, 1_000e18);
        vm.prank(stranger);
        oimd_.approve(address(intake_), type(uint256).max);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _pending(address who) internal view returns (uint256 id, CabalGate.Plea memory p) {
        id = gate.pendingOf(who);
        if (id != 0) p = gate.getPlea(id);
    }

    function plead(uint256 actorSeed, uint256 bpsSeed) external {
        address who = _actor(actorSeed);
        uint256 amount = plea.balanceOf(who) * bound(bpsSeed, 1, 1_500) / 10_000;
        if (amount > gate.MAX_SELL()) amount = gate.MAX_SELL();
        vm.prank(who);
        try gate.submitSell(amount, TEXT) returns (uint256) {
            ++asks;
        } catch {}
    }

    function appeal(uint256 actorSeed, uint256 bpsSeed) external {
        address who = _actor(actorSeed);
        uint256 o = lastDenied[who];
        if (o == 0) return;
        uint256 amount = gate.getPlea(o).amount * bound(bpsSeed, 1, 10_000) / 10_000;
        vm.prank(who);
        try gate.appeal(o, amount, "Please reconsider my plea.") returns (uint256) {
            ++asks;
        } catch {}
    }

    function answer(uint256 actorSeed, uint256 scoreSeed) external {
        address who = _actor(actorSeed);
        (uint256 id, CabalGate.Plea memory p) = _pending(who);
        if (id == 0 || p.status != CabalGate.Status.Pending) return;
        (,,, bool completed) = intake.requests(p.intakeId);
        if (completed) return;
        uint256 score = bound(scoreSeed, 0, 45);
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("answer", id, ++nonce)),
            chainId: 1,
            questionHash: keccak256("question"),
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(score),
            figure: score,
            fromBlock: 26_000_000,
            toBlock: 26_000_300,
            blockHash: keccak256("block"),
            panelJobId: keccak256(abi.encode("job", id)),
            panelSize: 30,
            quorum: 17,
            agreed: 20,
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 3600)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, gate.attestationDigest(a));
        bool live = block.timestamp <= uint256(p.submittedAt) + gate.PENDING_EXPIRY() && gate.cabalAlive();
        bool delivered = intake.complete(p.intakeId, 0, abi.encode(p.intakeId, a, abi.encodePacked(r, s, v)));
        assertEq(delivered, live, "a fresh signed answer for a live pending plea is delivered");
        if (!delivered) return;
        ++answered;
        ghostLastVerdict = uint64(block.timestamp);
        if (score < p.need) lastDenied[who] = id;
        assertEq(gate.pleaOfIntake(p.intakeId), 0, "an answered request is forgotten");
    }

    /// The Intake reports a refusal (1) or no agreement (2) for an actor's request.
    function fail(uint256 actorSeed, uint256 statusSeed, bytes32 reason, uint16 agreed, uint16 answeredCount) external {
        address who = _actor(actorSeed);
        (uint256 id, CabalGate.Plea memory p) = _pending(who);
        if (id == 0 || p.status != CabalGate.Status.Pending) return;
        (,,, bool completed) = intake.requests(p.intakeId);
        if (completed) return;
        uint8 status = uint8(bound(statusSeed, 1, 2));
        uint256[6] memory before = _balances(who);
        uint64 clock = gate.lastVerdictAt();
        uint256 denied = gate.lastDeniedAt(who);
        uint256 lapsed = gate.lastLapsedAt(who);
        uint256 executed = gate.lastExecutedAt(who);

        vm.expectEmit(true, false, false, true, address(gate));
        emit CabalGate.PleaFailed(id, status, reason, agreed, answeredCount);
        assertTrue(intake.fail(p.intakeId, status, reason, agreed, answeredCount), "failure delivered");
        ++failures;

        CabalGate.Plea memory q = gate.getPlea(id);
        assertEq(uint8(q.status), uint8(CabalGate.Status.Expired));
        assertEq(q.score, 0, "a failure is no verdict");
        assertEq(q.verdictAt, 0);
        assertEq(gate.pendingOf(who), 0);
        assertEq(gate.pleaOfIntake(p.intakeId), 0);
        if (p.isAppeal) assertFalse(gate.getPlea(p.originalId).appealed, "a failed appeal may be retried");
        assertEq(gate.lastVerdictAt(), clock, "a failure never resets the dead-man");
        assertEq(gate.lastDeniedAt(who), denied);
        assertEq(gate.lastLapsedAt(who), lapsed);
        assertEq(gate.lastExecutedAt(who), executed);
        uint256[6] memory afterBal = _balances(who);
        for (uint256 i; i < 6; ++i) {
            assertEq(afterBal[i], before[i], "a failure moves no value");
        }
    }

    /// A stranger pays the Intake, names the gate's functions and makes its own request fail.
    function strangerFails(uint256 statusSeed) external {
        vm.prank(stranger);
        bytes32 rid = intake.requestWithFailure(
            bytes32("oracle.request@oracle-1"),
            "{}",
            MockIntake.Callback({target: address(gate), selector: gate.onOracleResult.selector}),
            gate.onPleaFailure.selector,
            address(oimd),
            0.5e18
        );
        ++strangerAsks;
        uint256[6] memory before = _balances(stranger);
        assertFalse(intake.fail(rid, uint8(bound(statusSeed, 1, 2)), bytes32("disagreed"), 1, 2), "not ours");
        uint256[6] memory afterBal = _balances(stranger);
        for (uint256 i; i < 6; ++i) {
            assertEq(afterBal[i], before[i]);
        }
    }

    /// Anyone but the Intake calling the failure function directly, even with a live request id.
    function directFailure(uint256 actorSeed, address caller) external {
        if (caller == address(intake)) return;
        (uint256 id, CabalGate.Plea memory p) = _pending(_actor(actorSeed));
        bytes32 rid = id == 0 ? keccak256(abi.encode(caller)) : p.intakeId;
        vm.prank(caller);
        vm.expectRevert(CabalGate.NotIntake.selector);
        gate.onPleaFailure(rid, 2, bytes32("disagreed"), 0, 0, "");
    }

    /// The fallback: anyone expires a stale pending plea.
    function expire(uint256 actorSeed) external {
        (uint256 id, CabalGate.Plea memory p) = _pending(_actor(actorSeed));
        if (id == 0 || p.status != CabalGate.Status.Pending) return;
        bool stale = block.timestamp > uint256(p.submittedAt) + gate.PENDING_EXPIRY();
        (,,, bool completed) = intake.requests(p.intakeId);
        if (!stale && !completed) {
            vm.expectRevert(CabalGate.NotStale.selector);
            gate.expire(id);
            return;
        }
        uint64 clock = gate.lastVerdictAt();
        gate.expire(id);
        assertEq(gate.lastVerdictAt(), clock);
        // A failure arriving after the fallback has nothing left to clear.
        if (!completed) assertFalse(intake.fail(p.intakeId, 2, bytes32("late"), 0, 0));
    }

    function execute(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        (uint256 id, CabalGate.Plea memory p) = _pending(who);
        if (id == 0 || p.status != CabalGate.Status.Approved) return;
        vm.prank(who);
        try gate.executeSell(0) {} catch {}
    }

    function advance(uint256 raw) external {
        skip(bound(raw, 1, 3 hours));
        if (ghostDiedAt == 0 && gate.diedAt() != 0) ghostDiedAt = gate.diedAt();
    }

    function _balances(address who) internal view returns (uint256[6] memory b) {
        b[0] = plea.balanceOf(who);
        b[1] = imd.balanceOf(who);
        b[2] = oimd.balanceOf(who);
        b[3] = plea.balanceOf(address(gate));
        b[4] = imd.balanceOf(address(gate));
        b[5] = oimd.balanceOf(address(gate));
    }
}

contract GateFailureInvariantTest is Fixture {
    GateFailureHandler handler;

    function setUp() public override {
        super.setUp();
        users.push(makeAddr("dave"));
        fund(users[3]);
        for (uint256 i; i < users.length; ++i) {
            buy(users[i], 2_000e18);
        }
        skip(1 days); // some holding time, so a plea can pass
        handler = new GateFailureHandler(gate, intake, plea, imd, oimd, users);
        targetContract(address(handler));
    }

    /// The handler reaches every path it claims to: asks, failures, denials, appeals, approvals.
    function test_handlerReachesFailuresVerdictsAndAppeals() public {
        handler.plead(0, 1_000);
        assertEq(handler.asks(), 1, "a plea is asked");
        handler.fail(0, 2, bytes32("disagreed"), 13, 28);
        assertEq(handler.failures(), 1, "the failure clears it");
        handler.plead(0, 1_000);
        handler.answer(0, 0); // denied
        assertEq(handler.answered(), 1);
        assertGt(handler.lastDenied(users[0]), 0);
        handler.appeal(0, 10_000);
        assertEq(handler.asks(), 3, "the appeal is asked");
        handler.fail(0, 1, bytes32("body_refused"), 0, 0);
        assertEq(handler.failures(), 2);
        handler.appeal(0, 10_000); // retried after the failure
        assertEq(handler.asks(), 4);
        handler.answer(0, 45);
        assertEq(uint8(gate.getPlea(gate.pendingOf(users[0])).status), uint8(CabalGate.Status.Approved));
        handler.execute(0);
        assertEq(gate.pendingOf(users[0]), 0, "sold");
        handler.plead(1, 500);
        handler.advance(21 minutes);
        handler.expire(1);
        assertEq(gate.pendingOf(users[1]), 0, "the fallback clears it");
        handler.strangerFails(2);
        handler.directFailure(2, address(this));
        invariant_gateHoldsNothing();
        invariant_pendingBookkeepingIsConsistent();
        invariant_onlyVerdictsMoveTheClock();
    }

    /// A failure arriving after the Cabal died still only clears the plea; it cannot revive it.
    function test_failureAfterDeathDoesNotReviveTheCabal() public {
        handler.plead(0, 1_000);
        uint256 id = gate.pendingOf(users[0]);
        bytes32 rid = gate.getPlea(id).intakeId;
        vm.warp(uint256(gate.lastVerdictAt()) + gate.DEADMAN());
        assertFalse(gate.cabalAlive());
        uint64 died = gate.diedAt();
        assertTrue(intake.fail(rid, 2, bytes32("disagreed"), 0, 0));
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Expired));
        assertFalse(gate.cabalAlive());
        assertEq(gate.diedAt(), died);
        assertFalse(gate.restricted());
    }

    /// The gate never keeps custody: oracle fees go to the Intake, appeal shares to the wall, sells
    /// straight through the pool.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_gateHoldsNothing() public view {
        assertEq(plea.balanceOf(address(gate)), 0);
        assertEq(imd.balanceOf(address(gate)), 0);
        assertEq(oimd.balanceOf(address(gate)), 0);
        assertEq(oimd.balanceOf(intake.PAY_TO()), (handler.asks() + handler.strangerAsks()) * gate.ORACLE_FEE());
    }

    /// Each seller's open plea is theirs and actionable, and a request id maps to a plea exactly
    /// while that plea is pending.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_pendingBookkeepingIsConsistent() public view {
        for (uint256 i; i < users.length; ++i) {
            uint256 id = gate.pendingOf(users[i]);
            if (id == 0) continue;
            CabalGate.Plea memory p = gate.getPlea(id);
            assertEq(p.seller, users[i]);
            assertTrue(p.status == CabalGate.Status.Pending || p.status == CabalGate.Status.Approved);
        }
        uint256 n = gate.nextId();
        for (uint256 id = 1; id < n; ++id) {
            CabalGate.Plea memory p = gate.getPlea(id);
            bool mapped = gate.pleaOfIntake(p.intakeId) == id;
            assertEq(mapped, p.status == CabalGate.Status.Pending, "intake id mapped iff pending");
            if (p.status == CabalGate.Status.Pending) assertEq(gate.pendingOf(p.seller), id);
            if (p.isAppeal && p.status != CabalGate.Status.Expired) {
                assertTrue(gate.getPlea(p.originalId).appealed, "a live appeal marks its original");
            }
        }
    }

    /// Only a signed verdict moves the dead-man clock, and a dead Cabal stays dead.
    /// forge-config: default.invariant.runs = 64
    /// forge-config: default.invariant.depth = 64
    function invariant_onlyVerdictsMoveTheClock() public view {
        assertEq(gate.lastVerdictAt(), handler.ghostLastVerdict());
        if (handler.ghostDiedAt() != 0) {
            assertFalse(gate.cabalAlive());
            assertEq(gate.diedAt(), handler.ghostDiedAt());
        }
    }
}
