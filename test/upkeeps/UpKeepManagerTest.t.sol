// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2 as console} from "forge-std/console2.sol";

import {IERC20MetadataUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {BaseAvatarUtils} from "../../src/BaseAvatarUtils.sol";
import {CHAINLINK_KEEPER_REGISTRY} from "../../src/BaseConstants.sol";
import {IAvatar} from "../../src/interfaces/badger/IAvatar.sol";
import {IKeeperRegistry} from "../../src/interfaces/chainlink/IKeeperRegistry.sol";
import {IAggregatorV3} from "../../src/interfaces/chainlink/IAggregatorV3.sol";
import {AuraAvatarMultiToken} from "../../src/aura/AuraAvatarMultiToken.sol";
import {UpKeepManagerUtils} from "../../src/upkeeps/UpKeepManagerUtils.sol";
import {UpKeepManager} from "../../src/upkeeps/UpKeepManager.sol";

contract UpKeepManagerTest is Test, UpKeepManagerUtils {
    AuraAvatarMultiToken avatar;
    UpKeepManager upKeepManager;

    uint256 constant MONITORING_GAS_LIMIT = 1_000_000;

    address constant admin = address(1);
    address constant eoa = address(2);
    address constant dummy_avatar = address(3);

    event RoundsTopUpUpdated(uint256 oldValue, uint256 newValue);
    event MinRoundsTopUpUpdated(uint256 oldValue, uint256 newValue);

    event SweepLinkToTechops(uint256 amount, uint256 timestamp);
    event SweepEth(address recipient, uint256 amount, uint256 timestamp);

    function setUp() public {
        vm.createSelectFork("mainnet", 16385870);

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

    function test_constructor() public {
        assertEq(upKeepManager.governance(), admin);
        assertEq(upKeepManager.roundsTopUp(), 20);
        assertEq(upKeepManager.minRoundsTopUp(), 3);
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
        upKeepManager.addMember(address(0), "randomAvatar", 500000, 0);
    }

    function test_addMember_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(UpKeepManager.ZeroAddress.selector);
        upKeepManager.addMember(address(0), "randomAvatar", 500000, 0);

        vm.expectRevert(UpKeepManager.ZeroUintValue.selector);
        upKeepManager.addMember(address(6), "randomAvatar", 0, 0);

        vm.expectRevert(UpKeepManager.EmptyString.selector);
        upKeepManager.addMember(address(6), "", 500000, 0);

        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.MemberAlreadyRegister.selector, address(avatar)));
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);
    }

    function test_addMember() public {
        uint256 linkBalBefore = LINK.balanceOf(address(upKeepManager));
        vm.startPrank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

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

    function test_addMember_existing_upKeep() public {
        // NOTE: use a dripper from our infra for this test
        uint256 existingUpKeepId = 98030557125143332209375009711552185081207413079136145061022651896587613727137;
        (address target, uint32 executeGas,,,,,,) = CL_REGISTRY.getUpkeep(existingUpKeepId);

        console.log(target);

        uint256 linkBalBefore = LINK.balanceOf(address(upKeepManager));
        vm.startPrank(admin);
        upKeepManager.addMember(target, "RemBadgerDripper2023", executeGas, existingUpKeepId);

        // NOTE: given that it is registed, expected to not spend funds
        assertEq(LINK.balanceOf(address(upKeepManager)), linkBalBefore);

        (string memory name, uint256 gasLimit, uint256 upKeepId) = upKeepManager.membersInfo(target);

        assertEq(name, "RemBadgerDripper2023");
        assertEqUint(gasLimit, executeGas);
        assertEq(upKeepId, existingUpKeepId);
    }

    function test_addMember_not_auto_approve() public {
        (IKeeperRegistry.State memory state, IKeeperRegistry.Config memory config, address[] memory keepers) =
            CL_REGISTRY.getState();
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getState.selector),
            abi.encode(state, config, keepers)
        );

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotAutoApproveKeeper.selector));
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);
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

    function test_withdrawLinkFundsAndRemoveMember_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotGovernance.selector, (address(this))));
        upKeepManager.withdrawLinkFundsAndRemoveMember(address(0));
    }

    function test_withdrawLinkFundsAndRemoveMember_member_not_included() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotMemberIncluded.selector, dummy_avatar));
        upKeepManager.withdrawLinkFundsAndRemoveMember(dummy_avatar);
    }

    function test_withdrawLinkFundsAndRemoveMember_upkeep_not_cancelled() public {
        vm.startPrank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        (,, uint256 upKeepId) = upKeepManager.membersInfo(address(avatar));

        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.UpKeepNotCancelled.selector, upKeepId));
        upKeepManager.withdrawLinkFundsAndRemoveMember(address(avatar));
    }

    function test_withdrawLinkFundsAndRemoveMember() public {
        vm.startPrank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);
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

    function test_sweepEthFunds_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotGovernance.selector, (address(this))));
        upKeepManager.sweepEthFunds(payable(address(7)));
    }

    function test_sweepEthFunds() public {
        vm.deal(address(upKeepManager), 2 ether);

        uint256 ethBalBefore = eoa.balance;
        uint256 upKeepManagerEthBal = address(upKeepManager).balance;

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit SweepEth(eoa, upKeepManagerEthBal, block.timestamp);
        upKeepManager.sweepEthFunds(payable(eoa));

        assertEq(eoa.balance, ethBalBefore + upKeepManagerEthBal);
    }

    function test_setRoundsTopUp_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotGovernance.selector, (address(this))));
        upKeepManager.setRoundsTopUp(50000);
    }

    function test_setRoundsTopUp_zero_value() public {
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.ZeroUintValue.selector));
        vm.prank(admin);
        upKeepManager.setRoundsTopUp(0);
    }

    function test_setRoundsTopUp_invalid_value() public {
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.InvalidRoundsTopUp.selector, 1000));
        vm.prank(admin);
        upKeepManager.setRoundsTopUp(1000);
    }

    function test_setRoundsTopUp() public {
        vm.expectEmit(true, true, false, false);
        emit RoundsTopUpUpdated(upKeepManager.roundsTopUp(), 10);
        vm.prank(admin);
        upKeepManager.setRoundsTopUp(10);

        assertEq(upKeepManager.roundsTopUp(), 10);
    }

    function test_setMinRoundsTopUp_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotGovernance.selector, (address(this))));
        upKeepManager.setMinRoundsTopUp(50000);
    }

    function test_setMinRoundsTopUp_zero_value() public {
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.ZeroUintValue.selector));
        vm.prank(admin);
        upKeepManager.setMinRoundsTopUp(0);
    }

    function test_setMinRoundsTopUp_invalid_value() public {
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.InvalidUnderFundedThreshold.selector, 3000));
        vm.prank(admin);
        upKeepManager.setMinRoundsTopUp(3000);
    }

    function test_setMinRoundsTopUp() public {
        vm.expectEmit(true, true, false, true);
        emit MinRoundsTopUpUpdated(upKeepManager.minRoundsTopUp(), 4);
        vm.prank(admin);
        upKeepManager.setMinRoundsTopUp(4);

        assertEq(upKeepManager.minRoundsTopUp(), 4);
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
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        address[] memory testA = upKeepManager.getMembers();

        for (uint256 i = 0; i < testA.length; i++) {
            console.log(testA[i]);
        }

        (,, uint256 upKeepId) = upKeepManager.membersInfo(address(avatar));

        uint96 enforceUpKeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
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
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        address[] memory testA = upKeepManager.getMembers();

        uint256 len = testA.length;
        console.log(len);

        for (uint256 i = 0; i < len; i++) {
            console.log(testA[i]);
        }

        (bool upkeepNeeded,) = upKeepManager.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);
    }

    function test_performUpKeep_permissions() public {
        address[3] memory actors = [address(this), admin, eoa];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.prank(actors[i]);
            vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotKeeper.selector, actors[i]));
            avatar.performUpkeep(new bytes(0));

            vm.revertTo(snapId);
        }
    }

    function test_performUpKeep_unregistered_member() public {
        bytes memory performData = abi.encode(address(7));
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.MemberNotRegisteredYet.selector, address(7)));
        upKeepManager.performUpkeep(performData);
    }

    function test_performUpKeep_cancelled_member() public {
        vm.prank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);
        (,, uint256 upKeepId) = upKeepManager.membersInfo(address(avatar));

        vm.prank(admin);
        upKeepManager.cancelMemberUpKeep(address(avatar));
        vm.stopPrank();

        (,,,,,, uint256 maxValidBlocknumber,) = CL_REGISTRY.getUpkeep(upKeepId);

        uint96 enforceUpKeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, upKeepId),
            // getUpKeep mock
            abi.encode(
                address(avatar), 500000, new bytes(0), enforceUpKeepBal, address(upKeepManager), maxValidBlocknumber, 0
            )
        );

        bytes memory performData = abi.encode(address(avatar));

        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.UpkeepCancelled.selector, upKeepId));
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upKeepManager.performUpkeep(performData);
    }

    function test_performUpKeep_not_underfunded() public {
        vm.prank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);
        (,, uint256 upKeepId) = upKeepManager.membersInfo(address(avatar));

        bytes memory performData = abi.encode(address(avatar));

        vm.expectRevert(abi.encodeWithSelector(UpKeepManager.NotUnderFundedUpkeep.selector, upKeepId));
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upKeepManager.performUpkeep(performData);
    }

    function test_performUpKeep_negative_answer() public {
        vm.prank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        (,, uint256 upKeepId) = upKeepManager.membersInfo(address(avatar));

        uint96 enforceUpKeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, upKeepId),
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

        (bool upkeepNeeded, bytes memory performData) = upKeepManager.checkUpkeep(new bytes(0));

        assertTrue(upkeepNeeded);

        // remove all link funds from upKeepManager
        vm.prank(admin);
        upKeepManager.sweepLinkFunds();
        assertEq(address(upKeepManager).balance, 0);
        assertEq(LINK.balanceOf(address(upKeepManager)), 0);
        vm.stopPrank();

        // send eth from hypothetical gas station
        vm.deal(address(upKeepManager), 2 ether);

        (uint80 roundId,, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            LINK_ETH_FEED.latestRoundData();
        int256 negativeAnswer = -5e18;

        // force neg value
        vm.mockCall(
            address(LINK_ETH_FEED),
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(roundId, negativeAnswer, startedAt, updatedAt, answeredInRound)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseAvatarUtils.NegativePriceFeedAnswer.selector,
                address(LINK_ETH_FEED),
                negativeAnswer,
                block.timestamp
            )
        );
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upKeepManager.performUpkeep(performData);
    }

    function test_performUpKeep_stale_cl_feed() public {
        vm.prank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        (,, uint256 upKeepId) = upKeepManager.membersInfo(address(avatar));

        uint96 enforceUpKeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, upKeepId),
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

        (bool upkeepNeeded, bytes memory performData) = upKeepManager.checkUpkeep(new bytes(0));

        assertTrue(upkeepNeeded);

        // remove all link funds from upKeepManager
        vm.prank(admin);
        upKeepManager.sweepLinkFunds();
        assertEq(address(upKeepManager).balance, 0);
        assertEq(LINK.balanceOf(address(upKeepManager)), 0);
        vm.stopPrank();

        // send eth from hypothetical gas station
        vm.deal(address(upKeepManager), 2 ether);

        skip(1 weeks);

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseAvatarUtils.StalePriceFeed.selector, block.timestamp, LINK_ETH_FEED.latestTimestamp(), 6 hours
            )
        );
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upKeepManager.performUpkeep(performData);
    }

    function test_performUpKeep_avatar_topup() public {
        vm.prank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        (,, uint256 upKeepId) = upKeepManager.membersInfo(address(avatar));

        uint96 enforceUpKeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, upKeepId),
            // getUpKeep mock
            abi.encode(address(avatar), 500000, new bytes(0), enforceUpKeepBal, address(0), TECHOPS, 2 ** 64 - 1, 0)
        );

        (bool upkeepNeeded, bytes memory performData) = upKeepManager.checkUpkeep(new bytes(0));

        assertTrue(upkeepNeeded);

        uint256 linkBalBefore = LINK.balanceOf(address(upKeepManager));
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
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
            CHAINLINK_KEEPER_REGISTRY,
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
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upKeepManager.performUpkeep(performData);
        vm.clearMockedCalls();

        (,,, uint96 balance,,,,) = CL_REGISTRY.getUpkeep(upKeepIdTarget);
        assertTrue(balance > enforceUpKeepBal);
        assertLt(LINK.balanceOf(address(upKeepManager)), linkBalBefore);
    }

    function test_performUpKeep_swap_involved() public {
        vm.prank(admin);
        upKeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);
        (,, uint256 upKeepIdTarget) = upKeepManager.membersInfo(address(avatar));

        bool upkeepNeeded;
        bytes memory performData;

        uint96 enforceUpKeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
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
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
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
