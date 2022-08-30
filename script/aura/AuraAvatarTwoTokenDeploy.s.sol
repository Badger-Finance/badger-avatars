// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

import {Script} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {AuraAvatarTwoToken} from "../../src/aura/AuraAvatarTwoToken.sol";
import {BADGER_PROXY_ADMIN, PID_80BADGER_20WBTC, PID_40WBTC_40DIGG_20GRAVIAURA} from "../../src/BaseConstants.sol";

contract AuraAvatarTwoTokenDeploy is Script {
    function run() public {
        bytes memory initData = abi.encodeCall(AuraAvatarTwoToken.initialize, (msg.sender, msg.sender, msg.sender));

        vm.startBroadcast();
        address logic = address(new AuraAvatarTwoToken(PID_80BADGER_20WBTC, PID_40WBTC_40DIGG_20GRAVIAURA));
        AuraAvatarTwoToken(address(new TransparentUpgradeableProxy(logic, BADGER_PROXY_ADMIN, initData)));
    }
}
