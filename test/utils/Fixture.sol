// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {PLEA} from "../../src/PLEA.sol";
import {CabalGate} from "../../src/CabalGate.sol";
import {Seasons} from "../../src/Seasons.sol";
import {PleaDistributor} from "../../src/PleaDistributor.sol";
import {Letterbox} from "../../src/Letterbox.sol";
import {PleaLaunch} from "../../src/PleaLaunch.sol";
import {PleaHook} from "../../src/PleaHook.sol";
import {MockIMD, MockSIMD, MockStacker, BuyRouter, MockIntake} from "./Mocks.sol";

/// @dev Replays the launch (PLEA, CabalGate, Seasons, PleaDistributor, PleaLaunch in one call
/// context), deploys the Letterbox through PleaLaunch, mines the hook salt, deploys the hook and
/// opens trading.
contract Fixture is Test {
    address constant OWNER = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821;
    /// @dev anvil's second account, used as the test oracle signer.
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant CREDIT_GAS = 300_000;
    uint256 constant T0 = 1_800_000_000;

    uint256 SEASON = 15 days;
    uint256 DEADMAN = 33 hours;

    PoolManager pm;
    MockIMD imd;
    MockIMD oimd;
    MockSIMD simd;
    MockStacker stacker;
    MockIntake intake;
    PLEA plea;
    CabalGate gate;
    Seasons seasons;
    PleaDistributor distributor;
    Letterbox letterbox;
    PleaLaunch launch;
    PleaHook hook;
    BuyRouter router;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address keeper = makeAddr("keeper");
    address[] users;

    function setTimings() internal virtual {}

    /// @dev Sepolia: a separate oracle fee token (the Letterbox mints the fee). Mainnet path: return
    /// the pool IMD, so the Letterbox buys the oracle fee with PLEA like the tip.
    function oracleFeeToken() internal view virtual returns (MockIMD) {
        return oimd;
    }

    function creditGasBudget() internal pure virtual returns (uint256) {
        return CREDIT_GAS;
    }

    /// @dev Default: past the 90-minute launch window (no extra fee, no buy cap).
    function afterSeed() internal virtual {
        skip(91 minutes);
    }

    function setUp() public virtual {
        vm.chainId(11155111);
        vm.warp(T0);
        vm.roll(1000);
        setTimings();
        pm = new PoolManager(address(this));
        deployImd();
        oimd = new MockIMD();
        simd = new MockSIMD();
        stacker = new MockStacker(imd, simd);
        intake = new MockIntake(oracleFeeToken());
        deployLaunch();
        deployHook();
        vm.prank(OWNER);
        launch.seed();
        afterSeed();
        router = new BuyRouter(IPoolManager(address(pm)), hook, imd, plea);
        users.push(alice);
        users.push(bob);
        users.push(carol);
        for (uint256 i; i < users.length; ++i) {
            fund(users[i]);
        }
    }

    function fund(address who) internal {
        imd.mint(who, 100_000e18);
        oimd.mint(who, 1_000e18);
        vm.startPrank(who);
        imd.approve(address(router), type(uint256).max);
        imd.approve(address(gate), type(uint256).max);
        imd.approve(address(seasons), type(uint256).max);
        oimd.approve(address(gate), type(uint256).max);
        plea.approve(address(gate), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Default: IMD sorts below PLEA (IMD is currency0). Orientation tests override this.
    function deployImd() internal virtual {
        imd = new MockIMD();
    }

    function deployLaunch() internal {
        plea = new PLEA(OWNER);
        gate = new CabalGate(
            address(plea), address(intake), address(oracleFeeToken()), address(imd), SIGNER, SEASON, DEADMAN
        );
        seasons = new Seasons(address(plea), address(gate), address(imd));
        distributor = new PleaDistributor(address(plea), OWNER);
        MockIMD feeToken = oracleFeeToken();
        launch = new PleaLaunch(
            address(plea),
            address(gate),
            address(seasons),
            address(distributor),
            address(pm),
            address(imd),
            address(stacker),
            creditGasBudget(),
            T0 + 1 days,
            address(feeToken),
            feeToken != imd,
            keccak256(type(Letterbox).creationCode)
        );
        // After the launch: anyone deploys the committed Letterbox.
        letterbox = Letterbox(launch.deployLetterbox(type(Letterbox).creationCode));
    }

    function hookInitCode() internal view returns (bytes memory) {
        return abi.encodePacked(
            type(PleaHook).creationCode,
            abi.encode(
                address(pm), address(plea), address(imd), address(stacker), OWNER, address(seasons), creditGasBudget()
            )
        );
    }

    function mineSalt(bytes32 initHash) internal view returns (bytes32 salt) {
        uint160 flags = launch.FLAGS();
        for (uint256 s;; ++s) {
            address a = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(launch), bytes32(s), initHash))))
            );
            if (uint160(a) & 0x3fff == flags) return bytes32(s);
        }
    }

    function deployHook() internal {
        bytes memory code = hookInitCode();
        bytes32 salt = mineSalt(keccak256(code));
        hook = PleaHook(launch.deployHook(salt, code));
    }

    // ---------------------------------------------------------------- actions

    function buy(address who, uint256 imdIn) internal returns (uint256 out) {
        vm.prank(who);
        out = router.buyExactIn(imdIn, abi.encode(who));
    }

    function plead(address who, uint256 amount) internal returns (uint256 id) {
        return plead(who, amount, "I have held through every candle and need to pay rent; I keep the rest.");
    }

    function plead(address who, uint256 amount, string memory text) internal returns (uint256 id) {
        vm.prank(who);
        id = gate.submitSell(amount, text);
    }

    /// @dev A valid small plea: 2% of the balance (the gate's minimum is 1%), at most 2.5M PLEA.
    function small(address who) internal view returns (uint256 amount) {
        amount = plea.balanceOf(who) / 50;
        if (amount > 2_500_000e18) amount = 2_500_000e18;
    }

    function intakeIdOf(uint256 id) internal view returns (bytes32) {
        return gate.getPlea(id).intakeId;
    }

    function attestation(uint256 score, bytes32 requestId)
        internal
        view
        returns (OracleAttestation.Attestation memory a)
    {
        a = OracleAttestation.Attestation({
            requestId: requestId,
            chainId: 1,
            questionHash: keccak256("question"),
            answerType: OracleAttestation.ANSWER_UINT256,
            answer: abi.encode(score),
            figure: score,
            fromBlock: 26_000_000,
            toBlock: 26_000_300,
            blockHash: keccak256("block"),
            panelJobId: keccak256(abi.encode("job", requestId)),
            panelSize: 30,
            quorum: 17,
            agreed: 20,
            issuedAt: uint64(vm.getBlockTimestamp()),
            expiresAt: uint64(vm.getBlockTimestamp() + 3600)
        });
    }

    function sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, gate.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The Intake's writer completes the request with a signed score (status 0).
    function answer(uint256 id, uint256 score) internal returns (bool) {
        return deliver(intakeIdOf(id), attestation(score, keccak256(abi.encode("oracle", id))));
    }

    function deliver(bytes32 intakeId, OracleAttestation.Attestation memory a) internal returns (bool) {
        return intake.complete(intakeId, 0, abi.encode(intakeId, a, sign(a)));
    }

    /// @dev Buy, wait, plead 10% and get approved with `score`; returns the plea id.
    function approvedPlea(address who, uint256 score) internal returns (uint256 id) {
        uint256 bal = plea.balanceOf(who);
        id = plead(who, bal / 10);
        require(answer(id, score), "not delivered");
    }

    /// @dev Keeps the Cabal alive: a denied verdict resets the dead-man without points.
    function keepAlive(address who) internal {
        uint256 id = plead(who, plea.balanceOf(who) / 10);
        require(answer(id, 0), "not delivered");
    }
}
