// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PLEA} from "../src/PLEA.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Seasons} from "../src/Seasons.sol";
import {PleaDistributor} from "../src/PleaDistributor.sol";
import {Letterbox} from "../src/Letterbox.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";
import {PleaHook} from "../src/PleaHook.sol";

/// @dev Test-only equivalent of the factory's zero-value, ordered CREATE2 deployment.
contract ManifestFactory {
    function deploy(bytes memory code, bytes32 salt) public returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
            if iszero(deployed) {
                let ptr := mload(0x40)
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
        }
    }

    function deployAll(bytes[5] memory codes) external returns (address[5] memory deployed) {
        for (uint256 i; i < 5; ++i) {
            deployed[i] = deploy(codes[i], bytes32(i));
        }
    }
}

abstract contract ManifestFixture is Test {
    // Exact static constructor values from the supplied launch.json (Sepolia test run 3). Only
    // $owner and earlier contract references are resolved locally; no external contract is
    // installed or called.
    address constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address constant ORACLE_ASSET = 0x44a1Cd38474FB1748400E7DEb5F8D786ccE3F89A;
    address constant IMD = 0x2B69099E59b05901faA1DD164fabf098bf831E82;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    address constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address constant STACKER = 0x0457276D7b036818B3EddC1A4A3FCeda61e9314d;
    uint256 constant START = 1792162800;
    uint256 constant SEASON = 18_000;
    uint256 constant CREDIT_GAS = 1_300_000;
    bool constant MINT_ORACLE_FEE = true;
    /// @dev Ethereum's per-transaction gas cap (EIP-7825), and the headroom IMD's deployer adds to
    /// a launch's gas limit (limit / used was 1.175-1.214 on its last four launches).
    uint256 constant TX_GAS_CAP = 16_777_216;
    uint256 constant IMD_GAS_HEADROOM_BPS = 12_200;
    /// @dev What IMD's real ProjectFactory adds to the five CREATE2s below (decoding and copying
    /// the codes, names and metadata, the registry record). Measured by sending these five codes
    /// through the mainnet ProjectFactory 0xfF03...7120 on a fork (2026-10-12): 12,575,870 gas
    /// against 11,581,323 here, so 994,547; eth_estimateGas on mainnet asked for 11,513,828.
    uint256 constant IMD_FACTORY_OVERHEAD = 1_100_000;

    ManifestFactory factory;
    address owner;
    bytes[5] codes;
    address[5] expected;
    bytes32 letterboxHash;

    function setUp() public virtual {
        vm.chainId(11155111);
        vm.roll(1000);
        vm.warp(START - 1 days);
        owner = makeAddr("manifest owner");
        factory = new ManifestFactory();
        letterboxHash = keccak256(vm.getCode("Letterbox.sol:Letterbox"));
        _prepare(0, "PLEA.sol:PLEA", abi.encode(owner));
        _prepare(
            1,
            "CabalGate.sol:CabalGate",
            abi.encode(expected[0], INTAKE, ORACLE_ASSET, IMD, SIGNER, SEASON, uint256(118800))
        );
        _prepare(2, "Seasons.sol:Seasons", abi.encode(expected[0], expected[1], IMD));
        _prepare(3, "PleaDistributor.sol:PleaDistributor", abi.encode(expected[0], owner));
        _prepare(
            4,
            "PleaLaunch.sol:PleaLaunch",
            abi.encode(
                expected[0],
                expected[1],
                expected[2],
                expected[3],
                POOL_MANAGER,
                IMD,
                STACKER,
                CREDIT_GAS,
                START,
                ORACLE_ASSET,
                MINT_ORACLE_FEE,
                letterboxHash
            )
        );
    }

    function _prepare(uint256 i, string memory artifact, bytes memory args) internal {
        codes[i] = bytes.concat(vm.getCode(artifact), args);
        expected[i] = address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), address(factory), bytes32(i), keccak256(codes[i]))))
            )
        );
        assertLe(codes[i].length, 49_152, "EIP-3860 init code limit");
    }

    function _assertWiring() internal view {
        PLEA p = PLEA(expected[0]);
        CabalGate g = CabalGate(expected[1]);
        Seasons s = Seasons(expected[2]);
        PleaLaunch l = PleaLaunch(expected[4]);
        assertEq(p.owner(), owner);
        assertEq(p.launcher(), expected[4]);
        assertEq(p.letterbox(), address(0), "the Letterbox is deployed after the launch");
        assertEq(p.gate(), expected[1]);
        assertEq(p.seasons(), expected[2]);
        assertEq(p.distributor(), expected[3]);
        assertEq(address(g.plea()), expected[0]);
        assertEq(address(g.intake()), INTAKE);
        assertEq(address(g.oracleAsset()), ORACLE_ASSET);
        assertEq(address(g.imd()), IMD);
        assertEq(g.oracleSigner(), SIGNER);
        assertEq(g.SEASON(), SEASON);
        assertEq(g.DEADMAN(), 118800);
        assertEq(g.PANEL_SIZE(), 30);
        assertEq(g.QUORUM(), 17);
        assertEq(address(s.plea()), expected[0]);
        assertEq(address(s.gate()), expected[1]);
        assertEq(address(s.imd()), IMD);
        assertEq(s.SEASON(), SEASON);
        assertEq(address(PleaDistributor(expected[3]).plea()), expected[0]);
        assertEq(PleaDistributor(expected[3]).owner(), owner);
        assertEq(l.plea(), expected[0]);
        assertEq(l.gate(), expected[1]);
        assertEq(l.seasons(), expected[2]);
        assertEq(l.owner(), owner);
        assertEq(l.poolManager(), POOL_MANAGER);
        assertEq(l.imd(), IMD);
        assertEq(l.START(), START);
        assertEq(l.oracleAsset(), ORACLE_ASSET);
        assertEq(l.mintOracleFee(), MINT_ORACLE_FEE);
        assertEq(l.letterboxCodeHash(), keccak256(type(Letterbox).creationCode));
        assertEq(l.hookInitCodeHash(), keccak256(_hookCode()));
        assertEq(p.totalSupply(), 0, "hook deployment must remain a separate step");
        assertEq(p.hook(), address(0));
        assertEq(g.startedAt(), 0);
        assertTrue(p.restricted());
        assertFalse(l.opened());
    }

    function _hookCode() internal view returns (bytes memory) {
        return bytes.concat(
            vm.getCode("PleaHook.sol:PleaHook"),
            abi.encode(POOL_MANAGER, expected[0], IMD, STACKER, owner, expected[2], CREDIT_GAS)
        );
    }

    /// @dev EIP-2028 gas of the factory call's data (16 per non-zero byte, 4 per zero byte).
    function _txDataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }
}

contract AtomicManifestTest is ManifestFixture {
    /// The five-contract launch in one factory transaction, measured as the chain charges it: the
    /// init codes come in as transaction data (EIP-2028) and execute from memory, plus the real
    /// factory's measured overhead. It must fit under Ethereum's 16,777,216-gas cap even with the
    /// headroom IMD's deployer adds to the gas limit.
    function test_factoryDeploysExactManifestOnAnEmptySepoliaChain() public {
        assertEq(
            INTAKE.code.length + ORACLE_ASSET.code.length + IMD.code.length + POOL_MANAGER.code.length
                + STACKER.code.length,
            0
        );
        bytes[5] memory m = codes;
        uint256 dataGas = _txDataGas(abi.encodeCall(ManifestFactory.deployAll, (m)));
        uint256 before = gasleft();
        address[5] memory deployed = factory.deployAll(m);
        uint256 txGas = 21_000 + dataGas + (before - gasleft()) + IMD_FACTORY_OVERHEAD;
        uint256 limit = txGas * IMD_GAS_HEADROOM_BPS / 10_000;
        emit log_named_uint("five-contract launch transaction gas through IMD's factory", txGas);
        emit log_named_uint("gas limit with IMD's headroom", limit);
        emit log_named_int("margin to the 16,777,216 cap", int256(TX_GAS_CAP) - int256(limit));
        assertLt(limit, TX_GAS_CAP, "the launch must fit one mainnet transaction");
        for (uint256 i; i < 5; ++i) {
            assertEq(deployed[i], expected[i]);
            bytes memory runtime = deployed[i].code;
            assertGt(runtime.length, 0);
            assertLe(runtime.length, 24_576);
            // The supplied protected floor's scanner: skip PUSH data, scan every runtime opcode.
            for (uint256 j; j < runtime.length; ++j) {
                uint8 op = uint8(runtime[j]);
                if (op >= 0x60 && op <= 0x7f) {
                    j += op - 0x5f;
                    continue;
                }
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
            }
        }
        _assertWiring();
    }

    /// The launch recipe encodes bools as decimal/hex static words, never JSON words.
    function test_launchJsonEncodesOracleMintFlagAsStaticWord() public view {
        string memory json = vm.readFile("launch.json");
        string memory flag = vm.parseJsonString(json, ".contracts[4].constructorArgs[10]");
        assertEq(flag, "1", "the Sepolia mint flag must be the static bool word 1");
        assertEq(abi.encode(vm.parseUint(flag)), abi.encode(MINT_ORACLE_FEE));
    }

    /// launch.json commits to this build's Letterbox: its code hash argument must match.
    function test_launchJsonCommitsToThisLetterbox() public view {
        string memory json = vm.readFile("launch.json");
        assertEq(vm.parseJsonString(json, ".contracts[4].contract"), "PleaLaunch");
        bytes32 committed = vm.parseBytes32(vm.parseJsonString(json, ".contracts[4].constructorArgs[11]"));
        assertEq(committed, keccak256(type(Letterbox).creationCode), "update launch.json after changing Letterbox");
        assertEq(committed, letterboxHash);
    }
}

contract RehearsalManifestTest is ManifestFixture {
    function setUp() public override {
        super.setUp();
        factory.deploy(codes[0], bytes32(0));
        // Foundry ends this call before running a test, clearing PLEA's transient deployment flag.
    }

    function test_separateConstructorCallsInDeploymentBlockStillWork() public {
        for (uint256 i = 1; i < 5; ++i) {
            factory.deploy(codes[i], bytes32(i));
        }
        _assertWiring();
    }

    function test_laterBlockCannotRegisterLauncher() public {
        vm.roll(vm.getBlockNumber() + 1);
        for (uint256 i = 1; i < 4; ++i) {
            factory.deploy(codes[i], bytes32(i));
        }
        vm.expectRevert(PLEA.NotDeployTx.selector);
        factory.deploy(codes[4], bytes32(uint256(4)));
    }

    /// @dev Reproduces the accepted informational finding; real launch must use deployAll atomically.
    function test_separateTransactionsLeaveTheAcceptedDeploymentBlockWindow() public {
        address attacker = makeAddr("deployment-block attacker");
        vm.prank(attacker);
        PLEA(expected[0]).setLauncher(expected[1], expected[2], expected[3]);
        assertEq(PLEA(expected[0]).launcher(), attacker);
        for (uint256 i = 1; i < 4; ++i) {
            factory.deploy(codes[i], bytes32(i));
        }
        vm.expectRevert(PLEA.AlreadySet.selector);
        factory.deploy(codes[4], bytes32(uint256(4)));
    }
}

contract PostLaunchTest is ManifestFixture {
    function setUp() public override {
        super.setUp();
        factory.deployAll(codes);
    }

    /// After the launch: anyone deploys the committed Letterbox (its own transaction, well under
    /// the cap); it reads its settings from PleaLaunch, and PLEA registers it once.
    function test_committedLetterboxDeploysLater() public {
        vm.roll(vm.getBlockNumber() + 1);
        PleaLaunch l = PleaLaunch(expected[4]);
        bytes memory code = vm.getCode("Letterbox.sol:Letterbox");
        vm.expectRevert(PleaLaunch.WrongInitCode.selector);
        l.deployLetterbox(bytes.concat(code, hex"00"));
        uint256 dataGas = _txDataGas(abi.encodeCall(PleaLaunch.deployLetterbox, (code)));
        vm.prank(makeAddr("anyone"));
        uint256 before = gasleft();
        address lb = l.deployLetterbox(code);
        uint256 txGas = 21_000 + dataGas + (before - gasleft());
        emit log_named_uint("deployLetterbox transaction gas", txGas);
        assertLt(txGas * IMD_GAS_HEADROOM_BPS / 10_000, TX_GAS_CAP);
        assertEq(lb, l.predictLetterbox());
        assertEq(PLEA(expected[0]).letterbox(), lb);
        assertEq(Letterbox(payable(lb)).nameOf(owner), "");
        vm.expectRevert(PleaLaunch.LetterboxAlreadyDeployed.selector);
        l.deployLetterbox(code);
    }

    function test_committedHookDeploysLaterAndMintsOnlyTheFixedSplit() public {
        _assertWiring();
        vm.roll(vm.getBlockNumber() + 1);
        PleaLaunch l = PleaLaunch(expected[4]);
        bytes memory code = _hookCode();
        bytes32 hash = keccak256(code);
        uint160 flags = l.FLAGS();
        uint256 salt;
        while (
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(l), bytes32(salt), hash)))) & 0x3fff
                != flags
        ) ++salt;
        address h = l.deployHook(bytes32(salt), code);
        PLEA p = PLEA(expected[0]);
        assertEq(p.hook(), h);
        assertEq(p.poolManager(), POOL_MANAGER);
        assertEq(p.totalSupply(), 1_000_000_000e18);
        assertEq(p.balanceOf(h), 870_000_000e18);
        assertEq(p.balanceOf(expected[2]), 30_000_000e18);
        assertEq(p.balanceOf(expected[3]), 100_000_000e18);
        assertEq(PleaHook(h).owner(), owner);
        assertEq(address(PleaHook(h).stacker()), STACKER);
        assertEq(PleaHook(h).seasons(), expected[2]);
        assertEq(PleaHook(h).creditGas(), CREDIT_GAS);
        assertFalse(PleaHook(h).seeded());
        vm.expectRevert(PleaLaunch.HookAlreadyDeployed.selector);
        l.deployHook(bytes32(salt), code);
    }
}
