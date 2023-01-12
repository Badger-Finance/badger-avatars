// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ConvexAvatarMultiToken} from "../../src/convex/ConvexAvatarMultiToken.sol";
import {BADGER_PROXY_ADMIN} from "../../src/BaseConstants.sol";

contract ConvexAvatarMultiTokenDeploy is Script {
    // Convex
    uint256 constant CONVEX_PID_BADGER_FRAXBP = 35;

    // Config: owner and manager
    address constant VAULT_MSIG = 0xD0A7A8B98957b9CD3cFB9c0425AbE44551158e9e;
    address constant TECHOPS_MSIG = 0x86cbD0ce0c087b482782c181dA8d191De18C8275;

    function run() public {
        /// @dev pid related with vanilla curve lp positions, not private vaults
        uint256[] memory vanillaPidsInit;

        /// @dev pid related with the convex-frax private vaults
        uint256[] memory fraxPidsInit = new uint256[](1);
        fraxPidsInit[0] = CONVEX_PID_BADGER_FRAXBP;

        bytes memory initData =
            abi.encodeCall(ConvexAvatarMultiToken.initialize, (VAULT_MSIG, TECHOPS_MSIG, vanillaPidsInit, fraxPidsInit));

        vm.startBroadcast();
        address logic = address(new ConvexAvatarMultiToken());
        ConvexAvatarMultiToken(
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
