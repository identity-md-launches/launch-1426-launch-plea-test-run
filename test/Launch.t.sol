// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PLEA} from "../src/PLEA.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Seasons} from "../src/Seasons.sol";
import {PleaDistributor} from "../src/PleaDistributor.sol";
import {Letterbox} from "../src/Letterbox.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";
import {PleaHook} from "../src/PleaHook.sol";
import {MockIMD, MockIntake} from "./utils/Mocks.sol";

/// @dev The launch as IMD runs it: five constructors, then deployLetterbox, deployHook and seed.
contract LaunchTest is Test {
    address constant OWNER = 0x4b91078b2374c956A65F7Af0999CaE0a935E6821;
    address constant SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    uint256 constant START = 1_800_100_000;

    PoolManager pm;
    MockIMD imd;
    PLEA plea;
    Seasons seasons;
    CabalGate gate;
    PleaLaunch launch;
    address stacker = address(0x5747);

    function setUp() public {
        vm.chainId(11155111);
        vm.warp(1_800_000_000);
        pm = new PoolManager(address(this));
        imd = new MockIMD();
    }

    function deployAll(address poolManager) internal {
        MockIntake intake = new MockIntake(imd);
        plea = new PLEA(OWNER);
        gate = new CabalGate(address(plea), address(intake), address(imd), address(imd), SIGNER, 5 hours, 27.5 minutes);
        seasons = new Seasons(address(plea), address(gate), address(imd));
        PleaDistributor d = new PleaDistributor(address(plea), OWNER);
        launch = new PleaLaunch(
            address(plea),
            address(gate),
            address(seasons),
            address(d),
            poolManager,
            address(imd),
            stacker,
            1_300_000,
            START,
            address(imd),
            false,
            keccak256(type(Letterbox).creationCode)
        );
    }

    function initCode() internal view returns (bytes memory) {
        return abi.encodePacked(
            type(PleaHook).creationCode,
            abi.encode(address(pm), address(plea), address(imd), stacker, OWNER, address(seasons), uint256(1_300_000))
        );
    }

    function mine() internal view returns (bytes32 salt) {
        for (uint256 s;; ++s) {
            if (uint160(launch.predict(bytes32(s))) & 0x3fff == launch.FLAGS()) return bytes32(s);
        }
    }

    function test_launchWiresEverythingWithoutCallingOutside() public {
        // An empty chain: the PoolManager has no code; every constructor still succeeds.
        deployAll(address(0xdead));
        assertEq(plea.launcher(), address(launch));
        assertEq(plea.gate(), address(gate));
        assertEq(plea.seasons(), address(seasons));
        assertTrue(plea.restricted());
        assertEq(gate.startedAt(), 0);
        assertEq(plea.letterbox(), address(0), "the Letterbox comes after the launch");
        assertEq(launch.letterboxCodeHash(), keccak256(type(Letterbox).creationCode));
    }

    function test_deployHookChecksTheInitCodeAndFlags() public {
        deployAll(address(pm));
        bytes memory code = initCode();
        bytes32 salt = mine();
        bytes memory wrong = bytes.concat(code, hex"00");
        vm.expectRevert(PleaLaunch.WrongInitCode.selector);
        launch.deployHook(salt, wrong);
        bytes32 bad = salt == bytes32(0) ? bytes32(uint256(1)) : bytes32(0);
        if (uint160(launch.predict(bad)) & 0x3fff != launch.FLAGS()) {
            vm.expectRevert();
            launch.deployHook(bad, code);
        }
        vm.prank(address(0xBEEF)); // anyone may deploy it: the outcome is fixed
        address h = launch.deployHook(salt, code);
        assertEq(uint160(h) & 0x3fff, launch.FLAGS());
        assertEq(plea.hook(), h);
        assertEq(plea.balanceOf(h), 870_000_000e18);
        assertEq(plea.balanceOf(address(seasons)), 30_000_000e18);
        vm.expectRevert(PleaLaunch.HookAlreadyDeployed.selector);
        launch.deployHook(salt, code);
    }

    function test_seedByOwnerAnyTimeByAnyoneAfterStart() public {
        deployAll(address(pm));
        vm.expectRevert(PleaLaunch.HookNotDeployed.selector);
        launch.seed();
        launch.deployHook(mine(), initCode());
        vm.expectRevert(abi.encodeWithSelector(PleaLaunch.TooEarly.selector, START));
        launch.seed();
        vm.warp(START);
        launch.seed();
        assertTrue(gate.cabalAlive());
        assertEq(gate.startedAt(), START);
        vm.expectRevert();
        launch.seed();
    }

    function test_ownerMaySeedEarly() public {
        deployAll(address(pm));
        launch.deployHook(mine(), initCode());
        vm.prank(OWNER);
        launch.seed();
        assertTrue(PleaHook(plea.hook()).seeded());
    }

    function test_eachStepFitsAMainnetTransaction() public {
        uint256 g = gasleft();
        deployAll(address(pm));
        uint256 deployGas = g - gasleft();
        bytes memory lbCode = type(Letterbox).creationCode;
        g = gasleft();
        launch.deployLetterbox(lbCode);
        uint256 letterboxGas = g - gasleft();
        bytes memory code = initCode();
        bytes32 salt = mine();
        g = gasleft();
        launch.deployHook(salt, code);
        uint256 hookGas = g - gasleft();
        vm.prank(OWNER);
        g = gasleft();
        launch.seed();
        uint256 seedGas = g - gasleft();
        emit log_named_uint("launch (5 contracts + intake mock)", deployGas);
        emit log_named_uint("deployLetterbox", letterboxGas);
        emit log_named_uint("deployHook", hookGas);
        emit log_named_uint("seed", seedGas);
        assertLt(deployGas, 16_777_216);
        assertLt(letterboxGas, 16_777_216);
        assertLt(hookGas, 16_777_216);
        assertLt(seedGas, 16_777_216);
        assertTrue(PleaHook(plea.hook()).seeded());
        assertEq(Letterbox(payable(plea.letterbox())).nameOf(OWNER), "");
    }
}
