// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PLEA} from "../../src/PLEA.sol";
import {CabalGate} from "../../src/CabalGate.sol";
import {Seasons} from "../../src/Seasons.sol";
import {PleaDistributor} from "../../src/PleaDistributor.sol";
import {Letterbox} from "../../src/Letterbox.sol";
import {PleaLaunch} from "../../src/PleaLaunch.sol";
import {PleaHook} from "../../src/PleaHook.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {BuyRouter} from "../utils/Mocks.sol";

/// @dev The live Intake v2 (same address and writer on Ethereum and Sepolia).
interface IIntakeV2Mainnet {
    function complete(bytes32 requestId, uint8 status, bytes32 resultHash, string calldata uri, bytes calldata args)
        external;

    function requests(bytes32 requestId)
        external
        view
        returns (address payer, address callbackTarget, bytes4 callbackSelector, bool completed);

    function priceOf(bytes32 action, address asset) external view returns (uint256);

    function payTo() external view returns (address);

    function callbackGas() external view returns (uint256);
}

/// @dev Stand-in for imd/acc's Stacker until it is deployed on mainnet: the same `credit` (pull the
/// IMD from the hook, deposit it into the real sIMD vault for the trader).
contract StackerStandIn {
    IERC20 public immutable imd;
    IERC4626 public immutable simd;
    bool internal approved;

    constructor(IERC20 imd_, IERC4626 simd_) {
        imd = imd_;
        simd = simd_;
    }

    function credit(address trader, uint256 amount) external returns (uint256 shares) {
        imd.transferFrom(msg.sender, address(this), amount);
        if (!approved) {
            imd.approve(address(simd), type(uint256).max);
            approved = true;
        }
        shares = simd.deposit(amount, trader);
    }
}

/// Mainnet rehearsal on an Ethereum fork: the seven launch contracts with chain-1 settings (IMD as
/// the oracle fee and the pool currency, 15-day seasons, credit gas 400k, the Letterbox buying the
/// oracle fee with PLEA), the hook mined and deployed on the real PoolManager, trading opened, and
/// every letter outcome driven through the real Intake v2, completed by impersonating its writer as
/// the oracle plane does, with mainnet's 200k callback gas. Only the oracle signer is a test key, and
/// imd/acc's Stacker (not deployed on mainnet yet) is a stand-in that deposits into the real sIMD.
///
/// MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com forge test --match-path test/fork/ForkMainnet.t.sol -vv
contract ForkMainnetTest is Test {
    IIntakeV2Mainnet constant INTAKE = IIntakeV2Mainnet(0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
    address constant WRITER = 0x3d3C0Df7C1a17d384545e9D7C8228897bD9625CB;
    IERC20 constant IMD = IERC20(0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
    IERC4626 constant SIMD = IERC4626(0x9Efa934D9fAd4AE28c998a40195646b965a97247);
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 constant ACTION = "oracle.request@oracle-1";
    uint256 constant SEASON = 15 days;
    uint256 constant DEADMAN = 118_800;
    uint256 constant CREDIT_GAS = 400_000;
    uint256 constant SIGNER_KEY = 0xA11CE;
    uint256 constant TIP = 0.25e18;

    PLEA plea;
    CabalGate gate;
    Seasons seasons;
    Letterbox letterbox;
    PleaLaunch launch;
    PleaHook hook;
    BuyRouter router;
    StackerStandIn stacker;
    address owner = makeAddr("owner");
    address runner = makeAddr("runner");
    address[] w;
    uint256 nonce;

    function setUp() public {
        string memory rpc = vm.envOr("MAINNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 1);
        stacker = new StackerStandIn(IMD, SIMD);
        _deploy();
        _deployHook();
        vm.prank(owner);
        launch.seed();
        router = new BuyRouter(IPoolManager(POOL_MANAGER), hook, IMD, IERC20(address(plea)));
        for (uint256 i; i < 3; ++i) {
            address a = makeAddr(string.concat("m", vm.toString(i)));
            w.push(a);
            deal(address(IMD), a, 10_000e18);
            vm.startPrank(a);
            IMD.approve(address(router), type(uint256).max);
            IMD.approve(address(gate), type(uint256).max);
            plea.approve(address(gate), type(uint256).max);
            vm.stopPrank();
        }
        _warp(block.timestamp + 91 minutes); // past the launch window
        for (uint256 i; i < 3; ++i) {
            _buy(w[i], 100e18);
        }
        _warp(block.timestamp + 1 days); // some holding time, so pleas can pass
    }

    function _deploy() internal {
        plea = new PLEA(owner);
        gate = new CabalGate(
            address(plea), address(INTAKE), address(IMD), address(IMD), vm.addr(SIGNER_KEY), SEASON, DEADMAN
        );
        seasons = new Seasons(address(plea), address(gate), address(IMD));
        PleaDistributor distributor = new PleaDistributor(address(plea), owner);
        launch = new PleaLaunch(
            address(plea),
            address(gate),
            address(seasons),
            address(distributor),
            POOL_MANAGER,
            address(IMD),
            address(stacker),
            CREDIT_GAS,
            block.timestamp + 7 days,
            address(IMD),
            false,
            keccak256(type(Letterbox).creationCode)
        );
        // After the launch transaction: anyone deploys the committed Letterbox.
        letterbox = Letterbox(launch.deployLetterbox(type(Letterbox).creationCode));
    }

    function _deployHook() internal {
        bytes memory code = abi.encodePacked(
            type(PleaHook).creationCode,
            abi.encode(POOL_MANAGER, address(plea), address(IMD), address(stacker), owner, address(seasons), CREDIT_GAS)
        );
        assertEq(keccak256(code), launch.hookInitCodeHash());
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
        vm.roll(block.number + 1);
    }

    function _buy(address who, uint256 imdIn) internal returns (uint256 out) {
        vm.prank(who);
        out = router.buyExactIn(imdIn, abi.encode(who));
    }

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

    function _attest(uint256 score) internal returns (OracleAttestation.Attestation memory a) {
        a = OracleAttestation.Attestation({
            requestId: keccak256(abi.encode("mainnet fork", ++nonce)),
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
            issuedAt: uint64(block.timestamp),
            expiresAt: uint64(block.timestamp + 3600)
        });
    }

    /// The plane's writer completes with an answer: the real Intake calls onOracleResult with
    /// mainnet's callback gas.
    function _answer(uint256 id, uint256 score) internal returns (uint256 gasUsed) {
        bytes32 rid = gate.getPlea(id).intakeId;
        OracleAttestation.Attestation memory a = _attest(score);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, gate.attestationDigest(a));
        uint256 g = gasleft();
        vm.prank(WRITER);
        INTAKE.complete(rid, 0, keccak256("attestation"), "uri", abi.encode(rid, a, abi.encodePacked(r, s, v)));
        gasUsed = g - gasleft();
    }

    function _fail(uint256 id) internal {
        bytes32 rid = gate.getPlea(id).intakeId;
        vm.prank(WRITER);
        INTAKE.complete(
            rid,
            2,
            bytes32(0),
            "uri",
            abi.encode(rid, uint8(2), bytes32("disagreed"), uint16(12), uint16(28), bytes(""))
        );
    }

    function _spotValue(uint256 amount) internal view returns (uint256) {
        uint256 sp = hook.currentSqrtPriceX96();
        return hook.pleaIsZero()
            ? FullMath.mulDiv(FullMath.mulDiv(amount, sp, 1 << 96), sp, 1 << 96)
            : FullMath.mulDiv(FullMath.mulDiv(amount, 1 << 96, sp), 1 << 96, sp);
    }

    /// @dev IMD held by the Intake and its fee recipient (wherever the Intake keeps a paid fee).
    function _intakeImd() internal view returns (uint256) {
        return IMD.balanceOf(address(INTAKE)) + IMD.balanceOf(INTAKE.payTo());
    }

    function _status(uint256 id) internal view returns (CabalGate.Status) {
        return gate.getPlea(id).status;
    }

    // ---------------------------------------------------------------- tests

    /// Chain-1 settings, and the real Intake sells a question for exactly the gate's oracle fee in IMD.
    function test_mainnetSettingsMatchTheRealIntake() public view {
        assertEq(address(gate.oracleAsset()), address(IMD));
        assertEq(INTAKE.priceOf(ACTION, address(IMD)), gate.ORACLE_FEE(), "the Intake's price in IMD");
        assertEq(INTAKE.callbackGas(), 200_000, "mainnet callback gas");
        assertEq(gate.SEASON(), SEASON);
        assertEq(hook.creditGas(), CREDIT_GAS);
        (uint256 feeImd,) = letterbox.feesFor(false);
        assertEq(feeImd, 0.5e18 + TIP, "a letter buys the oracle fee and the tip");
        (feeImd,) = letterbox.feesFor(true);
        assertEq(feeImd, 0.5e18 + 0.35e18 + TIP, "an appeal also buys the wall share");
        assertEq(plea.balanceOf(address(seasons)), 30_000_000e18);
        assertTrue(gate.cabalAlive());
    }

    /// A buy stacks the cashback into the real sIMD vault for the buyer, within the 400k credit gas.
    function test_buyStacksIntoTheRealSimd() public {
        address a = w[0];
        uint256 shares = SIMD.balanceOf(a);
        assertGt(shares, 0, "the setup buy already stacked sIMD");
        uint256 g = gasleft();
        _buy(a, 50e18);
        console2.log("gas: buy (repeat)", g - gasleft());
        assertGt(SIMD.balanceOf(a), shares);
        assertEq(IMD.allowance(address(hook), address(stacker)), 0, "exact approval per credit");
    }

    /// A raw letter on mainnet: the gate sells the writer's PLEA for exactly 0.75 IMD, pays the real
    /// Intake 0.5, keeps the tip; the answer arrives through the real Intake within 200k gas; a
    /// runner delivers for at least 95% of spot and earns the tip; the points are recorded.
    function test_letterBuysTheOracleFeeAndIsDelivered() public {
        address a = w[0];
        uint256 bal = plea.balanceOf(a);
        uint256 paid = _intakeImd();
        uint256 imdBefore = IMD.balanceOf(a);
        (uint256 id, uint256 gasLetter) =
            _letter(a, "I bought at the launch and held a day; one tenth pays for my bike repair, the rest stays.");
        console2.log("gas: letter", gasLetter);
        CabalGate.Plea memory p = gate.getPlea(id);
        assertEq(p.amount, bal / 5 > 2_500_000e18 ? 2_500_000e18 : bal / 5, "20%, within the 2.5M cap");
        assertEq(p.flags, 3);
        assertEq(_intakeImd() - paid, 0.5e18, "the real Intake was paid 0.5 IMD");
        assertEq(IMD.balanceOf(address(letterbox)), TIP, "the tip waits");
        assertGe(IMD.balanceOf(a), imdBefore, "the writer spent no IMD");
        (address payer,,, bool done) = INTAKE.requests(p.intakeId);
        assertEq(payer, address(gate));
        assertFalse(done);
        console2.log("gas: verdict delivery", _answer(id, 40));
        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Approved), "delivered within the 200k callback");
        imdBefore = IMD.balanceOf(a);
        uint256 g = gasleft();
        vm.prank(runner);
        uint256 out = letterbox.deliver(id);
        console2.log("gas: deliver", g - gasleft());
        assertEq(IMD.balanceOf(a) - imdBefore, out);
        assertGe((out + 0.35e18) * 10_000, _spotValue(p.amount) * 9_500, "at least 95% of spot before the fee");
        assertEq(IMD.balanceOf(runner), TIP);
        assertTrue(seasons.recorded(id));
        assertEq(plea.balanceOf(address(letterbox)), 0);
        assertEq(IMD.balanceOf(address(letterbox)), 0);
    }

    /// A letter typed into `letter(text)`, denied; an APPEAL letter buys the oracle fee, the wall
    /// share and the tip with PLEA; the panel gives no answer (failure through the real Intake);
    /// settle returns the escrow and the tip.
    function test_explorerLetterDeniedAppealedAndRefunded() public {
        address a = w[1];
        vm.prank(a);
        letterbox.letter("Typed on Etherscan: one tenth pays my phone bill, the other nine tenths stay with me.");
        uint256 id = gate.lastPleaOf(a);
        _answer(id, 0);
        assertEq(uint8(_status(id)), uint8(CabalGate.Status.Denied));
        uint256 wall = hook.retainedImd();
        uint256 paid = _intakeImd();
        uint256 g = gasleft();
        vm.prank(a);
        letterbox.letter("APPEAL The phone is how I work, and I keep the other nine tenths.");
        console2.log("gas: appeal letter", g - gasleft());
        uint256 ap = gate.lastPleaOf(a);
        assertEq(gate.getPlea(ap).originalId, id);
        assertEq(hook.retainedImd() - wall, 0.35e18, "the wall share");
        assertEq(_intakeImd() - paid, 0.5e18, "the real Intake was paid again");
        (, bool openOld,,) = letterbox.escrowOf(id);
        assertFalse(openOld, "the denied plea's escrow went back first");
        uint256 pleaBefore = plea.balanceOf(a);
        uint256 imdBefore = IMD.balanceOf(a);
        (,, uint256 amount,) = letterbox.escrowOf(ap);
        _fail(ap);
        assertEq(uint8(_status(ap)), uint8(CabalGate.Status.Expired), "cleared at once by the failure");
        vm.prank(runner);
        letterbox.settle(ap);
        assertEq(plea.balanceOf(a) - pleaBefore, amount);
        assertEq(IMD.balanceOf(a) - imdBefore, TIP);
        assertEq(IMD.balanceOf(runner), 0, "the caller gets nothing");
    }

    /// The site's manual flow on mainnet: the seller pays the 0.5 IMD oracle fee from the wallet,
    /// sells after the approval and records the points.
    function test_sitePleaPaysTheOracleFeeInImd() public {
        address a = w[2];
        uint256 amount = plea.balanceOf(a) / 20;
        uint256 imdBefore = IMD.balanceOf(a);
        vm.prank(a);
        uint256 g = gasleft();
        uint256 id =
            gate.submitSell(amount, "I am selling a little to pay rent and keeping the rest through every season.");
        console2.log("gas: site plea", g - gasleft());
        assertEq(imdBefore - IMD.balanceOf(a), 0.5e18, "the oracle fee, in IMD");
        _answer(id, 45);
        imdBefore = IMD.balanceOf(a);
        vm.prank(a);
        g = gasleft();
        gate.executeSell(0);
        console2.log("gas: site sale", g - gasleft());
        assertGt(IMD.balanceOf(a), imdBefore);
        seasons.record(id);
        (, uint256 season,) = seasons.currentSeason();
        assertEq(seasons.bestOf(season, a)[0], 45);
    }
}
