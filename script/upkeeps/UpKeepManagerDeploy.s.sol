// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";

import {UpKeepManager} from "../../src/upkeeps/UpKeepManager.sol";

contract UpKeepManagerDeploy is Script {
    // Config: governance
    address constant TECHOPS_MSIG = 0x86cbD0ce0c087b482782c181dA8d191De18C8275;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast();

        UpKeepManager upkeepManager = new UpKeepManager(TECHOPS_MSIG);

        vm.stopBroadcast();
    }
}
