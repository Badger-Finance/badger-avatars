// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2 as console} from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";

import {IERC20MetadataUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {AvatarRegistry} from "../../src/registry/AvatarRegistry.sol";

contract AvatarRegistryTest is Test {
    AvatarRegistry registry;

    IERC20MetadataUpgradeable constant LINK =
        IERC20MetadataUpgradeable(0x514910771AF9Ca656af840dff83E8264EcF986CA);
    uint256 constant MONITORING_AVATAR_GAS_LIMIT = 1_000_000;

    address constant admin = address(1);

    function setUp() public {
        vm.createSelectFork("mainnet", 15858000);

        registry = new AvatarRegistry(admin);

        deal(address(LINK), address(registry), 1000e18);

        vm.startPrank(admin);
        registry.avatarMonitoring(MONITORING_AVATAR_GAS_LIMIT);
        vm.stopPrank();
    }

    function test_avatar_monitoring() public {
        assertTrue(registry.avatarMonitoringUpKeepId() > 0);
        assertEq(
            LINK.allowance(address(registry), registry.KEEPER_REGISTRY()),
            type(uint256).max
        );
    }
}
