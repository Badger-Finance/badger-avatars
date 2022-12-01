// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {AuraAvatarMultiToken} from "../../src/aura/AuraAvatarMultiToken.sol";
import {
    BADGER_PROXY_ADMIN,
    PID_80BADGER_20WBTC,
    PID_40WBTC_40DIGG_20GRAVIAURA,
    PID_50BADGER_50RETH
} from "../../src/BaseConstants.sol";

contract AuraAvatarMultiTokenDeploy is Script {
    function run() public {
        uint256[] memory pidsInit = new uint256[](3);
        pidsInit[0] = PID_80BADGER_20WBTC;
        pidsInit[1] = PID_40WBTC_40DIGG_20GRAVIAURA;
        pidsInit[2] = PID_50BADGER_50RETH;

        bytes memory initData =
            abi.encodeCall(AuraAvatarMultiToken.initialize, (msg.sender, msg.sender, msg.sender, pidsInit));

        vm.startBroadcast();
        address logic = address(new AuraAvatarMultiToken());
        AuraAvatarMultiToken(
            address(
                new TransparentUpgradeableProxy(
                    logic,
                    BADGER_PROXY_ADMIN,
                    initData
                )
            )
        );
    }
}
