// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PLEA} from "../../src/PLEA.sol";
import {CabalGate} from "../../src/CabalGate.sol";
import {Seasons} from "../../src/Seasons.sol";
import {PleaDistributor} from "../../src/PleaDistributor.sol";
import {Letterbox} from "../../src/Letterbox.sol";
import {PleaLaunch} from "../../src/PleaLaunch.sol";
import {PleaHook} from "../../src/PleaHook.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

interface IPoolSwapTest {
    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    function swap(PoolKey memory key, SwapParams memory params, TestSettings memory s, bytes memory hookData)
        external
        payable
        returns (int256);
}

interface IMintable {
    function mint(address to, uint256 amount) external;
}

/// @dev The live Intake v2 on Sepolia: the writer's `complete` (selector 0x0f6261af, read from a
/// live failure delivery) and the request getter.
interface IIntakeV2 {
    function complete(bytes32 requestId, uint8 status, bytes32 resultHash, string calldata uri, bytes calldata args)
        external;

    function requests(bytes32 requestId)
        external
        view
        returns (address payer, address callbackTarget, bytes4 callbackSelector, bool completed);
}

/// Testnet run 3 rehearsal on a Sepolia fork: deploys the seven launch contracts with the values in
/// launch.json (only the oracle signer is a test key, so answers can be signed here), mines and
/// deploys the hook, seeds, and drives every plea outcome through the live Intake v2, completed by
/// impersonating its writer exactly as the plane does. Uses the live PoolManager, PoolSwapTest,
/// TestIMD, test oracle IMD and imd/acc Stacker.
///
/// SEPOLIA_RPC_URL=https://ethereum-sepolia-rpc.publicnode.com forge test --match-path 'test/fork/*' -vv
contract ForkTestnetTest is Test {
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant WRITER = 0x3d3C0Df7C1a17d384545e9D7C8228897bD9625CB;
    address constant ORACLE_IMD = 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A;
    IERC20 constant IMD = IERC20(0x2B69099E59b05901faA1DD164fabf098bf831E82);
    IERC20 constant SIMD = IERC20(0xF9e2EEc3B610ec6781f7438aC5Fb4bc049d81Cc1);
    address constant STACKER = 0x0457276D7b036818B3EddC1A4A3FCeda61e9314d;
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    IPoolSwapTest constant PST = IPoolSwapTest(0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe);
    uint256 constant SEASON = 18_000;
    uint256 constant DEADMAN = 118_800;
    uint256 constant CREDIT_GAS = 1_300_000;
    uint256 constant START = 1792162800;
    uint256 constant SIGNER_KEY = 0xA11CE;

    IIntakeV2 intake = IIntakeV2(INTAKE);
    PLEA plea;
    CabalGate gate;
    Seasons seasons;
    Letterbox letterbox;
    PleaLaunch launch;
    PleaHook hook;
    address owner = makeAddr("owner");
    address[] w;
    uint256 nonce;

    function setUp() public {
        string memory rpc = vm.envOr("SEPOLIA_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        _deploy();
        _deployHook();
        vm.prank(owner);
        launch.seed();
        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string.concat("w", vm.toString(i)));
            w.push(a);
            deal(address(IMD), a, 10_000e18);
            IMintable(ORACLE_IMD).mint(a, 100e18);
            vm.startPrank(a);
            IMD.approve(address(PST), type(uint256).max);
            IMD.approve(address(gate), type(uint256).max);
            IERC20(ORACLE_IMD).approve(address(gate), type(uint256).max);
            plea.approve(address(gate), type(uint256).max);
            plea.approve(address(PST), type(uint256).max);
            vm.stopPrank();
        }
        _warp(vm.getBlockTimestamp() + 91 minutes); // past the launch window
    }

    function _deploy() internal {
        plea = new PLEA(owner);
        gate = new CabalGate(address(plea), INTAKE, ORACLE_IMD, address(IMD), vm.addr(SIGNER_KEY), SEASON, DEADMAN);
        seasons = new Seasons(address(plea), address(gate), address(IMD));
        PleaDistributor distributor = new PleaDistributor(address(plea), owner);
        launch = new PleaLaunch(
            address(plea),
            address(gate),
            address(seasons),
            address(distributor),
            POOL_MANAGER,
            address(IMD),
            STACKER,
            CREDIT_GAS,
            START,
            ORACLE_IMD,
            true,
            keccak256(type(Letterbox).creationCode)
        );
        // After the launch transaction: anyone deploys the committed Letterbox.
        letterbox = Letterbox(launch.deployLetterbox(type(Letterbox).creationCode));
    }

    function _deployHook() internal {
        bytes memory code = abi.encodePacked(
            type(PleaHook).creationCode,
            abi.encode(POOL_MANAGER, address(plea), address(IMD), STACKER, owner, address(seasons), CREDIT_GAS)
        );
        bytes32 h = keccak256(code);
        assertEq(h, launch.hookInitCodeHash());
        uint160 flags = launch.FLAGS();
        uint256 s;
        while (uint160(launch.predict(bytes32(s))) & 0x3fff != flags) {
            ++s;
        }
        hook = PleaHook(launch.deployHook(bytes32(s), code));
    }

    // ---------------------------------------------------------------- helpers

    function _warp(uint256 t) internal {
        vm.warp(t);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _swap(address who, bool isBuy, uint256 amountIn, bytes memory hookData) internal {
        _swap(who, isBuy, amountIn, hookData, false);
    }

    function _swap(address who, bool isBuy, uint256 amountIn, bytes memory hookData, bool reverts) internal {
        // A buy pays IMD for PLEA; zeroForOne when the input currency is currency0.
        bool zeroForOne = isBuy != hook.pleaIsZero();
        PoolKey memory key = hook.poolKey();
        vm.prank(who);
        if (reverts) vm.expectRevert(); // v4 wraps the hook's error
        PST.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            IPoolSwapTest.TestSettings(false, false),
            hookData
        );
    }

    function buy(address who, uint256 imdIn) internal {
        _swap(who, true, imdIn, abi.encode(who));
    }

    function _amount(address who) internal view returns (uint256 amount) {
        amount = plea.balanceOf(who) / 20;
        if (amount > 2_000_000e18) amount = 2_000_000e18;
    }

    function plead(address who) internal returns (uint256 id, bytes32 rid) {
        uint256 amount = _amount(who);
        vm.prank(who);
        id = gate.submitSell(amount, "I am selling a little to pay rent and keeping the rest through every season.");
        rid = gate.getPlea(id).intakeId;
    }

    function _attest(uint256 score) internal returns (OracleAttestation.Attestation memory a) {
        a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("fork", ++nonce)),
            chainId: 1,
            questionHash: keccak256("q"),
            answerType: 3,
            answer: abi.encode(score),
            figure: score,
            fromBlock: 1,
            toBlock: 2,
            blockHash: keccak256("b"),
            panelJobId: keccak256(abi.encode("job", nonce)),
            panelSize: 30,
            quorum: 17,
            agreed: 20,
            issuedAt: uint64(_now()),
            expiresAt: uint64(_now() + 3600)
        });
    }

    /// The plane's writer completes with an answer (status 0): the Intake calls onOracleResult.
    function answer(bytes32 rid, uint256 score) internal {
        OracleAttestation.Attestation memory a = _attest(score);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, gate.attestationDigest(a));
        vm.prank(WRITER);
        intake.complete(rid, 0, keccak256("attestation"), "uri", abi.encode(rid, a, abi.encodePacked(r, s, v)));
    }

    /// The plane's writer completes without an answer: the Intake calls onPleaFailure.
    function fail(bytes32 rid, uint8 status, bytes32 reason, uint16 agreed, uint16 answered) internal {
        vm.prank(WRITER);
        intake.complete(rid, status, bytes32(0), "uri", abi.encode(rid, status, reason, agreed, answered, bytes("")));
    }

    /// Ticks moved toward a higher PLEA price (down in raw ticks when IMD is currency0).
    function _up(int24 from, int24 to) internal view returns (int256) {
        return hook.pleaIsZero() ? int256(to) - int256(from) : int256(from) - int256(to);
    }

    function _status(uint256 id) internal view returns (CabalGate.Status) {
        return gate.getPlea(id).status;
    }

    // ---------------------------------------------------------------- tests

    function test_launchStateMatchesTheManifest() public view {
        assertEq(address(gate.intake()), INTAKE);
        assertEq(address(gate.oracleAsset()), ORACLE_IMD);
        assertEq(gate.SEASON(), SEASON);
        assertEq(gate.DEADMAN(), DEADMAN);
        assertEq(plea.hook(), address(hook));
        assertEq(plea.balanceOf(address(seasons)), 30_000_000e18);
        assertEq(hook.creditGas(), CREDIT_GAS);
        assertApproxEqRel(hook.capDecayPerDay(), (hook.inventoryCap() - hook.CAP_FLOOR()) / 25, 1e15, "25-day decay");
        assertTrue(gate.cabalAlive());
        console2.log("capDecayPerDay", hook.capDecayPerDay());
        console2.log("wallGuardTick", int256(hook.wallGuardTick()));
    }

    function test_buyStacksCashbackAndNeedsARecipient() public {
        address a = w[0];
        uint256 s0 = SIMD.balanceOf(a);
        uint256 g = gasleft();
        buy(a, 100e18);
        console2.log("buy gas (fork)", g - gasleft());
        assertGt(plea.balanceOf(a), 0);
        assertGt(SIMD.balanceOf(a), s0, "cashback stacked as sIMD");
        _swap(a, true, 1e18, "", true); // RecipientRequired
    }

    function test_failureThroughTheLiveIntakeClearsThePlea() public {
        address a = w[0];
        buy(a, 200e18);
        (uint256 id, bytes32 rid) = plead(a);
        (address payer, address target,, bool completed) = intake.requests(rid);
        assertEq(payer, address(gate));
        assertEq(target, address(gate));
        assertFalse(completed);
        uint64 clock = gate.lastVerdictAt();

        vm.expectEmit(true, false, false, true, address(gate));
        emit CabalGate.PleaFailed(id, 2, bytes32("disagreed"), 13, 28);
        uint256 g = gasleft();
        fail(rid, 2, bytes32("disagreed"), 13, 28);
        console2.log("failure delivery gas (fork)", g - gasleft());

        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Expired));
        assertEq(gate.pendingOf(a), 0);
        assertEq(gate.lastVerdictAt(), clock, "a failure is not a verdict");
        assertEq(gate.lastDeniedAt(a), 0, "no cooldown");
        (,,, completed) = intake.requests(rid);
        assertTrue(completed);
        plead(a); // may plead again at once
    }

    function test_refusalThroughTheLiveIntakeClearsThePlea() public {
        address a = w[0];
        buy(a, 200e18);
        (uint256 id, bytes32 rid) = plead(a);
        fail(rid, 1, bytes32("body_invalid"), 0, 0);
        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Expired));
    }

    function test_writerCannotPointAFailureAtAnotherRequest() public {
        buy(w[0], 200e18);
        buy(w[1], 200e18);
        (uint256 id0, bytes32 r0) = plead(w[0]);
        (uint256 id1, bytes32 r1) = plead(w[1]);
        vm.prank(WRITER);
        vm.expectRevert(); // FailureArgsMismatch
        intake.complete(r0, 2, bytes32(0), "uri", abi.encode(r1, uint8(2), bytes32("failed"), 0, 0, bytes("")));
        vm.prank(WRITER);
        vm.expectRevert(); // FailureArgsMismatch: another status
        intake.complete(r0, 2, bytes32(0), "uri", abi.encode(r0, uint8(1), bytes32("failed"), 0, 0, bytes("")));
        assertEq(uint8(_status(id0)), uint8(CabalGate.Status.Pending));
        assertEq(uint8(_status(id1)), uint8(CabalGate.Status.Pending));
    }

    function test_answerApprovesSellsAndRecords() public {
        address a = w[0];
        buy(a, 200e18);
        (uint256 id, bytes32 rid) = plead(a);
        uint256 g = gasleft();
        answer(rid, 45);
        console2.log("answer delivery gas (fork)", g - gasleft());
        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Approved));
        assertEq(gate.lastVerdictAt(), _now());
        uint256 before = IMD.balanceOf(a);
        vm.prank(a);
        gate.executeSell(0);
        assertGt(IMD.balanceOf(a), before);
        seasons.record(id);
        (, uint256 season,) = seasons.currentSeason();
        assertEq(seasons.bestOf(season, a)[0], 45);
        uint256 amt = _amount(a);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(CabalGate.Cooldown.selector, _now() + 4 hours));
        gate.submitSell(amt, "Another plea too soon.");
    }

    function test_deniedAppealFailsThenRetries() public {
        address a = w[0];
        buy(a, 200e18);
        (uint256 id, bytes32 rid) = plead(a);
        answer(rid, 0);
        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Denied));
        uint256 amount = gate.getPlea(id).amount; // an appeal may not ask for more, nor under 1%
        vm.prank(a);
        uint256 ap = gate.appeal(id, amount, "Please reconsider; I keep the rest.");
        fail(gate.getPlea(ap).intakeId, 2, bytes32("disagreed"), 12, 30);
        assertEq(uint8(_status(ap)), uint8(CabalGate.Status.Expired));
        assertFalse(gate.getPlea(id).appealed);
        vm.prank(a);
        uint256 retry = gate.appeal(id, amount, "Asking once more, in my own words.");
        answer(gate.getPlea(retry).intakeId, 45);
        assertEq(uint8(_status(retry)), uint8(CabalGate.Status.Approved));
    }

    function test_lateFailureAfterExpireIsHarmless() public {
        address a = w[0];
        buy(a, 200e18);
        (uint256 id, bytes32 rid) = plead(a);
        _warp(_now() + 20 minutes + 1);
        gate.expire(id);
        fail(rid, 2, bytes32("failed"), 0, 0); // the failure call reverts inside the Intake's try
        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Expired));
        (,,, bool completed) = intake.requests(rid);
        assertTrue(completed);
    }

    function test_lateAnswerAfterAFailureCannotApprove() public {
        address a = w[0];
        buy(a, 200e18);
        (uint256 id, bytes32 rid) = plead(a);
        fail(rid, 2, bytes32("disagreed"), 13, 28);
        vm.prank(WRITER);
        vm.expectRevert(); // already completed
        intake.complete(rid, 0, bytes32(0), "uri", "");
        // even a direct call from the Intake finds no plea for that request
        OracleAttestation.Attestation memory at = _attest(45);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, gate.attestationDigest(at));
        vm.prank(INTAKE);
        vm.expectRevert(abi.encodeWithSelector(CabalGate.UnknownRequest.selector, rid));
        gate.onOracleResult(rid, at, abi.encodePacked(r, s, v));
        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Expired));
    }

    function test_capDecaysAtMostTheDailyRateAndTheGuardLagsAPump() public {
        uint256 rate = hook.capDecayPerDay();
        uint256 cap0 = hook.inventoryCap();
        buy(w[0], 2_000e18);
        uint256 cap1 = hook.inventoryCap();
        assertLe(cap0 - cap1, rate, "no jump to the holdings");
        int24 g0 = hook.wallGuardTick();
        int24 spot0 = hook.currentTick();
        // A pump held over many blocks: refTick follows ~200 ticks a block, the guard must not.
        for (uint256 i; i < 10; ++i) {
            _warp(_now() + 12);
            buy(w[1], 300e18);
        }
        int24 g1 = hook.wallGuardTick();
        int256 pumped = _up(spot0, hook.currentTick());
        int256 jump = _up(g0, g1);
        assertGt(pumped, 400, "the price rose");
        assertLe(jump, 1, "the guard did not follow the pump within the same minutes");
        _warp(_now() + 1 days);
        buy(w[2], 1e18);
        int24 g2 = hook.wallGuardTick();
        int256 rise = _up(g1, g2);
        assertLe(rise, 401, "the guard rises at most ~4% a day");
        assertGt(rise, 0, "the guard follows a held price slowly");
        console2.log("price rise in ticks", pumped);
        _warp(_now() + 10 days);
        buy(w[3], 1e18);
        uint256 cap2 = hook.inventoryCap();
        assertGe(cap2, hook.CAP_FLOOR());
        assertLe(cap0 - cap2, rate * (_now() - gate.startedAt()) / 1 days + 1, "decay bounded by the daily allowance");
        assertGt(cap1 - cap2, 0, "the cap followed the buys down");
        console2.log("cap at seed", cap0);
        console2.log("cap after buys", cap1);
        console2.log("cap 11 days later", cap2);
        console2.log("guard before pump", int256(g0));
        console2.log("guard after pump", int256(g1));
        console2.log("guard a day later", int256(g2));
        hook.rebalance();
    }

    function test_deadCabalFreesTradingAndFlushesThePot() public {
        address a = w[0];
        buy(a, 500e18);
        (uint256 id, bytes32 rid) = plead(a);
        answer(rid, 45);
        vm.prank(a);
        gate.executeSell(0);
        seasons.record(id);
        _warp(gate.lastVerdictAt() + DEADMAN + 1);
        assertFalse(gate.cabalAlive());
        assertFalse(plea.restricted());
        // a plain sell through the router, still with a recipient in hookData
        uint256 before = IMD.balanceOf(w[1]);
        buy(w[1], 100e18);
        _swap(w[1], false, plea.balanceOf(w[1]) / 2, abi.encode(w[1]));
        assertGt(IMD.balanceOf(w[1]), before - 100e18);
        uint256 amt = _amount(a);
        vm.prank(a);
        vm.expectRevert(CabalGate.CabalNotWatching.selector);
        gate.submitSell(amt, "Too late, the Cabal is gone.");
        _warp(_now() + SEASON + 2 hours);
        while (!seasons.finished()) {
            seasons.closeSeason(new uint256[](0));
        }
        seasons.flushToWall();
        assertEq(seasons.pot(), 0);
        assertEq(plea.balanceOf(address(seasons)), 0, "the unused PLEA bonus is burned");
        assertEq(seasons.bonusBurned(), 30_000_000e18);
    }

    function test_seasonWinnerGetsThePleaBonus() public {
        address a = w[0];
        buy(a, 500e18);
        uint256 t0 = gate.startedAt();
        _warp(t0 + SEASON + 1); // season 1 (the second season), from its start
        (uint256 id1, bytes32 r1) = plead(a);
        answer(r1, 40);
        vm.prank(a);
        gate.executeSell(0);
        _warp(_now() + 4 hours + 1);
        (uint256 id2, bytes32 r2) = plead(a);
        answer(r2, 41);
        vm.prank(a);
        gate.executeSell(0);
        seasons.record(id1);
        seasons.record(id2);
        _warp(t0 + 2 * SEASON + 1 hours + 1);
        seasons.closeSeason(new uint256[](0)); // season 0: nobody qualified, its bonus is burned
        assertEq(seasons.bonusBurned(), 5_000_000e18);
        uint256 before = plea.balanceOf(a);
        seasons.closeSeason(new uint256[](0)); // season 1: a has 81 points
        assertEq(plea.balanceOf(a) - before, 1_250_000e18);
        assertEq(seasons.bonusBurned(), 5_000_000e18 + 3_750_000e18);
        assertEq(plea.balanceOf(address(seasons)), 20_000_000e18);

        // the winner sells most of the prize through a plea, after the 4-hour cooldown
        _warp(_now() + 4 hours);
        uint256 sellAmount = 1_200_000e18;
        assertLe(sellAmount, plea.balanceOf(a) * 35 / 100);
        vm.prank(a);
        uint256 id3 = gate.submitSell(sellAmount, "I won this season and I am taking part of my prize home.");
        answer(gate.getPlea(id3).intakeId, 45);
        uint256 balBefore = plea.balanceOf(a);
        uint256 imdBefore = IMD.balanceOf(a);
        vm.prank(a);
        uint256 out = gate.executeSell(0);
        assertEq(balBefore - plea.balanceOf(a), sellAmount, "exactly the approved amount left the wallet");
        assertEq(IMD.balanceOf(a) - imdBefore, out);
        assertGt(out, 0);
    }

    // ---------------------------------------------------------------- selling

    /// IMD a sale of `amount` PLEA is worth at the current pool price, before fees and impact.
    function _spotValue(uint256 amount) internal view returns (uint256) {
        uint256 sp = hook.currentSqrtPriceX96();
        return hook.pleaIsZero()
            ? FullMath.mulDiv(FullMath.mulDiv(amount, sp, 1 << 96), sp, 1 << 96)
            : FullMath.mulDiv(FullMath.mulDiv(amount, 1 << 96, sp), 1 << 96, sp);
    }

    function test_noWayToSellOrMovePleaWhileTheCabalWatches() public {
        address a = w[0];
        buy(a, 200e18);
        uint256 bal = plea.balanceOf(a);
        _swap(a, false, bal / 5, abi.encode(a), true); // router sell: SellsOnlyViaGate
        _swap(a, false, bal / 5, "", true); // without a recipient too
        vm.startPrank(a);
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(w[1], 1); // no wallet-to-wallet transfers
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(POOL_MANAGER, 1); // no direct sends to the PoolManager
        vm.expectRevert(PLEA.CabalIsWatching.selector);
        plea.transfer(address(gate), 1); // nor to the gate
        vm.stopPrank();
        assertEq(plea.balanceOf(a), bal);
    }

    function test_approvedSellIsExactAndFairlyPriced() public {
        address a = w[0];
        buy(a, 300e18);
        (uint256 id, bytes32 rid) = plead(a);
        answer(rid, 45);
        uint256 amount = gate.getPlea(id).amount;
        uint256 spot = _spotValue(amount);
        uint256 burned = hook.totalBurned();
        uint256 balBefore = plea.balanceOf(a);
        uint256 imdBefore = IMD.balanceOf(a);
        vm.prank(a);
        vm.expectEmit(true, true, false, false, address(gate));
        emit CabalGate.SellExecuted(id, a, amount, 0);
        uint256 out = gate.executeSell(0);
        assertEq(balBefore - plea.balanceOf(a), amount);
        assertEq(IMD.balanceOf(a) - imdBefore, out);
        assertGt(hook.totalBurned(), burned, "the 0.25% PLEA burn was taken");
        console2.log("sell: PLEA in", amount);
        console2.log("sell: IMD at spot", spot);
        console2.log("sell: IMD out", out);
        assertLt(out, spot * 9825 / 10_000, "fees (1.75%) were charged");
        assertGt(out, spot * 95 / 100, "fees plus impact stay small for a 5% sale");
        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Executed));
        assertEq(plea.balanceOf(address(gate)), 0);
        assertEq(IMD.balanceOf(address(gate)), 0);
    }

    function test_sellSlippageGuardKeepsTheApproval() public {
        address a = w[0];
        buy(a, 300e18);
        (uint256 id, bytes32 rid) = plead(a);
        answer(rid, 45);
        uint256 bal = plea.balanceOf(a);
        vm.prank(a);
        vm.expectRevert(); // SlippageExceeded
        gate.executeSell(type(uint128).max);
        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Approved));
        assertEq(plea.balanceOf(a), bal);
        vm.prank(a);
        gate.executeSell(1);
        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Executed));
    }

    function test_onlyTheSellerCanExecuteAndOnlyWithinSevenMinutes() public {
        address a = w[0];
        buy(a, 300e18);
        buy(w[1], 300e18);
        (uint256 id, bytes32 rid) = plead(a);
        answer(rid, 45);
        vm.prank(w[1]);
        vm.expectRevert(CabalGate.NotApproved.selector);
        gate.executeSell(0);
        _warp(gate.getPlea(id).verdictAt + 7 minutes + 1);
        vm.prank(a);
        vm.expectRevert(CabalGate.WindowLapsed.selector);
        gate.executeSell(0);
        // the lapse starts the 4-hour cooldown
        uint256 amt = _amount(a);
        uint256 until = gate.getPlea(id).verdictAt + 4 hours;
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(CabalGate.Cooldown.selector, until));
        gate.submitSell(amt, "One more try.");
    }

    function test_freeSellAfterDeathIsExactAndFairlyPriced() public {
        address a = w[0];
        buy(a, 300e18);
        _warp(gate.lastVerdictAt() + DEADMAN + 1);
        assertFalse(gate.cabalAlive());
        uint256 amount = plea.balanceOf(a) / 2;
        uint256 spot = _spotValue(amount);
        uint256 imdBefore = IMD.balanceOf(a);
        uint256 balBefore = plea.balanceOf(a);
        _swap(a, false, amount, ""); // no recipient needed to sell once the Cabal is dead
        uint256 out = IMD.balanceOf(a) - imdBefore;
        assertEq(balBefore - plea.balanceOf(a), amount);
        console2.log("free sell: IMD at spot", spot);
        console2.log("free sell: IMD out", out);
        assertLt(out, spot * 9825 / 10_000);
        assertGt(out, spot * 90 / 100);
        // and wallets can move PLEA freely
        vm.prank(a);
        plea.transfer(w[1], 1e18);
    }

    // ---------------------------------------------------------------- gas benchmark

    /// @dev 280 bytes (the maximum), with quotes and a backslash so the JSON escaping works too.
    function _longText(string memory head) internal pure returns (string memory s) {
        s = string.concat(head, ' I wrote "please" twice\\ and meant it. ');
        while (bytes(s).length < 280) s = string.concat(s, "x");
        assembly {
            mstore(s, 280)
        }
    }

    /// The gas of each user flow on Ethereum's schedule, against the live Sepolia contracts, with
    /// the longest allowed texts: a reference for the mainnet gas pass.
    function test_gasBenchmark() public {
        address a = w[0];
        address b = w[1];
        uint256 g = gasleft();
        buy(a, 200e18);
        emit log_named_uint("gas: buy (first)", g - gasleft());
        buy(b, 200e18);
        _warp(_now() + 1 days);

        // The site: plea, answer, sale, points.
        uint256 amount = _amount(a);
        string memory t = _longText("Site plea:");
        vm.prank(a);
        g = gasleft();
        uint256 id = gate.submitSell(amount, t);
        emit log_named_uint("gas: site plea (280 B)", g - gasleft());
        g = gasleft();
        answer(gate.getPlea(id).intakeId, 45);
        emit log_named_uint("gas: verdict delivery", g - gasleft());
        vm.prank(a);
        g = gasleft();
        gate.executeSell(0);
        emit log_named_uint("gas: site sale", g - gasleft());
        g = gasleft();
        seasons.record(id);
        emit log_named_uint("gas: record", g - gasleft());

        // Letters: plea, runner's delivery; denial, appeal letter.
        (uint256 l, uint256 gasLetter) = _letter(b, bytes(_longText("Letter:")));
        emit log_named_uint("gas: letter (280 B)", gasLetter);
        answer(gate.getPlea(l).intakeId, 45);
        vm.prank(makeAddr("runner"));
        g = gasleft();
        letterbox.deliver(l);
        emit log_named_uint("gas: deliver", g - gasleft());
        _warp(_now() + 4 hours + 1);
        (uint256 l2,) = _letter(b, bytes(_longText("Second letter:")));
        answer(gate.getPlea(l2).intakeId, 0);
        (, uint256 gasAppeal) = _letter(b, bytes(string.concat("APPEAL ", _longText("Appeal:"))));
        emit log_named_uint("gas: appeal letter (280 B)", gasAppeal);
    }

    // ---------------------------------------------------------------- letters

    function _letter(address who, bytes memory text) internal returns (uint256 id, uint256 gasUsed) {
        uint256 g = gasleft();
        vm.prank(who);
        (bool ok, bytes memory ret) = address(letterbox).call(text);
        gasUsed = g - gasleft();
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        id = gate.lastPleaOf(who);
    }

    /// A letter sent as raw calldata pleads through the live Intake v2 (the Letterbox mints the
    /// Sepolia oracle fee and buys the tip with the writer's PLEA); a stranger delivers the
    /// approval for the tip; the writer gets the IMD and the points.
    function test_letterThroughTheLiveIntakeIsDeliveredByARunner() public {
        address a = w[1];
        buy(a, 50e18);
        _warp(_now() + 1 days);
        uint256 bal = plea.balanceOf(a);
        uint256 paidBefore = IERC20(ORACLE_IMD).balanceOf(INTAKE);
        (uint256 id, uint256 gasLetter) =
            _letter(a, "I bought at the launch and held a day; one tenth pays for my bike repair, the rest stays.");
        emit log_named_uint("letter gas", gasLetter);
        CabalGate.Plea memory p = gate.getPlea(id);
        assertEq(p.amount, bal / 5 > 2_500_000e18 ? 2_500_000e18 : bal / 5, "20%, within the 2.5M cap");
        assertEq(p.flags, 3);
        (address payer,,, bool done) = intake.requests(p.intakeId);
        assertEq(payer, address(gate));
        assertFalse(done);
        assertGe(IERC20(ORACLE_IMD).balanceOf(INTAKE) + 1, paidBefore, "the Intake was paid");
        assertEq(IMD.balanceOf(address(letterbox)), 0.25e18, "tip held");
        answer(p.intakeId, 40);
        address runner = makeAddr("runner");
        uint256 imdBefore = IMD.balanceOf(a);
        uint256 g = gasleft();
        vm.prank(runner);
        uint256 out = letterbox.deliver(id);
        emit log_named_uint("deliver gas", g - gasleft());
        assertEq(IMD.balanceOf(a) - imdBefore, out);
        assertGe((out + 0.35e18) * 10_000, _spotValue(p.amount) * 9_500, "at least 95% of spot before the fee");
        assertEq(IMD.balanceOf(runner), 0.25e18);
        assertTrue(seasons.recorded(id));
        assertEq(plea.balanceOf(address(letterbox)), 0);
        assertEq(IMD.balanceOf(address(letterbox)), 0);
    }

    /// The same letter typed into `letter(text)` on a block explorer pleads through the live Intake
    /// v2; the writer's own `SELL`, typed the same way, sells it and returns the tip.
    function test_explorerLetterThroughTheLiveIntake() public {
        address a = w[3];
        buy(a, 50e18);
        _warp(_now() + 1 days);
        uint256 bal = plea.balanceOf(a);
        uint256 g = gasleft();
        vm.prank(a);
        letterbox.letter("Typed on Etherscan: one tenth pays my phone bill, the other nine tenths stay with me.");
        emit log_named_uint("explorer letter gas", g - gasleft());
        uint256 id = gate.lastPleaOf(a);
        CabalGate.Plea memory p = gate.getPlea(id);
        assertEq(p.seller, a);
        assertEq(p.amount, bal / 5 > 2_500_000e18 ? 2_500_000e18 : bal / 5, "20%, within the 2.5M cap");
        assertEq(p.flags, 3);
        (address payer,,, bool done) = intake.requests(p.intakeId);
        assertEq(payer, address(gate));
        assertFalse(done);
        answer(p.intakeId, 40);
        uint256 imdBefore = IMD.balanceOf(a);
        vm.prank(a);
        letterbox.letter("SELL");
        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Executed));
        assertGe((IMD.balanceOf(a) - imdBefore - 0.25e18 + 0.35e18) * 10_000, _spotValue(p.amount) * 9_500, "sale + own tip");
        assertTrue(seasons.recorded(id));
        assertEq(IMD.balanceOf(address(letterbox)), 0);
    }

    /// Denied by letter, appealed by letter (the wall share bought with PLEA), the appeal gets no
    /// verdict through the live Intake: settle gives the writer back the escrow and the tip.
    function test_letterDenialAppealAndNoVerdictSettle() public {
        address a = w[2];
        buy(a, 50e18);
        _warp(_now() + 1 days);
        (uint256 id,) = _letter(a, "One tenth to pay back a friend; nine tenths stay with me through the season.");
        answer(gate.getPlea(id).intakeId, 0);
        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Denied));
        uint256 wall = hook.retainedImd();
        (uint256 ap, uint256 gasAppeal) =
            _letter(a, "APPEAL My friend lent me rent money in July; this tenth repays her, the rest stays.");
        emit log_named_uint("appeal letter gas", gasAppeal);
        assertEq(gate.getPlea(ap).originalId, id);
        assertEq(hook.retainedImd() - wall, 0.35e18);
        (, bool openOld,,) = letterbox.escrowOf(id);
        assertFalse(openOld, "the denied plea's escrow went back first");
        uint256 pleaBefore = plea.balanceOf(a);
        uint256 imdBefore = IMD.balanceOf(a);
        (,, uint256 amount,) = letterbox.escrowOf(ap);
        fail(gate.getPlea(ap).intakeId, 2, bytes32("disagreed"), 12, 28);
        assertEq(uint8(_status(ap)), uint8(CabalGate.Status.Expired));
        letterbox.settle(ap);
        assertEq(plea.balanceOf(a) - pleaBefore, amount);
        assertEq(IMD.balanceOf(a) - imdBefore, 0.25e18);
        assertTrue(vm.contains(letterbox.status(a), "NO VERDICT"), letterbox.status(a));
    }
}
