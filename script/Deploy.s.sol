// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PLEA} from "../src/PLEA.sol";
import {CabalGate} from "../src/CabalGate.sol";
import {Seasons} from "../src/Seasons.sol";
import {PleaDistributor} from "../src/PleaDistributor.sol";
import {Letterbox} from "../src/Letterbox.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";

/// @notice What the IMD launch does, as one script, for local runs and gas checks (a fork or anvil).
/// The real launch deploys the same five contracts in this order in one transaction (launch.json);
/// the Letterbox follows in its own transaction through `PleaLaunch.deployLetterbox`, as here.
/// Env: OWNER, INTAKE, ORACLE_ASSET, IMD, ORACLE_SIGNER, SEASON, DEADMAN, POOL_MANAGER, STACKER,
/// CREDIT_GAS, START, MINT_ORACLE_FEE.
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        PLEA plea = new PLEA(vm.envAddress("OWNER"));
        CabalGate gate = new CabalGate(
            address(plea),
            vm.envAddress("INTAKE"),
            vm.envAddress("ORACLE_ASSET"),
            vm.envAddress("IMD"),
            vm.envAddress("ORACLE_SIGNER"),
            vm.envUint("SEASON"),
            vm.envUint("DEADMAN")
        );
        Seasons seasons = new Seasons(address(plea), address(gate), vm.envAddress("IMD"));
        PleaDistributor distributor = new PleaDistributor(address(plea), vm.envAddress("OWNER"));
        PleaLaunch launch = new PleaLaunch(
            address(plea),
            address(gate),
            address(seasons),
            address(distributor),
            vm.envAddress("POOL_MANAGER"),
            vm.envAddress("IMD"),
            vm.envAddress("STACKER"),
            vm.envUint("CREDIT_GAS"),
            vm.envUint("START"),
            vm.envAddress("ORACLE_ASSET"),
            vm.envBool("MINT_ORACLE_FEE"),
            keccak256(type(Letterbox).creationCode)
        );
        address letterbox = launch.deployLetterbox(type(Letterbox).creationCode);
        vm.stopBroadcast();
        console2.log("PLEA", address(plea));
        console2.log("CabalGate", address(gate));
        console2.log("Seasons", address(seasons));
        console2.log("PleaDistributor", address(distributor));
        console2.log("PleaLaunch", address(launch));
        console2.log("Letterbox", letterbox);
    }
}
