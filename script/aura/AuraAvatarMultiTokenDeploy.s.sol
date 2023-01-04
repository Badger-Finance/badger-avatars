// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {AuraAvatarMultiToken} from "../../src/aura/AuraAvatarMultiToken.sol";
import {BADGER_PROXY_ADMIN} from "../../src/BaseConstants.sol";

contract AuraAvatarMultiTokenDeploy is Script {
    // Aura
    uint256 constant PID_80BADGER_20WBTC = 18;
    uint256 constant PID_40WBTC_40DIGG_20GRAVIAURA = 19;
    uint256 constant PID_50BADGER_50RETH = 11;

    // Config: owner and manager
    address constant VAULT_MSIG = 0xD0A7A8B98957b9CD3cFB9c0425AbE44551158e9e;
    address constant TECHOPS_MSIG = 0x86cbD0ce0c087b482782c181dA8d191De18C8275;

    function run() public {
        uint256[] memory pidsInit = new uint256[](3);
        pidsInit[0] = PID_80BADGER_20WBTC;
        pidsInit[1] = PID_40WBTC_40DIGG_20GRAVIAURA;
        pidsInit[2] = PID_50BADGER_50RETH;

        bytes memory initData = abi.encodeCall(AuraAvatarMultiToken.initialize, (VAULT_MSIG, TECHOPS_MSIG, pidsInit));

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
