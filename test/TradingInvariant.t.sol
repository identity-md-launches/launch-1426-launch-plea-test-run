// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PLEA} from "src/PLEA.sol";
import {CabalGate} from "src/CabalGate.sol";
import {PleaHook} from "src/PleaHook.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {SepoliaFixture} from "./utils/SepoliaFixture.sol";
import {MockIMD, MockSIMD, MockIntake, BuyRouter} from "./utils/Mocks.sol";

contract TradingHandler is Test {
    PLEA public token;
    CabalGate public gate;
    PleaHook public hook;
    MockIMD public imd;
    MockIMD public feeAsset;
    MockSIMD public simd;
    MockIntake public intake;
    BuyRouter public router;
    address[3] public actors;
    address public keeper;
    uint256 private signerKey;
    uint256 public donations;
    uint256 public plainCashback;
    uint256 public redeemedCashback;
    uint256 public redemptionCalls;
    uint256 public buyCalls;
    uint256 public sellCalls;
    uint256 public verdictCalls;
    uint256 public rebalanceCalls;
    uint256 public previousCap;
    bool public dead;

    struct Environment {
        PLEA token;
        CabalGate gate;
        PleaHook hook;
        MockIMD imd;
        MockIMD feeAsset;
        MockSIMD simd;
        MockIntake intake;
        BuyRouter router;
        address[3] actors;
        address keeper;
        uint256 signerKey;
    }

    constructor(Environment memory e) {
        token = e.token;
        gate = e.gate;
        hook = e.hook;
        imd = e.imd;
        feeAsset = e.feeAsset;
        simd = e.simd;
        intake = e.intake;
        router = e.router;
        actors = e.actors;
        keeper = e.keeper;
        signerKey = e.signerKey;
        previousCap = hook.inventoryCap();
        for (uint256 i; i < 3; ++i) {
            vm.startPrank(actors[i]);
            imd.approve(address(hook), type(uint256).max);
            token.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function buy(uint256 actorSeed, uint256 raw) external {
        address actor = actors[actorSeed % 3];
        uint256 available = imd.balanceOf(actor);
        if (available < 1e12) return;
        uint256 amount = bound(raw, 1e12, available < 200e18 ? available : 200e18);
        uint256 cashbackBefore = hook.totalCashback();
        uint256 claimsBefore = quoteClaims(actor);
        vm.prank(actor);
        uint256 received = router.buyExactIn(amount, abi.encode(actor));
        assertGt(received, 0, "a funded buy must deliver tokens");
        ++buyCalls;
        afterTrade(actor, cashbackBefore, claimsBefore);
    }

    function submit(uint256 actorSeed, uint256 raw) external {
        address actor = actors[actorSeed % 3];
        if (!gate.cabalAlive()) return;
        if (
            vm.getBlockTimestamp() < gate.lastExecutedAt(actor) + 4 hours
                || vm.getBlockTimestamp() < gate.lastDeniedAt(actor) + 4 hours
                || vm.getBlockTimestamp() < gate.lastLapsedAt(actor) + 4 hours
        ) return;
        uint256 pending = gate.pendingOf(actor);
        if (pending != 0) {
            CabalGate.Plea memory p = gate.getPlea(pending);
            if (p.status == CabalGate.Status.Pending) {
                (,,, bool completed) = intake.requests(p.intakeId);
                if (vm.getBlockTimestamp() <= uint256(p.submittedAt) + 20 minutes && !completed) return;
            } else if (vm.getBlockTimestamp() <= uint256(p.verdictAt) + 7 minutes) {
                return;
            } else if (vm.getBlockTimestamp() < uint256(p.verdictAt) + 4 hours) {
                uint256 feeBefore = feeAsset.balanceOf(actor);
                vm.expectRevert(abi.encodeWithSelector(CabalGate.Cooldown.selector, uint256(p.verdictAt) + 4 hours));
                vm.prank(actor);
                gate.submitSell(1, "The expired approval cannot shorten my cooldown.");
                assertEq(gate.pendingOf(actor), pending);
                assertEq(feeAsset.balanceOf(actor), feeBefore);
                return;
            }
        }
        uint256 maximum = token.balanceOf(actor) * 15 / 100;
        if (maximum > 2_500_000e18) maximum = 2_500_000e18;
        if (maximum == 0) return;
        uint256 amount = bound(raw, 1, maximum);
        uint256 need = 70 - gate.factScore(actor, amount);
        uint256 balanceBefore = feeAsset.balanceOf(actor);
        if (need > 45) vm.expectRevert(abi.encodeWithSelector(CabalGate.CannotPass.selector, need));
        vm.prank(actor);
        uint256 id = gate.submitSell(amount, "I need a small sale for rent and will keep the rest.");
        if (need > 45) {
            assertEq(feeAsset.balanceOf(actor), balanceBefore);
            return;
        }
        assertEq(feeAsset.balanceOf(actor), balanceBefore - 0.5e18);
        assertEq(gate.pendingOf(actor), id);
        assertEq(gate.getPlea(id).seller, actor);
    }

    function verdict(uint256 actorSeed, uint256 rawScore) external {
        uint256 id = gate.pendingOf(actors[actorSeed % 3]);
        CabalGate.Plea memory p = gate.getPlea(id);
        if (p.status != CabalGate.Status.Pending) return;
        (,,, bool completed) = intake.requests(p.intakeId);
        if (completed) return;
        uint256 score = bound(rawScore, 0, 45);
        OracleAttestation.Attestation memory a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("stateful verdict", id)),
            chainId: 1,
            questionHash: keccak256(bytes(gate.question(id))),
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(score),
            figure: score,
            fromBlock: 26_000_000,
            toBlock: 26_000_300,
            blockHash: keccak256("test block"),
            panelJobId: keccak256(abi.encode("panel", id)),
            panelSize: 30,
            quorum: 17,
            agreed: 17,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 1 hours)
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, gate.attestationDigest(a));
        bool live = gate.cabalAlive() && vm.getBlockTimestamp() <= uint256(p.submittedAt) + 20 minutes;
        uint64 lastVerdict = gate.lastVerdictAt();
        bool delivered = intake.complete(p.intakeId, 0, abi.encode(p.intakeId, a, abi.encodePacked(r, s, v)));
        assertEq(delivered, live, "valid timely oracle callback must fit the 200k stipend");
        if (live) {
            ++verdictCalls;
            assertTrue(gate.consumed(a.requestId));
            assertEq(gate.lastVerdictAt(), vm.getBlockTimestamp());
            assertEq(
                uint8(gate.getPlea(id).status),
                uint8(score >= p.need ? CabalGate.Status.Approved : CabalGate.Status.Denied)
            );
        } else {
            assertFalse(gate.consumed(a.requestId));
            assertEq(gate.lastVerdictAt(), lastVerdict);
        }
    }

    function execute(uint256 actorSeed) external {
        address actor = actors[actorSeed % 3];
        uint256 id = gate.pendingOf(actor);
        CabalGate.Plea memory p = gate.getPlea(id);
        if (p.status != CabalGate.Status.Approved || vm.getBlockTimestamp() > uint256(p.verdictAt) + 7 minutes) return;
        if (token.balanceOf(actor) < p.amount) return;
        uint256 cashbackBefore = hook.totalCashback();
        uint256 claimsBefore = quoteClaims(actor);
        uint256 balanceBefore = token.balanceOf(actor);
        uint256 quoteBefore = imd.balanceOf(actor);
        vm.prank(actor);
        uint256 out = gate.executeSell(0);
        // With minOut=0 a dust sell may legitimately round its quote output to zero.
        uint256 plain = simd.paused() ? hook.totalCashback() - cashbackBefore - (quoteClaims(actor) - claimsBefore) : 0;
        assertEq(imd.balanceOf(actor), quoteBefore + out + plain);
        assertEq(token.balanceOf(actor), balanceBefore - p.amount);
        assertEq(gate.pendingOf(actor), 0);
        assertEq(uint8(gate.getPlea(id).status), uint8(CabalGate.Status.Executed));
        ++sellCalls;
        afterTrade(actor, cashbackBefore, claimsBefore);
    }

    function freeSell(uint256 actorSeed, uint256 raw, bool sellAll) external {
        if (gate.cabalAlive()) return;
        address actor = actors[actorSeed % 3];
        uint256 balance = token.balanceOf(actor);
        if (balance < 1e12) return;
        uint256 amount = sellAll ? balance : bound(raw, 1e12, balance);
        uint256 cashbackBefore = hook.totalCashback();
        uint256 claimsBefore = quoteClaims(actor);
        vm.prank(actor);
        router.sellExactIn(amount, abi.encode(actor));
        ++sellCalls;
        afterTrade(actor, cashbackBefore, claimsBefore);
    }

    function quoteClaims(address who) public view returns (uint256) {
        return hook.poolManager().balanceOf(who, uint256(uint160(address(imd))));
    }

    function redeemClaims(uint256 actorSeed, uint256 raw) external {
        bool isOwner = actorSeed % 4 == 3;
        address holder = isOwner ? token.owner() : actors[actorSeed % 3];
        uint256 available = quoteClaims(holder);
        if (available == 0) return;
        uint256 amount = bound(raw, 1, available);
        IPoolManager pm = hook.poolManager();
        vm.prank(holder);
        pm.approve(address(this), uint256(uint160(address(imd))), amount);
        uint256 before = imd.balanceOf(holder);
        pm.unlock(abi.encode(holder, amount));
        assertEq(imd.balanceOf(holder), before + amount);
        assertEq(quoteClaims(holder), available - amount);
        if (!isOwner) redeemedCashback += amount;
        ++redemptionCalls;
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        IPoolManager pm = hook.poolManager();
        require(msg.sender == address(pm), "manager only");
        (address holder, uint256 amount) = abi.decode(data, (address, uint256));
        pm.burn(holder, uint256(uint160(address(imd))), amount);
        pm.take(Currency.wrap(address(imd)), holder, amount);
        return "";
    }

    function fundWall(uint256 actorSeed, uint256 raw) external {
        address actor = actors[actorSeed % 3];
        uint256 balance = imd.balanceOf(actor);
        uint256 amount = bound(raw, 0, balance < 1000e18 ? balance : 1000e18);
        uint256 before = hook.retainedImd();
        vm.prank(actor);
        hook.fundWall(amount);
        assertEq(hook.retainedImd(), before + amount);
    }

    function donateQuote(uint256 actorSeed, uint256 raw) external {
        address actor = actors[actorSeed % 3];
        uint256 balance = imd.balanceOf(actor);
        uint256 amount = bound(raw, 0, balance < 1e18 ? balance : 1e18);
        vm.prank(actor);
        imd.transfer(address(hook), amount);
        donations += amount;
    }

    function rebalance() external {
        if (!hook.pendingRebalance()) return;
        uint160 price = hook.currentSqrtPriceX96();
        uint256 cap = hook.inventoryCap();
        vm.prank(keeper);
        hook.rebalance();
        assertEq(hook.currentSqrtPriceX96(), price, "moving liquidity must not move spot price");
        assertEq(hook.inventoryCap(), cap);
        ++rebalanceCalls;
    }

    function pauseCashback(bool paused) external {
        simd.setPaused(paused);
    }

    function advance(uint256 raw) external {
        vm.warp(vm.getBlockTimestamp() + bound(raw, 0, 12 hours));
        vm.roll(block.number + 1);
        if (dead) assertFalse(gate.cabalAlive());
        dead = !gate.cabalAlive();
    }

    function afterTrade(address actor, uint256 cashbackBefore, uint256 claimsBefore) internal {
        // Claim payouts do not call Stacker, including when it is paused. Count only actual cash here.
        if (simd.paused()) {
            plainCashback += hook.totalCashback() - cashbackBefore - (quoteClaims(actor) - claimsBefore);
        }
        uint256 cap = hook.inventoryCap();
        assertLe(cap, previousCap, "cap can only ratchet down");
        assertGe(cap, 900_000e18);
        previousCap = cap;
        if (dead) assertFalse(gate.cabalAlive());
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TradingInvariantTest is SepoliaFixture {
    TradingHandler internal handler;
    uint256 internal seedBurn;
    uint256 internal initialCap;
    uint256 internal decayStart;

    function setUp() public virtual override {
        super.setUp();
        seedBurn = plea.TOTAL_SUPPLY() - plea.totalSupply();
        initialCap = hook.inventoryCap();
        decayStart = hook.lastCapDecayAt();
        handler = new TradingHandler(
            TradingHandler.Environment({
                token: plea,
                gate: gate,
                hook: hook,
                imd: imd,
                feeAsset: oimd,
                simd: simd,
                intake: intake,
                router: router,
                actors: [alice, bob, carol],
                keeper: keeper,
                signerKey: SIGNER_KEY
            })
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.buy.selector;
        selectors[1] = handler.submit.selector;
        selectors[2] = handler.verdict.selector;
        selectors[3] = handler.execute.selector;
        selectors[4] = handler.freeSell.selector;
        selectors[5] = handler.fundWall.selector;
        selectors[6] = handler.donateQuote.selector;
        selectors[7] = handler.rebalance.selector;
        selectors[8] = handler.pauseCashback.selector;
        selectors[9] = handler.advance.selector;
        selectors[10] = handler.redeemClaims.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_allPleaIsAccountedForAndSupplyOnlyFallsByActualBurns() public view {
        uint256 sum =
            plea.balanceOf(address(pm)) + plea.balanceOf(address(distributor)) + plea.balanceOf(address(seasons));
        for (uint256 i; i < users.length; ++i) {
            sum += plea.balanceOf(users[i]);
        }
        assertEq(sum, plea.totalSupply());
        assertEq(plea.totalSupply() + hook.totalBurned() + seedBurn + seasons.bonusBurned(), 1_000_000_000e18);
        assertEq(plea.balanceOf(address(hook)), 0);
        assertEq(plea.balanceOf(address(gate)), 0);
        assertEq(plea.balanceOf(address(router)), 0);
        assertEq(plea.balanceOf(address(distributor)), 100_000_000e18);
    }

    /// @dev The Stacker is approved per credit and the credit consumes it (or the approval is reset
    /// when the credit reverts): between calls the wall reserve is never within its reach.
    function invariant_stackerHoldsNoStandingAllowanceOnTheHooksImd() public view {
        assertEq(imd.allowance(address(hook), address(stacker)), 0, "Stacker allowance left standing");
    }

    function invariant_quoteConservationAndFeePaymentsMatchTheirCounters() public view {
        uint256 sum = imd.balanceOf(address(pm)) + imd.balanceOf(address(hook)) + imd.balanceOf(address(seasons))
            + imd.balanceOf(address(stacker)) + imd.balanceOf(OWNER) + imd.balanceOf(keeper);
        uint256 oracleSum = oimd.balanceOf(intake.PAY_TO());
        uint256 stacked;
        uint256 cashbackClaims;
        for (uint256 i; i < users.length; ++i) {
            sum += imd.balanceOf(users[i]);
            oracleSum += oimd.balanceOf(users[i]);
            stacked += simd.balanceOf(users[i]);
            cashbackClaims += handler.quoteClaims(users[i]);
        }
        assertEq(sum, imd.totalSupply());
        assertEq(oracleSum, oimd.totalSupply());
        assertEq(imd.balanceOf(address(gate)), 0);
        assertEq(oimd.balanceOf(address(gate)), 0);
        assertEq(imd.balanceOf(OWNER) + handler.quoteClaims(OWNER), hook.totalOwnerFees());
        assertEq(seasons.pot(), hook.totalPrize());
        assertEq(imd.balanceOf(address(stacker)), simd.totalSupply());
        assertEq(stacked, simd.totalSupply());
        assertEq(stacked + handler.plainCashback() + cashbackClaims + handler.redeemedCashback(), hook.totalCashback());
    }

    function invariant_wallReservesClaimsAndGateStateRemainBacked() public view {
        assertEq(imd.balanceOf(address(hook)), hook.retainedImd() + handler.donations());
        assertEq(pm.balanceOf(address(hook), uint256(uint160(address(imd)))), hook.retainClaims());
        uint256 allClaims = hook.retainClaims() + handler.quoteClaims(OWNER) + handler.quoteClaims(address(seasons));
        for (uint256 i; i < users.length; ++i) {
            allClaims += handler.quoteClaims(users[i]);
        }
        assertGe(imd.balanceOf(address(pm)), allClaims, "pool cash backs every claim beneficiary");
        assertLe(hook.inventoryCap(), initialCap);
        uint256 used = initialCap - hook.inventoryCap();
        assertLe(used * 1 days, hook.capDecayPerDay() * (vm.getBlockTimestamp() - decayStart));
        assertEq(used * 1 days, hook.capDecayPerDay() * (hook.lastCapDecayAt() - decayStart) + hook.capDecayRemainder());
        for (uint256 i; i < users.length; ++i) {
            assertEq(
                pm.balanceOf(users[i], uint256(uint160(address(plea)))), 0, "restricted buys must not leak PLEA claims"
            );
            uint256 id = gate.pendingOf(users[i]);
            if (id != 0) {
                CabalGate.Plea memory p = gate.getPlea(id);
                assertEq(p.seller, users[i]);
                assertTrue(p.status == CabalGate.Status.Pending || p.status == CabalGate.Status.Approved);
            }
        }
        if (handler.dead()) assertFalse(plea.restricted());
    }

    function test_handlerExercisesTradingVerdictsRebalancesAndDeath() public {
        handler.buy(0, 100e18);
        handler.buy(1, 100e18);
        handler.submit(0, 100e18);
        handler.verdict(0, 45);
        handler.execute(0);
        handler.pauseCashback(true);
        handler.buy(2, 50e18);
        handler.fundWall(0, 200e18);
        handler.rebalance();
        for (uint256 i; i < 9; ++i) {
            handler.advance(4 hours);
        }
        handler.freeSell(0, 0, true);
        assertGt(handler.buyCalls(), 0);
        assertGt(handler.sellCalls(), 1);
        assertGt(handler.verdictCalls(), 0);
        assertGt(handler.rebalanceCalls(), 0);
        assertTrue(handler.dead());
        invariant_allPleaIsAccountedForAndSupplyOnlyFallsByActualBurns();
        invariant_quoteConservationAndFeePaymentsMatchTheirCounters();
        invariant_wallReservesClaimsAndGateStateRemainBacked();
    }

    function testFuzz_handlerAccountsForClaimFeesAndTheirRedemption(bool paused) public {
        handler.buy(0, 1e12);
        handler.pauseCashback(paused);
        handler.buy(1, 200e18); // its fees exceed the cash left by the first tiny buy
        assertGt(handler.quoteClaims(OWNER), 0);
        assertGt(handler.quoteClaims(bob), 0);
        assertGt(handler.quoteClaims(address(seasons)), 0);
        invariant_quoteConservationAndFeePaymentsMatchTheirCounters();
        invariant_wallReservesClaimsAndGateStateRemainBacked();
        handler.redeemClaims(3, handler.quoteClaims(OWNER));
        handler.redeemClaims(1, handler.quoteClaims(bob));
        assertEq(handler.redemptionCalls(), 2);
        assertEq(handler.quoteClaims(OWNER), 0);
        assertEq(handler.quoteClaims(bob), 0);
        assertGt(handler.redeemedCashback(), 0);
        invariant_allPleaIsAccountedForAndSupplyOnlyFallsByActualBurns();
        invariant_quoteConservationAndFeePaymentsMatchTheirCounters();
        invariant_wallReservesClaimsAndGateStateRemainBacked();
    }
}

/// @dev The same sequences with PLEA sorted before IMD exercise both v4 currency orientations.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract TradingPleaZeroInvariantTest is TradingInvariantTest {
    function pleaFirst() internal pure override returns (bool) {
        return true;
    }
}
