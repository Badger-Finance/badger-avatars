// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

import {IERC20MetadataUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {IAvatar} from "../../src/interfaces/badger/IAvatar.sol";
import {IKeeperRegistry} from "../../src/interfaces/chainlink/IKeeperRegistry.sol";
import {AuraAvatarTwoToken} from "../../src/aura/AuraAvatarTwoToken.sol";
import {AvatarRegistry} from "../../src/registry/AvatarRegistry.sol";

contract AvatarRegistryTest is Test {
    AuraAvatarTwoToken avatar;
    AvatarRegistry registry;

    IERC20MetadataUpgradeable constant LINK = IERC20MetadataUpgradeable(0x514910771AF9Ca656af840dff83E8264EcF986CA);
    address public constant KEEPER_REGISTRY = 0x02777053d6764996e594c3E88AF1D58D5363a2e6;
    IKeeperRegistry public constant CL_REGISTRY = IKeeperRegistry(KEEPER_REGISTRY);
    address public constant TECHOPS = 0x86cbD0ce0c087b482782c181dA8d191De18C8275;
    uint256 constant MONITORING_AVATAR_GAS_LIMIT = 1_000_000;

    address constant admin = address(1);
    address constant eoa = address(2);
    address constant dummy_avatar = address(3);

    event SweepLinkToTechops(uint256 amount, uint256 timestamp);

    function setUp() public {
        vm.createSelectFork("mainnet", 15858000);

        registry = new AvatarRegistry(admin);

        avatar = new AuraAvatarTwoToken(20, 21);
        avatar.initialize(admin, eoa, KEEPER_REGISTRY);

        deal(address(LINK), address(registry), 1000e18);

        vm.startPrank(admin);
        registry.avatarMonitoring(MONITORING_AVATAR_GAS_LIMIT);
        vm.stopPrank();
    }

    function test_avatar_monitoring() public {
        assertTrue(registry.avatarMonitoringUpKeepId() > 0);
        assertEq(LINK.allowance(address(registry), address(registry.CL_REGISTRY())), type(uint256).max);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Config: Admin
    ////////////////////////////////////////////////////////////////////////////

    function test_addAvatar_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(AvatarRegistry.NotGovernance.selector, (address(this))));
        registry.addAvatar(address(0), "randomAvatar", 500000);
    }

    function test_addAvatar_requires() public {
        vm.startPrank(admin);
        vm.expectRevert(AvatarRegistry.ZeroAddress.selector);
        registry.addAvatar(address(0), "randomAvatar", 500000);

        registry.addAvatar(dummy_avatar, "randomAvatar", 500000);

        vm.expectRevert(abi.encodeWithSelector(AvatarRegistry.AvatarAlreadyRegister.selector, dummy_avatar));
        registry.addAvatar(dummy_avatar, "randomAvatar", 500000);
    }

    function test_addAvatar() public {
        vm.startPrank(admin);
        registry.addAvatar(dummy_avatar, "randomAvatar", 500000);

        (string memory name, uint256 gasLimit, AvatarRegistry.AvatarStatus status, uint256 upKeepId) =
            registry.avatarsInfo(dummy_avatar);

        assertEq(name, "randomAvatar");
        assertEqUint(gasLimit, 500000);
        assertTrue(status == AvatarRegistry.AvatarStatus.TESTING);
        assertEqUint(upKeepId, 0);

        address[] memory avatarBook = registry.getAvatars();
        assertEq(avatarBook[0], dummy_avatar);
    }

    function test_cancelAvatarUpKeep_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(AvatarRegistry.NotGovernance.selector, (address(this))));
        registry.cancelAvatarUpKeep(address(0));
    }

    function test_cancelAvatarUpKeep_requires() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(AvatarRegistry.NotAvatarIncluded.selector, dummy_avatar));
        // Test for both cases, since it cannot remove from set if not avail
        registry.cancelAvatarUpKeep(dummy_avatar);
    }

    function test_cancelAvatarUpKeep_and_removeAvatar() public {
        vm.startPrank(admin);
        registry.addAvatar(address(avatar), "randomAvatar", 500000);
        vm.stopPrank();

        // register on registry to enable cancelling
        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);
        vm.prank(KEEPER_REGISTRY);
        registry.performUpkeep(performData);
        vm.stopPrank();

        vm.startPrank(admin);
        uint256 currentBlock = block.number;
        registry.cancelAvatarUpKeep(address(avatar));

        // NOTE: advance blocks to allow fund withdrawal
        vm.roll(currentBlock + 51);
        uint256 linkBalBefore = LINK.balanceOf(address(registry));
        registry.withdrawLinkFundsAndRemoveAvatar(address(avatar));

        (string memory name, uint256 gasLimit, AvatarRegistry.AvatarStatus status, uint256 upKeepId) =
            registry.avatarsInfo(dummy_avatar);

        assertEq(name, "");
        assertEqUint(gasLimit, 0);
        assertTrue(status == AvatarRegistry.AvatarStatus.DEPRECATED);
        assertEqUint(upKeepId, 0);
        assertGt(LINK.balanceOf(address(registry)), linkBalBefore);
    }

    function test_updateStatus_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(AvatarRegistry.NotGovernance.selector, (address(this))));
        registry.updateStatus(address(0), AvatarRegistry.AvatarStatus.TESTING);
    }

    function test_updateStatus_requires() public {
        vm.prank(admin);
        registry.addAvatar(dummy_avatar, "randomAvatar", 500000);

        vm.prank(admin);
        vm.expectRevert(AvatarRegistry.UpdateSameStatus.selector);
        registry.updateStatus(dummy_avatar, AvatarRegistry.AvatarStatus.TESTING);
    }

    function test_updateStatus() public {
        vm.prank(admin);
        registry.addAvatar(dummy_avatar, "randomAvatar", 500000);
        vm.prank(admin);
        registry.updateStatus(dummy_avatar, AvatarRegistry.AvatarStatus.SEEDED);

        (,, AvatarRegistry.AvatarStatus status,) = registry.avatarsInfo(dummy_avatar);
        assertTrue(status == AvatarRegistry.AvatarStatus.SEEDED);
    }

    function test_sweep_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(AvatarRegistry.NotGovernance.selector, (address(this))));
        registry.sweepLinkFunds();
    }

    function test_sweep() public {
        uint256 linkBal = LINK.balanceOf(address(registry));
        uint256 linkTechopsBal = LINK.balanceOf(address(TECHOPS));

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit SweepLinkToTechops(linkBal, block.timestamp);
        registry.sweepLinkFunds();

        // ensure techops link balance is increased
        assertGt(LINK.balanceOf(address(TECHOPS)), linkTechopsBal);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Pausing
    ////////////////////////////////////////////////////////////////////////////

    function test_pause_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(AvatarRegistry.NotGovernance.selector, (address(this))));
        registry.pause();
    }

    function test_unpause_permissions() public {
        vm.prank(admin);
        registry.pause();

        address[2] memory actors = [address(this), eoa];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.prank(actors[i]);
            vm.expectRevert(abi.encodeWithSelector(AvatarRegistry.NotGovernance.selector, actors[i]));
            registry.unpause();

            vm.revertTo(snapId);
        }
    }

    function test_pause() public {
        vm.startPrank(admin);
        registry.pause();

        assertTrue(registry.paused());
    }

    function test_unpause() public {
        vm.startPrank(admin);
        registry.pause();

        assertTrue(registry.paused());

        registry.unpause();
        assertFalse(registry.paused());
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Keepers
    ////////////////////////////////////////////////////////////////////////////

    function test_checkUpkeep() public {
        // deploy avatar and set keeper addr
        vm.prank(admin);
        registry.addAvatar(address(avatar), "randomAvatar", 500000);

        address[] memory testA = registry.getAvatarsByStatus(AvatarRegistry.AvatarStatus.TESTING);

        for (uint256 i = 0; i < testA.length; i++) {
            console.log(testA[i]);
        }

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        (address avatarTarget, AvatarRegistry.OperationKeeperType operationType) =
            abi.decode(performData, (address, AvatarRegistry.OperationKeeperType));

        assertEq(avatarTarget, address(avatar));
        assertTrue(operationType == AvatarRegistry.OperationKeeperType.REGISTER_UPKEEP);
    }

    function test_checkUpKeep_not_required() public {
        vm.prank(admin);
        registry.addAvatar(address(avatar), "randomAvatar", 500000);
        vm.prank(admin);
        // assume that once we change status, avatar has being "register"
        registry.updateStatus(address(avatar), AvatarRegistry.AvatarStatus.SEEDED);

        address[] memory testA = registry.getAvatarsByStatus(AvatarRegistry.AvatarStatus.TESTING);

        uint256 len = testA.length;
        console.log(len);

        for (uint256 i = 0; i < len; i++) {
            console.log(testA[i]);
        }

        (bool upkeepNeeded,) = registry.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);
    }

    function test_performUpKeep_avatar_registration() public {
        vm.prank(admin);
        registry.addAvatar(address(avatar), "randomAvatar", 500000);

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        (address avatarTarget, AvatarRegistry.OperationKeeperType operationType) =
            abi.decode(performData, (address, AvatarRegistry.OperationKeeperType));

        assertEq(avatarTarget, address(avatar));
        assertTrue(operationType == AvatarRegistry.OperationKeeperType.REGISTER_UPKEEP);

        uint256 linkBalBefore = LINK.balanceOf(address(registry));
        vm.prank(KEEPER_REGISTRY);
        registry.performUpkeep(performData);

        assertLt(LINK.balanceOf(address(registry)), linkBalBefore);

        (,,, uint256 upKeepId) = registry.avatarsInfo(address(avatar));
        assertTrue(upKeepId > 0);

        (address target, uint32 executeGas, bytes memory checkData, uint96 balance,, address keeperJobAdmin,,) =
            CL_REGISTRY.getUpkeep(upKeepId);

        assertEq(target, address(avatar));
        assertEq(executeGas, 500000);
        assertEq(checkData, new bytes(0));
        assertTrue(balance > 0);
        assertEq(keeperJobAdmin, address(registry));
    }

    function test_performUpKeep_avatar_topup() public {
        vm.prank(admin);
        registry.addAvatar(address(avatar), "randomAvatar", 500000);

        bool upkeepNeeded;
        bytes memory performData;

        (upkeepNeeded, performData) = registry.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        // simply first register and then dry link funds
        vm.prank(KEEPER_REGISTRY);
        registry.performUpkeep(performData);

        (,,, uint256 upKeepId) = registry.avatarsInfo(address(avatar));

        uint96 enforceUpKeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, upKeepId),
            // getUpKeep mock
            abi.encode(address(avatar), 500000, new bytes(0), enforceUpKeepBal, address(0), TECHOPS, 2 ** 64 - 1, 0)
        );

        (upkeepNeeded, performData) = registry.checkUpkeep(new bytes(0));
        (, AvatarRegistry.OperationKeeperType operationType) =
            abi.decode(performData, (address, AvatarRegistry.OperationKeeperType));

        assertTrue(upkeepNeeded);
        assertTrue(operationType == AvatarRegistry.OperationKeeperType.TOPUP_UPKEEP);

        uint256 linkBalBefore = LINK.balanceOf(address(registry));
        vm.prank(KEEPER_REGISTRY);
        registry.performUpkeep(performData);
        vm.clearMockedCalls();

        (,,, uint96 balance,,,,) = CL_REGISTRY.getUpkeep(upKeepId);
        assertTrue(balance > enforceUpKeepBal);
        assertLt(LINK.balanceOf(address(registry)), linkBalBefore);
    }

    function test_performUpKeep_self_topup() public {
        uint256 upKeepIdTarget = registry.avatarMonitoringUpKeepId();
        uint96 enforceUpKeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, upKeepIdTarget),
            // getUpKeep mock
            abi.encode(
                address(registry),
                MONITORING_AVATAR_GAS_LIMIT,
                new bytes(0),
                enforceUpKeepBal,
                address(0),
                TECHOPS,
                2 ** 64 - 1,
                0
            )
        );

        (bool upkeepNeeded, bytes memory performData) = registry.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        (address target, AvatarRegistry.OperationKeeperType operationType) =
            abi.decode(performData, (address, AvatarRegistry.OperationKeeperType));

        assertEq(target, address(registry));
        assertTrue(operationType == AvatarRegistry.OperationKeeperType.TOPUP_UPKEEP);

        uint256 linkBalBefore = LINK.balanceOf(address(registry));
        vm.prank(KEEPER_REGISTRY);
        registry.performUpkeep(performData);
        vm.clearMockedCalls();

        (,,, uint96 balance,,,,) = CL_REGISTRY.getUpkeep(upKeepIdTarget);
        assertTrue(balance > enforceUpKeepBal);
        assertLt(LINK.balanceOf(address(registry)), linkBalBefore);
    }
}
