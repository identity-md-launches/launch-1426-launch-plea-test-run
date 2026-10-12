// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PleaLaunch} from "../src/PleaLaunch.sol";
import {Letterbox} from "../src/Letterbox.sol";

/// @notice After the launch: deploys the Letterbox through `PleaLaunch.deployLetterbox` (anyone, once).
/// Env: LAUNCH.
/// forge script script/DeployLetterbox.s.sol --rpc-url $RPC --private-key $KEY --broadcast
contract DeployLetterbox is Script {
    function run() external {
        PleaLaunch launch = PleaLaunch(vm.envAddress("LAUNCH"));
        bytes memory code = type(Letterbox).creationCode;
        require(keccak256(code) == launch.letterboxCodeHash(), "creation code differs from the launch's commitment");
        console2.log("Letterbox will be", launch.predictLetterbox());
        vm.startBroadcast();
        address letterbox = launch.deployLetterbox(code);
        vm.stopBroadcast();
        console2.log("Letterbox", letterbox);
    }
}
