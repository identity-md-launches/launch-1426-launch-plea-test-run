// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./utils/Fixture.sol";
import {MockIMD, MockIntake} from "./utils/Mocks.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Letterbox} from "../src/Letterbox.sol";
import {PLEA} from "../src/PLEA.sol";

/// @notice Random sequences of letters (raw input data, `letter(text)` and the site's auto-sell
/// `plead`), appeals (the same three ways), signed answers, Intake failures, `deliver` by a runner,
/// the writers' own `SELL`, `settle` by anyone, strangers trying the court's entry points, and time
/// passing (the Cabal may die). A broken expectation inside a step is recorded in `broken` rather
/// than reverted, because a reverting step is simply skipped by the fuzzer.
contract LetterboxHandler is Test {
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 constant TIP = 0.25e18;
    string constant TEXT = "One tenth for my rent; the rest stays with me all season.";
    string constant APPEAL_TEXT = "Plainly: the rent is due, and I keep the other nine tenths.";

    CabalGate public gate;
    Letterbox public letterbox;
    MockIntake public intake;
    PLEA public plea;
    MockIMD public imd;

    address[] public writers;
    address public runner = makeAddr("runner");
    address public stranger = makeAddr("stranger");

    /// @dev Every escrow ever opened, in order.
    uint256[] public ids;
    /// @dev Each writer's PLEA when the run began, and the PLEA their fee sales spent since.
    mapping(address => uint256) public start;
    mapping(address => uint256) public fees;

    string public broken;
    uint256 public letters;
    uint256 public appeals;
    uint256 public sitePleas;
    uint256 public approvals;
    uint256 public denials;
    uint256 public failures;
    uint256 public deliveries;
    uint256 public sells;
    uint256 public settles;
    uint256 nonce;

    constructor(
        CabalGate gate_,
        Letterbox letterbox_,
        MockIntake intake_,
        PLEA plea_,
        MockIMD imd_,
        address[] memory w
    ) {
        gate = gate_;
        letterbox = letterbox_;
        intake = intake_;
        plea = plea_;
        imd = imd_;
        writers = w;
        for (uint256 i; i < w.length; ++i) {
            start[w[i]] = plea_.balanceOf(w[i]);
        }
    }

    function writerCount() external view returns (uint256) {
        return writers.length;
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function _check(bool ok, string memory why) internal {
        if (!ok && bytes(broken).length == 0) broken = why;
    }

    function _writer(uint256 seed) internal view returns (address) {
        return writers[bound(seed, 0, writers.length - 1)];
    }

    // ---------------------------------------------------------------- writing

    /// A new plea by letter (`how` 0: raw input data, 1: `letter(text)`) or by the site's auto-sell
    /// (`how` 2: `plead(amount, text)` with 1%-50% of the balance).
    function write(uint256 writerSeed, uint256 how, uint256 bps) external {
        _send(_writer(writerSeed), how % 3, bps, false);
    }

    /// An appeal of the writer's latest plea, the same three ways.
    function appeal(uint256 writerSeed, uint256 how) external {
        _send(_writer(writerSeed), how % 3, 0, true);
    }

    function _send(address w, uint256 how, uint256 bps, bool isAppeal) internal {
        uint256 maxFee;
        try letterbox.feesFor(isAppeal) returns (uint256, uint256 m) {
            maxFee = m;
        } catch {
            return;
        }
        (uint256 old,) = letterbox.openOf(w);
        uint256 balBefore = plea.balanceOf(w);
        bool ok;
        if (!isAppeal && how == 2) {
            uint256 siteAmount = balBefore * bound(bps, 100, 5_000) / 10_000;
            if (siteAmount > gate.MAX_SELL()) siteAmount = gate.MAX_SELL();
            vm.prank(w);
            try letterbox.plead(siteAmount, TEXT) returns (uint256) {
                ok = true;
            } catch {}
        } else if (isAppeal && how == 2) {
            uint256 o = gate.lastPleaOf(w);
            vm.prank(w);
            try letterbox.appealAuto(o, APPEAL_TEXT) returns (uint256) {
                ok = true;
            } catch {}
        } else {
            string memory text = isAppeal ? string.concat("APPEAL ", APPEAL_TEXT) : TEXT;
            if (how == 0) {
                vm.prank(w);
                (ok,) = address(letterbox).call(bytes(text));
            } else {
                vm.prank(w);
                try letterbox.letter(text) {
                    ok = true;
                } catch {}
            }
        }
        if (!ok) {
            _check(plea.balanceOf(w) == balBefore, "a refused letter moved PLEA");
            return;
        }
        uint256 id = gate.lastPleaOf(w);
        (address writer, bool open, uint256 amount,) = letterbox.escrowOf(id);
        _check(writer == w && open && amount > 0, "the new escrow is the writer's and open");
        CabalGate.Plea memory p = gate.getPlea(id);
        _check(p.seller == w && p.isAppeal == isAppeal, "the plea is the writer's");
        _check(p.status == CabalGate.Status.Pending, "the new plea is pending");
        // A previous open escrow was ended first (refunded: it cannot have been sold in this call).
        uint256 refunded;
        if (old != 0 && old != id) {
            (, bool stillOpen, uint256 oldAmount, uint256 sold) = letterbox.escrowOf(old);
            _check(!stillOpen && sold == 0, "the previous escrow was settled first");
            refunded = oldAmount;
        }
        uint256 balAfter = plea.balanceOf(w);
        if (balBefore + refunded < amount + balAfter) {
            _check(false, "a letter took more than its escrow and fees");
            return;
        }
        uint256 fee = balBefore + refunded - amount - balAfter;
        _check(fee > 0 && fee <= maxFee, "the fee sale stays within the snapshot value + 10%");
        fees[w] += fee;
        ids.push(id);
        if (isAppeal) ++appeals;
        else if (how == 2) ++sitePleas;
        else ++letters;
    }

    // ---------------------------------------------------------------- verdicts

    function answer(uint256 writerSeed, uint256 scoreSeed) external {
        address w = _writer(writerSeed);
        uint256 id = gate.pendingOf(w);
        if (id == 0) return;
        CabalGate.Plea memory p = gate.getPlea(id);
        if (p.status != CabalGate.Status.Pending) return;
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
        if (!intake.complete(p.intakeId, 0, abi.encode(p.intakeId, a, abi.encodePacked(r, s, v)))) return;
        if (score >= p.need) ++approvals;
        else ++denials;
    }

    function fail(uint256 writerSeed, uint256 statusSeed) external {
        address w = _writer(writerSeed);
        uint256 id = gate.pendingOf(w);
        if (id == 0) return;
        CabalGate.Plea memory p = gate.getPlea(id);
        if (p.status != CabalGate.Status.Pending) return;
        (,,, bool completed) = intake.requests(p.intakeId);
        if (completed) return;
        if (intake.fail(p.intakeId, uint8(bound(statusSeed, 1, 2)), bytes32("disagreed"), 13, 28)) ++failures;
    }

    // ---------------------------------------------------------------- endings

    /// A runner delivers any escrow; only an approved one inside its window may sell.
    function deliver(uint256 idSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[bound(idSeed, 0, ids.length - 1)];
        (address w,, uint256 amount,) = letterbox.escrowOf(id);
        uint256 writerPlea = plea.balanceOf(w);
        uint256 writerImd = imd.balanceOf(w);
        uint256 tips = imd.balanceOf(runner);
        uint256 pot = imd.balanceOf(plea.seasons());
        vm.prank(runner);
        try letterbox.deliver(id) returns (uint256 out) {
            ++deliveries;
            _checkSold(id);
            _check(imd.balanceOf(runner) - tips == TIP, "the runner earns exactly the tip");
            _check(imd.balanceOf(w) - writerImd == out, "the sale's IMD goes to the writer");
            _check(imd.balanceOf(plea.seasons()) - pot >= 0.35e18, "the auto-sell fee reached the season pot");
            _check(plea.balanceOf(w) == writerPlea && amount > 0, "a delivery moves no PLEA of the writer's");
        } catch {}
    }

    /// The writer's own `SELL` letter.
    function sell(uint256 writerSeed) external {
        address w = _writer(writerSeed);
        (uint256 id,) = letterbox.openOf(w);
        uint256 writerImd = imd.balanceOf(w);
        vm.prank(w);
        (bool ok,) = address(letterbox).call("SELL");
        if (!ok) return;
        ++sells;
        _checkSold(id);
        (,,, uint256 soldFor) = letterbox.escrowOf(id);
        _check(imd.balanceOf(w) - writerImd == soldFor + TIP, "SELL pays the sale and the tip back");
    }

    /// Anyone settles any escrow: the escrow and the tip go back to its writer, never to the caller.
    function settle(uint256 idSeed, uint256 callerSeed) external {
        if (ids.length == 0) return;
        uint256 id = ids[bound(idSeed, 0, ids.length - 1)];
        (address w,, uint256 amount,) = letterbox.escrowOf(id);
        uint256 k = bound(callerSeed, 0, writers.length + 1);
        address caller = k < writers.length ? writers[k] : (k == writers.length ? stranger : runner);
        uint256 writerPlea = plea.balanceOf(w);
        uint256 writerImd = imd.balanceOf(w);
        uint256 callerPlea = plea.balanceOf(caller);
        vm.prank(caller);
        try letterbox.settle(id) {
            ++settles;
            (, bool open,, uint256 soldFor) = letterbox.escrowOf(id);
            _check(!open && soldFor == 0, "a settled escrow is closed and unsold");
            _check(plea.balanceOf(w) - writerPlea == amount, "settle returns exactly the escrow");
            _check(imd.balanceOf(w) - writerImd == TIP, "settle returns exactly the tip");
            if (caller != w) _check(plea.balanceOf(caller) == callerPlea, "the caller gets nothing");
        } catch {}
    }

    function _checkSold(uint256 id) internal {
        (, bool open,, uint256 soldFor) = letterbox.escrowOf(id);
        CabalGate.Plea memory p = gate.getPlea(id);
        _check(!open && soldFor > 0, "a sold escrow is closed with its price");
        _check(p.status == CabalGate.Status.Executed && p.score >= p.need, "only an approved plea sells");
    }

    // ---------------------------------------------------------------- strangers and time

    /// The court's entry points refuse anyone else, and an escrowed plea cannot be sold around
    /// the Letterbox.
    function poke(uint256 writerSeed) external {
        address w = _writer(writerSeed);
        uint256 last = gate.lastPleaOf(w);
        vm.prank(stranger);
        try plea.courtTake(w, 1) {
            _check(false, "a stranger moved PLEA with courtTake");
        } catch {}
        vm.prank(stranger);
        try gate.submitFor(w, 1e18, 10e18, TEXT, 3, 0, 0) returns (uint256, uint256) {
            _check(false, "a stranger pleaded for a writer");
        } catch {}
        vm.prank(stranger);
        try gate.appealFor(w, last, 1e18, 10e18, TEXT, 3, 0, 0) returns (uint256, uint256) {
            _check(false, "a stranger appealed for a writer");
        } catch {}
        vm.prank(stranger);
        try gate.executeSellFor(last, 0) returns (uint256) {
            _check(false, "a stranger sold a writer's plea");
        } catch {}
        vm.prank(w);
        try gate.executeSell(0) returns (uint256) {
            _check(false, "an escrowed plea sold around the Letterbox");
        } catch {}
        vm.prank(stranger);
        (bool ok,) = address(letterbox).call("SELL");
        _check(!ok, "a stranger's SELL letter did something");
    }

    function advance(uint256 raw) external {
        vm.warp(block.timestamp + bound(raw, 1 minutes, 6 hours));
    }
}

/// The Letterbox holds exactly its open escrows and tips, every escrow ends once (sold only after
/// an approval, otherwise refunded to its writer), and no writer's PLEA moves except through their
/// own letters. Sepolia mode: the Letterbox mints the test oracle fee and buys only the tip.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 80
contract LetterboxInvariantTest is Fixture {
    LetterboxHandler handler;

    function setUp() public virtual override {
        super.setUp();
        users.push(makeAddr("dave"));
        fund(users[3]);
        for (uint256 i; i < users.length; ++i) {
            buy(users[i], 2_000e18);
        }
        skip(1 days); // some holding time, so pleas can pass
        handler = new LetterboxHandler(gate, letterbox, intake, plea, imd, users);
        targetContract(address(handler));
    }

    /// The handler reaches every path it claims to.
    function test_handlerReachesEveryPath() public {
        handler.write(0, 0, 0); // raw letter
        handler.answer(0, 45);
        handler.deliver(0); // runner
        handler.write(1, 1, 0); // letter(text)
        handler.answer(1, 0); // denied
        handler.appeal(1, 0); // raw APPEAL, settles the denied escrow first
        handler.answer(1, 45);
        handler.sell(1); // the writer's SELL
        handler.write(2, 2, 1_000); // site auto-sell
        handler.fail(2, 2); // no verdict
        handler.settle(3, 5); // carol's, settled by the runner, refunded to her
        handler.write(3, 1, 0);
        handler.answer(3, 0);
        handler.appeal(3, 2); // appealAuto
        handler.advance(21 minutes);
        handler.poke(3);
        handler.settle(5, 4); // dave's stale appeal, by a stranger
        assertEq(handler.letters(), 3);
        assertEq(handler.appeals(), 2);
        assertEq(handler.sitePleas(), 1);
        assertEq(handler.deliveries(), 1);
        assertEq(handler.sells(), 1);
        assertGe(handler.settles(), 2);
        assertEq(handler.failures(), 1);
        assertEq(handler.broken(), "");
        invariant_holdsExactlyTheOpenEscrowsAndTips();
        invariant_everyWritersPleaIsAccountedFor();
        invariant_escrowsMatchTheirPleas();
    }

    function invariant_noStepBrokeAnExpectation() public view {
        assertEq(handler.broken(), "");
    }

    function invariant_holdsExactlyTheOpenEscrowsAndTips() public view {
        uint256 n = handler.idCount();
        uint256 escrowed;
        uint256 openCount;
        for (uint256 i; i < n; ++i) {
            (, bool open, uint256 amount,) = letterbox.escrowOf(handler.ids(i));
            if (open) {
                escrowed += amount;
                ++openCount;
            }
        }
        (, uint256 counted) = letterbox.openOf(address(0));
        assertEq(counted, openCount, "open count");
        assertEq(plea.balanceOf(address(letterbox)), escrowed, "PLEA held = open escrows");
        assertEq(imd.balanceOf(address(letterbox)), openCount * 0.25e18, "IMD held = one tip per open escrow");
        assertEq(oimd.balanceOf(address(letterbox)), 0, "no oracle fee left behind");
        assertEq(plea.allowance(address(letterbox), address(gate)), 0, "no PLEA allowance left");
        assertEq(imd.allowance(address(letterbox), address(gate)), 0, "no IMD allowance left");
        assertEq(plea.balanceOf(address(gate)), 0, "the gate holds no PLEA");
    }

    /// Each writer's PLEA = what they started with - open escrows - sold escrows - fee sales.
    function invariant_everyWritersPleaIsAccountedFor() public view {
        uint256 n = handler.idCount();
        for (uint256 k; k < users.length; ++k) {
            address w = users[k];
            uint256 out;
            for (uint256 i; i < n; ++i) {
                (address writer, bool open, uint256 amount, uint256 soldFor) = letterbox.escrowOf(handler.ids(i));
                if (writer == w && (open || soldFor > 0)) out += amount;
            }
            assertEq(plea.balanceOf(w) + out + handler.fees(w), handler.start(w), "a writer's PLEA is accounted for");
        }
    }

    /// Every escrow is its plea's: same writer and amount, flagged auto-sell; sold only once
    /// approved; at most one open escrow per writer, and `openOf` names it.
    function invariant_escrowsMatchTheirPleas() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            uint256 id = handler.ids(i);
            (address writer, bool open, uint256 amount, uint256 soldFor) = letterbox.escrowOf(id);
            CabalGate.Plea memory p = gate.getPlea(id);
            assertEq(writer, p.seller, "writer = seller");
            assertEq(amount, p.amount, "escrow = plea amount");
            assertTrue((p.flags & 2) != 0, "auto-sell flag");
            if (soldFor > 0) {
                assertFalse(open);
                assertEq(uint8(p.status), uint8(CabalGate.Status.Executed), "sold = executed");
                assertGe(p.score, p.need, "sold only once approved");
            }
            if (open) {
                (uint256 openId,) = letterbox.openOf(writer);
                assertEq(openId, id, "openOf names the open escrow");
            }
        }
        for (uint256 k; k < users.length; ++k) {
            (uint256 openId,) = letterbox.openOf(users[k]);
            if (openId != 0) {
                (address writer, bool open,,) = letterbox.escrowOf(openId);
                assertTrue(open && writer == users[k], "openOf points at the writer's own open escrow");
            }
        }
    }
}

/// The same invariants on the mainnet path: the oracle fee is pool IMD, bought with PLEA in the
/// letter's own transaction together with the tip (and an appeal's wall share).
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 80
contract LetterboxMainnetInvariantTest is LetterboxInvariantTest {
    function oracleFeeToken() internal view override returns (MockIMD) {
        return imd;
    }
}
