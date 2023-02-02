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
import {UpkeepManagerUtils} from "../../src/upkeeps/UpkeepManagerUtils.sol";
import {UpkeepManager} from "../../src/upkeeps/UpkeepManager.sol";

contract UpkeepManagerTest is Test, UpkeepManagerUtils {
    AuraAvatarMultiToken avatar;
    UpkeepManager upkeepManager;

    uint256 constant MONITORING_GAS_LIMIT = 1_000_000;

    // Token to test sweep
    IERC20MetadataUpgradeable constant BADGER = IERC20MetadataUpgradeable(0x3472A5A71965499acd81997a54BBA8D852C6E53d);

    address constant admin = address(1);
    address constant eoa = address(2);
    address constant dummy_avatar = address(3);
    address constant BADGER_WHALE = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

    event RoundsTopUpUpdated(uint256 oldValue, uint256 newValue);
    event MinRoundsTopUpUpdated(uint256 oldValue, uint256 newValue);

    event ERC20Swept(address indexed token, address recipient, uint256 amount, uint256 timestamp);
    event SweepEth(address recipient, uint256 amount, uint256 timestamp);

    function setUp() public {
        vm.createSelectFork("mainnet", 16385870);

        upkeepManager = new UpkeepManager(admin);

        uint256[] memory pidsInit = new uint256[](2);
        pidsInit[0] = 20;
        pidsInit[1] = 21;
        avatar = new AuraAvatarMultiToken();
        avatar.initialize(admin, eoa, pidsInit);

        deal(address(LINK), address(upkeepManager), 1000e18);

        vm.startPrank(admin);
        upkeepManager.initializeBaseUpkeep(MONITORING_GAS_LIMIT);
        vm.stopPrank();
    }

    function test_constructor() public {
        assertEq(upkeepManager.governance(), admin);
        assertEq(upkeepManager.roundsTopUp(), 20);
        assertEq(upkeepManager.minRoundsTopUp(), 3);
    }

    function test_Upkeep_monitoring() public {
        assertTrue(upkeepManager.monitoringUpkeepId() > 0);
        assertEq(LINK.allowance(address(upkeepManager), address(CL_REGISTRY)), type(uint256).max);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Config: Admin
    ////////////////////////////////////////////////////////////////////////////

    function test_addMember_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotGovernance.selector, (address(this))));
        upkeepManager.addMember(address(0), "randomAvatar", 500000, 0);
    }

    function test_addMember_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(UpkeepManager.ZeroAddress.selector);
        upkeepManager.addMember(address(0), "randomAvatar", 500000, 0);

        vm.expectRevert(UpkeepManager.ZeroUintValue.selector);
        upkeepManager.addMember(address(6), "randomAvatar", 0, 0);

        vm.expectRevert(UpkeepManager.EmptyString.selector);
        upkeepManager.addMember(address(6), "", 500000, 0);

        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.MemberAlreadyRegister.selector, address(avatar)));
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);
    }

    function test_addMember() public {
        uint256 linkBalBefore = LINK.balanceOf(address(upkeepManager));
        vm.startPrank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        (string memory name, uint256 gasLimit, uint256 UpkeepId) = upkeepManager.membersInfo(address(avatar));

        assertEq(name, "randomAvatar");
        assertEqUint(gasLimit, 500000);
        assertTrue(UpkeepId > 0);

        address[] memory avatarBook = upkeepManager.getMembers();
        assertEq(avatarBook[0], address(avatar));

        assertLt(LINK.balanceOf(address(upkeepManager)), linkBalBefore);

        (address target, uint32 executeGas, bytes memory checkData, uint96 balance,, address keeperJobAdmin,,) =
            CL_REGISTRY.getUpkeep(UpkeepId);

        assertEq(target, address(avatar));
        assertEq(executeGas, 500000);
        assertEq(checkData, new bytes(0));
        assertTrue(balance > 0);
        assertEq(keeperJobAdmin, address(upkeepManager));
    }

    function test_addMember_existing_Upkeep() public {
        // NOTE: use a dripper from our infra for this test
        uint256 existingUpkeepId = 98030557125143332209375009711552185081207413079136145061022651896587613727137;
        (address target, uint32 executeGas,,,,,,) = CL_REGISTRY.getUpkeep(existingUpkeepId);

        console.log(target);

        uint256 linkBalBefore = LINK.balanceOf(address(upkeepManager));
        vm.startPrank(admin);
        upkeepManager.addMember(target, "RemBadgerDripper2023", executeGas, existingUpkeepId);

        // NOTE: given that it is registed, expected to not spend funds
        assertEq(LINK.balanceOf(address(upkeepManager)), linkBalBefore);

        (string memory name, uint256 gasLimit, uint256 UpkeepId) = upkeepManager.membersInfo(target);

        assertEq(name, "RemBadgerDripper2023");
        assertEqUint(gasLimit, executeGas);
        assertEq(UpkeepId, existingUpkeepId);
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
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotAutoApproveKeeper.selector));
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);
    }

    function test_cancelMemberUpkeep_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotGovernance.selector, (address(this))));
        upkeepManager.cancelMemberUpkeep(address(0));
    }

    function test_cancelMemberUpkeep_requires() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotMemberIncluded.selector, dummy_avatar));
        // Test for both cases, since it cannot remove from set if not avail
        upkeepManager.cancelMemberUpkeep(dummy_avatar);
    }

    function test_withdrawLinkFundsAndRemoveMember_member_not_included() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotMemberIncluded.selector, dummy_avatar));
        upkeepManager.withdrawLinkFundsAndRemoveMember(dummy_avatar);
    }

    function test_withdrawLinkFundsAndRemoveMember_Upkeep_not_cancelled() public {
        vm.startPrank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        (,, uint256 UpkeepId) = upkeepManager.membersInfo(address(avatar));

        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.UpkeepNotCancelled.selector, UpkeepId));
        upkeepManager.withdrawLinkFundsAndRemoveMember(address(avatar));
    }

    function test_withdrawLinkFundsAndRemoveMember() public {
        vm.startPrank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);
        vm.stopPrank();

        vm.startPrank(admin);
        uint256 currentBlock = block.number;
        upkeepManager.cancelMemberUpkeep(address(avatar));

        // NOTE: advance blocks to allow fund withdrawal
        vm.roll(currentBlock + 51);
        uint256 linkBalBefore = LINK.balanceOf(address(upkeepManager));
        upkeepManager.withdrawLinkFundsAndRemoveMember(address(avatar));

        (string memory name, uint256 gasLimit, uint256 UpkeepId) = upkeepManager.membersInfo(address(avatar));

        assertEq(name, "");
        assertEqUint(gasLimit, 0);
        assertEqUint(UpkeepId, 0);
        assertGt(LINK.balanceOf(address(upkeepManager)), linkBalBefore);
    }

    function test_sweep() public {
        vm.prank(admin);

        uint256 ownerBalBefore = BADGER.balanceOf(address(TECHOPS));

        vm.prank(BADGER_WHALE);
        BADGER.transfer(address(upkeepManager), 1 ether);

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit ERC20Swept(address(BADGER), address(TECHOPS), 1 ether, block.timestamp);
        upkeepManager.sweep(address(BADGER), address(TECHOPS));

        assertGt(BADGER.balanceOf(address(TECHOPS)), ownerBalBefore);
        assertEq(BADGER.balanceOf(address(upkeepManager)), 0);

        // NOTE: test for LINK in isolation particularly
        uint256 linkBal = LINK.balanceOf(address(upkeepManager));
        uint256 linkTechopsBal = LINK.balanceOf(address(TECHOPS));

        vm.prank(admin);
        vm.expectEmit(true, true, false, true);
        emit ERC20Swept(address(LINK), address(TECHOPS), linkBal, block.timestamp);
        upkeepManager.sweep(address(LINK), address(TECHOPS));

        // ensure techops link balance is increased
        assertGt(LINK.balanceOf(address(TECHOPS)), linkTechopsBal);
    }

    function test_sweep_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotGovernance.selector, (address(this))));
        upkeepManager.sweep(address(BADGER), address(9));
    }

    function test_sweepEthFunds_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotGovernance.selector, (address(this))));
        upkeepManager.sweepEthFunds(payable(address(7)));
    }

    function test_sweepEthFunds() public {
        vm.deal(address(upkeepManager), 2 ether);

        uint256 ethBalBefore = eoa.balance;
        uint256 UpkeepManagerEthBal = address(upkeepManager).balance;

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit SweepEth(eoa, UpkeepManagerEthBal, block.timestamp);
        upkeepManager.sweepEthFunds(payable(eoa));

        assertEq(eoa.balance, ethBalBefore + UpkeepManagerEthBal);
    }

    function test_setRoundsTopUp_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotGovernance.selector, (address(this))));
        upkeepManager.setRoundsTopUp(50000);
    }

    function test_setRoundsTopUp_zero_value() public {
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.ZeroUintValue.selector));
        vm.prank(admin);
        upkeepManager.setRoundsTopUp(0);
    }

    function test_setRoundsTopUp_invalid_value() public {
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.InvalidRoundsTopUp.selector, 1000));
        vm.prank(admin);
        upkeepManager.setRoundsTopUp(1000);
    }

    function test_setRoundsTopUp() public {
        vm.expectEmit(true, true, false, false);
        emit RoundsTopUpUpdated(upkeepManager.roundsTopUp(), 10);
        vm.prank(admin);
        upkeepManager.setRoundsTopUp(10);

        assertEq(upkeepManager.roundsTopUp(), 10);
    }

    function test_setMinRoundsTopUp_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotGovernance.selector, (address(this))));
        upkeepManager.setMinRoundsTopUp(50000);
    }

    function test_setMinRoundsTopUp_zero_value() public {
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.ZeroUintValue.selector));
        vm.prank(admin);
        upkeepManager.setMinRoundsTopUp(0);
    }

    function test_setMinRoundsTopUp_invalid_value() public {
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.InvalidUnderFundedThreshold.selector, 3000));
        vm.prank(admin);
        upkeepManager.setMinRoundsTopUp(3000);
    }

    function test_setMinRoundsTopUp() public {
        vm.expectEmit(true, true, false, true);
        emit MinRoundsTopUpUpdated(upkeepManager.minRoundsTopUp(), 4);
        vm.prank(admin);
        upkeepManager.setMinRoundsTopUp(4);

        assertEq(upkeepManager.minRoundsTopUp(), 4);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Pausing
    ////////////////////////////////////////////////////////////////////////////

    function test_pause_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotGovernance.selector, (address(this))));
        upkeepManager.pause();
    }

    function test_unpause_permissions() public {
        vm.prank(admin);
        upkeepManager.pause();

        address[2] memory actors = [address(this), eoa];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.prank(actors[i]);
            vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotGovernance.selector, actors[i]));
            upkeepManager.unpause();

            vm.revertTo(snapId);
        }
    }

    function test_pause() public {
        vm.startPrank(admin);
        upkeepManager.pause();

        assertTrue(upkeepManager.paused());
    }

    function test_unpause() public {
        vm.startPrank(admin);
        upkeepManager.pause();

        assertTrue(upkeepManager.paused());

        upkeepManager.unpause();
        assertFalse(upkeepManager.paused());
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Keepers
    ////////////////////////////////////////////////////////////////////////////

    function test_checkUpkeep() public {
        // deploy avatar and set keeper addr
        vm.prank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        address[] memory testA = upkeepManager.getMembers();

        for (uint256 i = 0; i < testA.length; i++) {
            console.log(testA[i]);
        }

        (,, uint256 UpkeepId) = upkeepManager.membersInfo(address(avatar));

        uint96 enforceUpkeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, UpkeepId),
            // getUpkeep mock
            abi.encode(address(avatar), 500000, new bytes(0), enforceUpkeepBal, address(0), TECHOPS, 2 ** 64 - 1, 0)
        );
        (bool UpkeepNeeded, bytes memory performData) = upkeepManager.checkUpkeep(new bytes(0));
        assertTrue(UpkeepNeeded);

        address avatarTarget = abi.decode(performData, (address));

        assertEq(avatarTarget, address(avatar));
    }

    function test_checkUpkeep_not_required() public {
        vm.prank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        address[] memory testA = upkeepManager.getMembers();

        uint256 len = testA.length;
        console.log(len);

        for (uint256 i = 0; i < len; i++) {
            console.log(testA[i]);
        }

        (bool UpkeepNeeded,) = upkeepManager.checkUpkeep(new bytes(0));
        assertFalse(UpkeepNeeded);
    }

    function test_performUpkeep_permissions() public {
        address[3] memory actors = [address(this), admin, eoa];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.prank(actors[i]);
            vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotKeeper.selector, actors[i]));
            avatar.performUpkeep(new bytes(0));

            vm.revertTo(snapId);
        }
    }

    function test_performUpkeep_unregistered_member() public {
        bytes memory performData = abi.encode(address(7), 0);
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.MemberNotRegisteredYet.selector, address(7)));
        upkeepManager.performUpkeep(performData);
    }

    function test_performUpkeep_cancelled_underfunded_member() public {
        vm.prank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);
        (,, uint256 UpkeepId) = upkeepManager.membersInfo(address(avatar));

        vm.prank(admin);
        upkeepManager.cancelMemberUpkeep(address(avatar));
        vm.stopPrank();

        (,,,,,, uint256 maxValidBlocknumber,) = CL_REGISTRY.getUpkeep(UpkeepId);

        uint96 enforceUpkeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, UpkeepId),
            // getUpkeep mock
            abi.encode(
                address(avatar), 500000, new bytes(0), enforceUpkeepBal, address(upkeepManager), maxValidBlocknumber, 0
            )
        );

        bytes memory performData = abi.encode(address(avatar), 0);

        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.UpkeepCancelled.selector, UpkeepId));
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upkeepManager.performUpkeep(performData);
    }

    function test_performUpkeep_withdrawLinkFunds_under_cancellation_delay() public {
        vm.prank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        (,, uint256 upkeepId) = upkeepManager.membersInfo(address(avatar));

        vm.prank(admin);
        upkeepManager.cancelMemberUpkeep(address(avatar));
        vm.stopPrank();

        (,,,,,, uint256 maxValidBlocknumber,) = CL_REGISTRY.getUpkeep(upkeepId);

        bytes memory performData = abi.encode(address(avatar), 1);

        vm.expectRevert(
            abi.encodeWithSelector(UpkeepManager.UnderCancelationDelay.selector, maxValidBlocknumber, block.number)
        );
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upkeepManager.performUpkeep(performData);
    }

    function test_performUpkeep_withdrawLinkFunds() public {
        vm.prank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        (,, uint256 upkeepId) = upkeepManager.membersInfo(address(avatar));

        vm.prank(admin);
        upkeepManager.cancelMemberUpkeep(address(avatar));
        vm.stopPrank();

        (,,,,,, uint256 maxValidBlocknumber,) = CL_REGISTRY.getUpkeep(upkeepId);

        vm.roll(maxValidBlocknumber + 1);

        (bool UpkeepNeeded, bytes memory performData) = upkeepManager.checkUpkeep(new bytes(0));
        (address member, UpkeepManager.KeeperAction action) =
            abi.decode(performData, (address, UpkeepManager.KeeperAction));

        assertTrue(UpkeepNeeded);
        assertEq(member, address(avatar));
        assertTrue(action == UpkeepManager.KeeperAction.WithdrawLinkFunds);

        uint256 linkBalBefore = LINK.balanceOf(address(upkeepManager));
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upkeepManager.performUpkeep(performData);

        (string memory name, uint256 gasLimit, uint256 upkeepID) = upkeepManager.membersInfo(address(avatar));

        assertEq(name, "");
        assertEqUint(gasLimit, 0);
        assertEqUint(upkeepID, 0);
        assertGt(LINK.balanceOf(address(upkeepManager)), linkBalBefore);
    }

    function test_performUpkeep_not_underfunded() public {
        vm.prank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);
        (,, uint256 UpkeepId) = upkeepManager.membersInfo(address(avatar));

        bytes memory performData = abi.encode(address(avatar), 0);

        vm.expectRevert(abi.encodeWithSelector(UpkeepManager.NotUnderFundedUpkeep.selector, UpkeepId));
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upkeepManager.performUpkeep(performData);
    }

    function test_performUpkeep_negative_answer() public {
        vm.prank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        (,, uint256 UpkeepId) = upkeepManager.membersInfo(address(avatar));

        uint96 enforceUpkeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, UpkeepId),
            // getUpkeep mock
            abi.encode(
                address(avatar),
                500000,
                new bytes(0),
                enforceUpkeepBal,
                address(0),
                address(upkeepManager),
                2 ** 64 - 1,
                0
            )
        );

        (bool UpkeepNeeded, bytes memory performData) = upkeepManager.checkUpkeep(new bytes(0));

        assertTrue(UpkeepNeeded);

        // remove all link funds from UpkeepManager
        vm.prank(admin);
        upkeepManager.sweep(address(LINK), address(TECHOPS));
        assertEq(address(upkeepManager).balance, 0);
        assertEq(LINK.balanceOf(address(upkeepManager)), 0);
        vm.stopPrank();

        // send eth from hypothetical gas station
        vm.deal(address(upkeepManager), 2 ether);

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
        upkeepManager.performUpkeep(performData);
    }

    function test_performUpkeep_stale_cl_feed() public {
        vm.prank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        (,, uint256 UpkeepId) = upkeepManager.membersInfo(address(avatar));

        uint96 enforceUpkeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, UpkeepId),
            // getUpkeep mock
            abi.encode(
                address(avatar),
                500000,
                new bytes(0),
                enforceUpkeepBal,
                address(0),
                address(upkeepManager),
                2 ** 64 - 1,
                0
            )
        );

        (bool UpkeepNeeded, bytes memory performData) = upkeepManager.checkUpkeep(new bytes(0));

        assertTrue(UpkeepNeeded);

        // remove all link funds from UpkeepManager
        vm.prank(admin);
        upkeepManager.sweep(address(LINK), address(TECHOPS));
        assertEq(address(upkeepManager).balance, 0);
        assertEq(LINK.balanceOf(address(upkeepManager)), 0);
        vm.stopPrank();

        // send eth from hypothetical gas station
        vm.deal(address(upkeepManager), 2 ether);

        skip(1 weeks);

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseAvatarUtils.StalePriceFeed.selector, block.timestamp, LINK_ETH_FEED.latestTimestamp(), 6 hours
            )
        );
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upkeepManager.performUpkeep(performData);
    }

    function test_performUpkeep_avatar_topup() public {
        vm.prank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);

        (,, uint256 UpkeepId) = upkeepManager.membersInfo(address(avatar));

        uint96 enforceUpkeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, UpkeepId),
            // getUpkeep mock
            abi.encode(address(avatar), 500000, new bytes(0), enforceUpkeepBal, address(0), TECHOPS, 2 ** 64 - 1, 0)
        );

        (bool UpkeepNeeded, bytes memory performData) = upkeepManager.checkUpkeep(new bytes(0));

        assertTrue(UpkeepNeeded);

        uint256 linkBalBefore = LINK.balanceOf(address(upkeepManager));
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upkeepManager.performUpkeep(performData);
        vm.clearMockedCalls();

        (,,, uint96 balance,,,,) = CL_REGISTRY.getUpkeep(UpkeepId);
        assertTrue(balance > enforceUpkeepBal);
        assertLt(LINK.balanceOf(address(upkeepManager)), linkBalBefore);
    }

    function test_performUpkeep_self_topup() public {
        uint256 UpkeepIdTarget = upkeepManager.monitoringUpkeepId();
        uint96 enforceUpkeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, UpkeepIdTarget),
            // getUpkeep mock
            abi.encode(
                address(upkeepManager),
                MONITORING_GAS_LIMIT,
                new bytes(0),
                enforceUpkeepBal,
                address(0),
                TECHOPS,
                2 ** 64 - 1,
                0
            )
        );

        (bool UpkeepNeeded, bytes memory performData) = upkeepManager.checkUpkeep(new bytes(0));
        assertTrue(UpkeepNeeded);

        address target = abi.decode(performData, (address));

        assertEq(target, address(upkeepManager));

        uint256 linkBalBefore = LINK.balanceOf(address(upkeepManager));
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upkeepManager.performUpkeep(performData);
        vm.clearMockedCalls();

        (,,, uint96 balance,,,,) = CL_REGISTRY.getUpkeep(UpkeepIdTarget);
        assertTrue(balance > enforceUpkeepBal);
        assertLt(LINK.balanceOf(address(upkeepManager)), linkBalBefore);
    }

    function test_performUpkeep_swap_involved() public {
        vm.prank(admin);
        upkeepManager.addMember(address(avatar), "randomAvatar", 500000, 0);
        (,, uint256 UpkeepIdTarget) = upkeepManager.membersInfo(address(avatar));

        bool UpkeepNeeded;
        bytes memory performData;

        uint96 enforceUpkeepBal = 1 ether;
        // https://book.getfoundry.sh/cheatcodes/mock-call#mockcall
        vm.mockCall(
            CHAINLINK_KEEPER_REGISTRY,
            abi.encodeWithSelector(IKeeperRegistry.getUpkeep.selector, UpkeepIdTarget),
            // getUpkeep mock
            abi.encode(
                address(avatar),
                500000,
                new bytes(0),
                enforceUpkeepBal,
                address(0),
                address(upkeepManager),
                2 ** 64 - 1,
                0
            )
        );
        (UpkeepNeeded, performData) = upkeepManager.checkUpkeep(new bytes(0));
        assertTrue(UpkeepNeeded);

        // remove all link funds from UpkeepManager
        vm.prank(admin);
        upkeepManager.sweep(address(LINK), address(TECHOPS));
        assertEq(address(upkeepManager).balance, 0);
        assertEq(LINK.balanceOf(address(upkeepManager)), 0);
        vm.stopPrank();

        // send eth from hypothetical gas station
        vm.deal(address(upkeepManager), 2 ether);

        // trigger a perform, inspect swap with verbosity -vvvv
        vm.prank(CHAINLINK_KEEPER_REGISTRY);
        upkeepManager.performUpkeep(performData);

        (,, uint256 UpkeepId) = upkeepManager.membersInfo(address(avatar));
        assertTrue(UpkeepId > 0);

        (address target, uint32 executeGas, bytes memory checkData, uint96 balance,, address keeperJobAdmin,,) =
            CL_REGISTRY.getUpkeep(UpkeepId);

        assertEq(target, address(avatar));
        assertEq(executeGas, 500000);
        assertEq(checkData, new bytes(0));
        assertTrue(balance > 0);
        assertEq(keeperJobAdmin, address(upkeepManager));
    }
}
