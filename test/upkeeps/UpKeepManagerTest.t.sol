// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

import {IERC20MetadataUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {IAvatar} from "../../src/interfaces/badger/IAvatar.sol";
import {IKeeperRegistry} from "../../src/interfaces/chainlink/IKeeperRegistry.sol";
import {AuraAvatarMultiToken} from "../../src/aura/AuraAvatarMultiToken.sol";
import {UpKeepManager} from "../../src/upkeeps/UpKeepManager.sol";

contract UpKeepManagerTest is Test {
    AuraAvatarMultiToken avatar;
    UpKeepManager upKeepManager;

    IERC20MetadataUpgradeable constant LINK = IERC20MetadataUpgradeable(0x514910771AF9Ca656af840dff83E8264EcF986CA);
    address public constant KEEPER_REGISTRY = 0x02777053d6764996e594c3E88AF1D58D5363a2e6;
    IKeeperRegistry public constant CL_REGISTRY = IKeeperRegistry(KEEPER_REGISTRY);
    address public constant TECHOPS = 0x86cbD0ce0c087b482782c181dA8d191De18C8275;
    uint256 constant MONITORING_GAS_LIMIT = 1_000_000;

    address constant admin = address(1);
    address constant eoa = address(2);
    address constant dummy_avatar = address(3);

    event SweepLinkToTechops(uint256 amount, uint256 timestamp);

    function setUp() public {
        vm.createSelectFork("mainnet", 16221000);

        upKeepManager = new UpKeepManager(admin);

        uint256[] memory pidsInit = new uint256[](2);
        pidsInit[0] = 20;
        pidsInit[1] = 21;
        avatar = new AuraAvatarMultiToken();
        avatar.initialize(admin, eoa, pidsInit);

        deal(address(LINK), address(upKeepManager), 1000e18);

        vm.startPrank(admin);
        upKeepManager.initializeBaseUpkeep(MONITORING_GAS_LIMIT);
        vm.stopPrank();
    }

    function test_upkeep_monitoring() public {
        assertTrue(upKeepManager.monitoringUpKeepId() > 0);
        assertEq(LINK.allowance(address(upKeepManager), address(CL_REGISTRY)), type(uint256).max);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Config: Admin
    ////////////////////////////////////////////////////////////////////////////

    function test_addMember_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotGovernance.selector, (address(this))));
        upKeepManager.addMember(address(0), "randomAvatar", 500000);
    }

    function test_addMember_requires() public {
        vm.startPrank(admin);
        vm.expectRevert(UpKeepManager.ZeroAddress.selector);
        upKeepManager.addMember(address(0), "randomAvatar", 500000);

        upKeepManager.addMember(address(avatar), "randomAvatar", 500000);

        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.MemberAlreadyRegister.selector, address(avatar)));
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000);
    }

    function test_addMember() public {
        uint256 linkBalBefore = LINK.balanceOf(address(upKeepManager));
        vm.startPrank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000);

        (string memory name, uint256 gasLimit, uint256 upKeepId) = upKeepManager.membersInfo(address(avatar));

        assertEq(name, "randomAvatar");
        assertEqUint(gasLimit, 500000);
        assertTrue(upKeepId > 0);

        address[] memory avatarBook = upKeepManager.getMembers();
        assertEq(avatarBook[0], address(avatar));

        assertLt(LINK.balanceOf(address(upKeepManager)), linkBalBefore);

        (address target, uint32 executeGas, bytes memory checkData, uint96 balance,, address keeperJobAdmin,,) =
            CL_REGISTRY.getUpkeep(upKeepId);

        assertEq(target, address(avatar));
        assertEq(executeGas, 500000);
        assertEq(checkData, new bytes(0));
        assertTrue(balance > 0);
        assertEq(keeperJobAdmin, address(upKeepManager));
    }

    function test_cancelMemberUpKeep_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotGovernance.selector, (address(this))));
        upKeepManager.cancelMemberUpKeep(address(0));
    }

    function test_cancelMemberUpKeep_requires() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotMemberIncluded.selector, dummy_avatar));
        // Test for both cases, since it cannot remove from set if not avail
        upKeepManager.cancelMemberUpKeep(dummy_avatar);
    }

    function test_cancelMemberUpKeep_and_removeAvatar() public {
        vm.startPrank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000);
        vm.stopPrank();

        vm.startPrank(admin);
        uint256 currentBlock = block.number;
        upKeepManager.cancelMemberUpKeep(address(avatar));

        // NOTE: advance blocks to allow fund withdrawal
        vm.roll(currentBlock + 51);
        uint256 linkBalBefore = LINK.balanceOf(address(upKeepManager));
        upKeepManager.withdrawLinkFundsAndRemoveMember(address(avatar));

        (string memory name, uint256 gasLimit, uint256 upKeepId) = upKeepManager.membersInfo(address(avatar));

        assertEq(name, "");
        assertEqUint(gasLimit, 0);
        assertEqUint(upKeepId, 0);
        assertGt(LINK.balanceOf(address(upKeepManager)), linkBalBefore);
    }

    function test_sweep_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotGovernance.selector, (address(this))));
        upKeepManager.sweepLinkFunds();
    }

    function test_sweep() public {
        uint256 linkBal = LINK.balanceOf(address(upKeepManager));
        uint256 linkTechopsBal = LINK.balanceOf(address(TECHOPS));

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit SweepLinkToTechops(linkBal, block.timestamp);
        upKeepManager.sweepLinkFunds();

        // ensure techops link balance is increased
        assertGt(LINK.balanceOf(address(TECHOPS)), linkTechopsBal);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Pausing
    ////////////////////////////////////////////////////////////////////////////

    function test_pause_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotGovernance.selector, (address(this))));
        upKeepManager.pause();
    }

    function test_unpause_permissions() public {
        vm.prank(admin);
        upKeepManager.pause();

        address[2] memory actors = [address(this), eoa];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.prank(actors[i]);
            vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotGovernance.selector, actors[i]));
            upKeepManager.unpause();

            vm.revertTo(snapId);
        }
    }

    function test_pause() public {
        vm.startPrank(admin);
        upKeepManager.pause();

        assertTrue(upKeepManager.paused());
    }

    function test_unpause() public {
        vm.startPrank(admin);
        upKeepManager.pause();

        assertTrue(upKeepManager.paused());

        upKeepManager.unpause();
        assertFalse(upKeepManager.paused());
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Keepers
    ////////////////////////////////////////////////////////////////////////////

    function test_checkUpkeep() public {
        // deploy avatar and set keeper addr
        vm.prank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000);

        address[] memory testA = upKeepManager.getMembers();

        for (uint256 i = 0; i < testA.length; i++) {
            console.log(testA[i]);
        }

        (,, uint256 upKeepId) = upKeepManager.membersInfo(address(avatar));

        uint96 enforceUpKeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, upKeepId),
            // getUpKeep mock
            abi.encode(address(avatar), 500000, new bytes(0), enforceUpKeepBal, address(0), TECHOPS, 2 ** 64 - 1, 0)
        );
        (bool upkeepNeeded, bytes memory performData) = upKeepManager.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        address avatarTarget = abi.decode(performData, (address));

        assertEq(avatarTarget, address(avatar));
    }

    function test_checkUpKeep_not_required() public {
        vm.prank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000);

        address[] memory testA = upKeepManager.getMembers();

        uint256 len = testA.length;
        console.log(len);

        for (uint256 i = 0; i < len; i++) {
            console.log(testA[i]);
        }

        (bool upkeepNeeded,) = upKeepManager.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);
    }

    function test_performUpKeep_avatar_topup() public {
        vm.prank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000);

        (,, uint256 upKeepId) = upKeepManager.membersInfo(address(avatar));

        uint96 enforceUpKeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, upKeepId),
            // getUpKeep mock
            abi.encode(address(avatar), 500000, new bytes(0), enforceUpKeepBal, address(0), TECHOPS, 2 ** 64 - 1, 0)
        );

        (bool upkeepNeeded, bytes memory performData) = upKeepManager.checkUpkeep(new bytes(0));

        assertTrue(upkeepNeeded);

        uint256 linkBalBefore = LINK.balanceOf(address(upKeepManager));
        vm.prank(KEEPER_REGISTRY);
        upKeepManager.performUpkeep(performData);
        vm.clearMockedCalls();

        (,,, uint96 balance,,,,) = CL_REGISTRY.getUpkeep(upKeepId);
        assertTrue(balance > enforceUpKeepBal);
        assertLt(LINK.balanceOf(address(upKeepManager)), linkBalBefore);
    }

    function test_performUpKeep_self_topup() public {
        uint256 upKeepIdTarget = upKeepManager.monitoringUpKeepId();
        uint96 enforceUpKeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, upKeepIdTarget),
            // getUpKeep mock
            abi.encode(
                address(upKeepManager),
                MONITORING_GAS_LIMIT,
                new bytes(0),
                enforceUpKeepBal,
                address(0),
                TECHOPS,
                2 ** 64 - 1,
                0
            )
        );

        (bool upkeepNeeded, bytes memory performData) = upKeepManager.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        address target = abi.decode(performData, (address));

        assertEq(target, address(upKeepManager));

        uint256 linkBalBefore = LINK.balanceOf(address(upKeepManager));
        vm.prank(KEEPER_REGISTRY);
        upKeepManager.performUpkeep(performData);
        vm.clearMockedCalls();

        (,,, uint96 balance,,,,) = CL_REGISTRY.getUpkeep(upKeepIdTarget);
        assertTrue(balance > enforceUpKeepBal);
        assertLt(LINK.balanceOf(address(upKeepManager)), linkBalBefore);
    }

    function test_performUpKeep_swap_involved() public {
        vm.prank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000);
        (,, uint256 upKeepIdTarget) = upKeepManager.membersInfo(address(avatar));

        bool upkeepNeeded;
        bytes memory performData;

        uint96 enforceUpKeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, upKeepIdTarget),
            // getUpKeep mock
            abi.encode(
                address(avatar),
                500000,
                new bytes(0),
                enforceUpKeepBal,
                address(0),
                address(upKeepManager),
                2 ** 64 - 1,
                0
            )
        );
        (upkeepNeeded, performData) = upKeepManager.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        // remove all link funds from upKeepManager
        vm.prank(admin);
        upKeepManager.sweepLinkFunds();
        assertEq(address(upKeepManager).balance, 0);
        assertEq(LINK.balanceOf(address(upKeepManager)), 0);
        vm.stopPrank();

        // send eth from hypothetical gas station
        vm.deal(address(upKeepManager), 2 ether);

        // trigger a perform, inspect swap with verbosity -vvvv
        vm.prank(KEEPER_REGISTRY);
        upKeepManager.performUpkeep(performData);

        (,, uint256 upKeepId) = upKeepManager.membersInfo(address(avatar));
        assertTrue(upKeepId > 0);

        (address target, uint32 executeGas, bytes memory checkData, uint96 balance,, address keeperJobAdmin,,) =
            CL_REGISTRY.getUpkeep(upKeepId);

        assertEq(target, address(avatar));
        assertEq(executeGas, 500000);
        assertEq(checkData, new bytes(0));
        assertTrue(balance > 0);
        assertEq(keeperJobAdmin, address(upKeepManager));
    }
}
