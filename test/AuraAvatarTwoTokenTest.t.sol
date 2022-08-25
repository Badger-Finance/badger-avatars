// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {console2 as console} from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20Upgradeable} from "openzeppelin-contracts-upgradeable/interfaces/IERC20Upgradeable.sol";

import {IBaseRewardPool} from "../src/interfaces/aura/IBaseRewardPool.sol";
import {IAggregatorV3} from "../src/interfaces/chainlink/IAggregatorV3.sol";
import {AuraAvatarTwoToken, TokenAmount} from "../src/avatars/aura/AuraAvatarTwoToken.sol";
import {AuraConstants} from "../src/avatars/aura/AuraConstants.sol";

import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";

uint256 constant PID_80BADGER_20WBTC = 11;
uint256 constant PID_40WBTC_40DIGG_20GRAVIAURA = 18;

// TODO: Maybe add event tests
contract AuraAvatarTwoTokenTest is Test, AuraConstants {
    AuraAvatarTwoToken avatar;

    IERC20Upgradeable constant BPT_80BADGER_20WBTC = IERC20Upgradeable(0xb460DAa847c45f1C4a41cb05BFB3b51c92e41B36);
    IERC20Upgradeable constant BPT_40WBTC_40DIGG_20GRAVIAURA =
        IERC20Upgradeable(0x8eB6c82C3081bBBd45DcAC5afA631aaC53478b7C);

    IBaseRewardPool constant BASE_REWARD_POOL_80BADGER_20WBTC =
        IBaseRewardPool(0xCea3aa5b2a50e39c7C7755EbFF1e9E1e1516D3f5);
    IBaseRewardPool constant BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA =
        IBaseRewardPool(0x10Ca519614b0F3463890387c24819001AFfC5152);

    address constant owner = address(1);
    address constant manager = address(2);
    address constant keeper = address(3);

    function setUp() public {
        avatar = new AuraAvatarTwoToken(PID_80BADGER_20WBTC, PID_40WBTC_40DIGG_20GRAVIAURA);
        avatar.initialize(owner, manager, keeper);

        deal(address(avatar.asset1()), owner, 10e18, true);
        deal(address(avatar.asset2()), owner, 20e18, true);

        vm.startPrank(owner);
        BPT_80BADGER_20WBTC.approve(address(avatar), 10e18);
        BPT_40WBTC_40DIGG_20GRAVIAURA.approve(address(avatar), 20e18);
        vm.stopPrank();
    }

    ////////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////////

    function test_constructor() public {
        assertEq(avatar.pid1(), PID_80BADGER_20WBTC);
        assertEq(avatar.pid2(), PID_40WBTC_40DIGG_20GRAVIAURA);

        assertEq(address(avatar.asset1()), address(BPT_80BADGER_20WBTC));
        assertEq(address(avatar.asset2()), address(BPT_40WBTC_40DIGG_20GRAVIAURA));

        assertEq(address(avatar.baseRewardPool1()), address(BASE_REWARD_POOL_80BADGER_20WBTC));
        assertEq(address(avatar.baseRewardPool2()), address(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA));
    }

    function test_initialize() public {
        assertEq(avatar.owner(), owner);
        assertFalse(avatar.paused());

        assertEq(avatar.manager(), manager);
        assertEq(avatar.keeper(), keeper);

        assertGt(avatar.sellBpsBalToUsd(), 0);
        assertGt(avatar.sellBpsAuraToUsd(), 0);

        uint256 bpsVal;
        uint256 bpsMin;

        (bpsVal, bpsMin) = avatar.minOutBpsBalToUsd();
        assertGt(bpsVal, 0);
        assertGt(bpsMin, 0);

        (bpsVal, bpsMin) = avatar.minOutBpsAuraToUsd();
        assertGt(bpsVal, 0);
        assertGt(bpsMin, 0);

        (bpsVal, bpsMin) = avatar.minOutBpsBalToAuraBal();
        assertGt(bpsVal, 0);
        assertGt(bpsMin, 0);
    }

    function test_assets() public {
        IERC20Upgradeable[2] memory assets = avatar.assets();

        assertEq(address(assets[0]), address(BPT_80BADGER_20WBTC));
        assertEq(address(assets[1]), address(BPT_40WBTC_40DIGG_20GRAVIAURA));
    }

    ////////////////////////////////////////////////////////////////////////////
    // Pausing
    ////////////////////////////////////////////////////////////////////////////

    function test_pause() public {
        address[2] memory actors = [owner, manager];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.prank(actors[i]);
            avatar.pause();

            assertTrue(avatar.paused());

            vm.revertTo(snapId);
        }
    }

    function test_pause_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotOwnerOrManager.selector, (address(this))));
        avatar.pause();
    }

    function test_unpause() public {
        vm.startPrank(owner);
        avatar.pause();

        assertTrue(avatar.paused());

        avatar.unpause();
        assertFalse(avatar.paused());
    }

    function test_unpause_permissions() public {
        vm.prank(owner);
        avatar.pause();

        address[2] memory actors = [address(this), manager];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.expectRevert("Ownable: caller is not the owner");
            vm.prank(actors[i]);
            avatar.unpause();

            vm.revertTo(snapId);
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // Config: Owner
    ////////////////////////////////////////////////////////////////////////////

    function test_setManager() public {
        vm.prank(owner);
        avatar.setManager(address(10));

        assertEq(avatar.manager(), address(10));
    }

    function test_setManager_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setManager(address(0));
    }

    function test_setKeeper() public {
        vm.prank(owner);
        avatar.setKeeper(address(10));

        assertEq(avatar.keeper(), address(10));
    }

    function test_setKeeper_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setKeeper(address(0));
    }

    function test_setClaimFrequency() public {
        vm.prank(owner);
        avatar.setClaimFrequency(2 weeks);

        assertEq(avatar.claimFrequency(), 2 weeks);
    }

    function test_setClaimFrequency_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setClaimFrequency(2 weeks);
    }

    function test_setSellBpsBalToUsd() public {
        vm.prank(owner);
        avatar.setSellBpsBalToUsd(5000);

        assertEq(avatar.sellBpsBalToUsd(), 5000);
    }

    function test_setSellBpsBalToUsd_invalidValues() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setSellBpsBalToUsd(1000000);
    }

    function test_setSellBpsBalToUsd_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setSellBpsBalToUsd(5000);
    }

    function test_setSellBpsAuraToUsd() public {
        vm.prank(owner);
        avatar.setSellBpsAuraToUsd(5000);

        assertEq(avatar.sellBpsAuraToUsd(), 5000);
    }

    function test_setSellBpsAuraToUsd_invalidValues() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setSellBpsAuraToUsd(1000000);
    }

    function test_setSellBpsAuraToUsd_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setSellBpsAuraToUsd(5000);
    }

    function test_setMinOutBpsBalToUsdMin() public {
        vm.prank(owner);
        avatar.setMinOutBpsBalToUsdMin(5000);

        (, uint256 val) = avatar.minOutBpsBalToUsd();
        assertEq(val, 5000);
    }

    function test_setMinOutBpsBalToUsdMin_invalidValues() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToUsdMin(1000000);
    }

    function test_setMinOutBpsBalToUsdMin_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setMinOutBpsBalToUsdMin(5000);
    }

    function test_setMinOutBpsAuraToUsdMin() public {
        vm.prank(owner);
        avatar.setMinOutBpsAuraToUsdMin(5000);

        (, uint256 val) = avatar.minOutBpsAuraToUsd();
        assertEq(val, 5000);
    }

    function test_setMinOutBpsAuraToUsdMin_invalidValues() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsAuraToUsdMin(1000000);
    }

    function test_setMinOutBpsAuraToUsdMin_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setMinOutBpsAuraToUsdMin(5000);
    }

    function test_setMinOutBpsBalToAuraBalMin() public {
        vm.prank(owner);
        avatar.setMinOutBpsBalToAuraBalMin(5000);

        (, uint256 val) = avatar.minOutBpsBalToAuraBal();
        assertEq(val, 5000);
    }

    function test_setMinOutBpsBalToAuraBalMin_invalidValues() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToAuraBalMin(1000000);
    }

    function test_setMinOutBpsBalToAuraBalMin_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setMinOutBpsBalToAuraBalMin(5000);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Config: Manager/Owner
    ////////////////////////////////////////////////////////////////////////////

    function test_setMinOutBpsBalToUsdVal() external {
        uint256 val;

        vm.prank(owner);
        avatar.setMinOutBpsBalToUsdVal(9100);
        (val,) = avatar.minOutBpsBalToUsd();
        assertEq(val, 9100);

        vm.prank(manager);
        avatar.setMinOutBpsBalToUsdVal(9200);
        (val,) = avatar.minOutBpsBalToUsd();
        assertEq(val, 9200);
    }

    function test_setMinOutBpsBalToUsdVal_invalidValues() external {
        vm.startPrank(owner);
        avatar.setMinOutBpsBalToUsdMin(9000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.LessThanMinBps.selector, 1000, 9000));
        avatar.setMinOutBpsBalToUsdVal(1000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToUsdVal(1000000);
    }

    function test_setMinOutBpsBalToUsdVal_permissions() external {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotOwnerOrManager.selector, (address(this))));
        avatar.setMinOutBpsBalToUsdVal(9100);
    }

    function test_setMinOutBpsAuraToUsdVal() external {
        uint256 val;

        vm.prank(owner);
        avatar.setMinOutBpsAuraToUsdVal(9100);
        (val,) = avatar.minOutBpsAuraToUsd();
        assertEq(val, 9100);

        vm.prank(manager);
        avatar.setMinOutBpsAuraToUsdVal(9200);
        (val,) = avatar.minOutBpsAuraToUsd();
        assertEq(val, 9200);
    }

    function test_setMinOutBpsAuraToUsdVal_invalidValues() external {
        vm.startPrank(owner);
        avatar.setMinOutBpsAuraToUsdMin(9000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.LessThanMinBps.selector, 1000, 9000));
        avatar.setMinOutBpsAuraToUsdVal(1000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsAuraToUsdVal(1000000);
    }

    function test_setMinOutBpsAuraToUsdVal_permissions() external {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotOwnerOrManager.selector, address(this)));
        avatar.setMinOutBpsAuraToUsdVal(9100);
    }

    function test_setMinOutBpsBalToAuraBalVal() external {
        uint256 val;

        vm.prank(owner);
        avatar.setMinOutBpsBalToAuraBalVal(9100);
        (val,) = avatar.minOutBpsBalToAuraBal();
        assertEq(val, 9100);

        vm.prank(manager);
        avatar.setMinOutBpsBalToAuraBalVal(9200);
        (val,) = avatar.minOutBpsBalToAuraBal();
        assertEq(val, 9200);
    }

    function test_setMinOutBpsBalToAuraBalVal_invalidValues() external {
        vm.startPrank(owner);
        avatar.setMinOutBpsBalToAuraBalMin(9000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.LessThanMinBps.selector, 1000, 9000));
        avatar.setMinOutBpsBalToAuraBalVal(1000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToAuraBalVal(1000000);
    }

    function test_setMinOutBpsBalToAuraBalVal_permissions() external {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotOwnerOrManager.selector, (address(this))));
        avatar.setMinOutBpsBalToAuraBalVal(9100);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Owner
    ////////////////////////////////////////////////////////////////////////////

    function test_deposit() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        assertEq(BPT_80BADGER_20WBTC.balanceOf(owner), 0);
        assertEq(BPT_40WBTC_40DIGG_20GRAVIAURA.balanceOf(address(avatar)), 0);

        assertEq(BASE_REWARD_POOL_80BADGER_20WBTC.balanceOf(address(avatar)), 10e18);
        assertEq(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.balanceOf(address(avatar)), 20e18);

        assertEq(avatar.lastClaimTimestamp(), block.timestamp);
    }

    function test_deposit_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.deposit(1, 1);
    }

    function test_deposit_empty() public {
        vm.expectRevert(AuraAvatarTwoToken.NothingToDeposit.selector);
        vm.prank(owner);
        avatar.deposit(0, 0);
    }

    function test_totalAssets() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        uint256[2] memory amounts = avatar.totalAssets();
        assertEq(amounts[0], 10e18);
        assertEq(amounts[1], 20e18);
    }

    function test_withdrawAll() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        vm.prank(owner);
        avatar.withdrawAll();

        assertEq(BASE_REWARD_POOL_80BADGER_20WBTC.balanceOf(address(avatar)), 0);
        assertEq(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.balanceOf(address(avatar)), 0);

        assertEq(BPT_80BADGER_20WBTC.balanceOf(owner), 10e18);
        assertEq(BPT_40WBTC_40DIGG_20GRAVIAURA.balanceOf(owner), 20e18);
    }

    function test_withdrawAll_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.withdrawAll();
    }

    function test_claimRewardsAndSendToOwner() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        skip(1 hours);

        assertGt(BASE_REWARD_POOL_80BADGER_20WBTC.earned(address(avatar)), 0);
        assertGt(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.earned(address(avatar)), 0);

        vm.prank(owner);
        avatar.claimRewardsAndSendToOwner();

        assertEq(BASE_REWARD_POOL_80BADGER_20WBTC.earned(address(avatar)), 0);
        assertEq(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.earned(address(avatar)), 0);

        assertEq(BAL.balanceOf(address(avatar)), 0);
        assertEq(AURA.balanceOf(address(avatar)), 0);

        assertGt(BAL.balanceOf(owner), 0);
        assertGt(AURA.balanceOf(owner), 0);
    }

    function test_claimRewardsAndSendToOwner_permissions() public {
        address[2] memory actors = [address(this), manager];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.expectRevert("Ownable: caller is not the owner");
            vm.prank(actors[i]);
            avatar.claimRewardsAndSendToOwner();

            vm.revertTo(snapId);
        }
    }

    function test_claimRewardsAndSendToOwner_noRewards() public {
        vm.expectRevert(AuraAvatarTwoToken.NoRewards.selector);
        vm.prank(owner);
        avatar.claimRewardsAndSendToOwner();
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Owner/Manager
    ////////////////////////////////////////////////////////////////////////////

    function test_processRewards() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        (,, uint256 voterBalanceBefore,) = AURA_LOCKER.lockedBalances(BADGER_VOTER);
        uint256 bauraBalBalanceBefore = BAURABAL.balanceOf(owner);
        uint256 usdcBalanceBefore = USDC.balanceOf(owner);

        skip(1 hours);

        assertGt(BASE_REWARD_POOL_80BADGER_20WBTC.earned(address(avatar)), 0);
        assertGt(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.earned(address(avatar)), 0);

        address[2] memory actors = [owner, manager];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.prank(actors[i]);
            avatar.processRewards();

            (,, uint256 voterBalanceAfter,) = AURA_LOCKER.lockedBalances(BADGER_VOTER);

            assertEq(BASE_REWARD_POOL_80BADGER_20WBTC.earned(address(avatar)), 0);
            assertEq(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.earned(address(avatar)), 0);

            assertEq(BAL.balanceOf(address(avatar)), 0);
            assertEq(AURA.balanceOf(address(avatar)), 0);

            assertGt(voterBalanceAfter, voterBalanceBefore);
            assertGt(BAURABAL.balanceOf(owner), bauraBalBalanceBefore);
            assertGt(USDC.balanceOf(owner), usdcBalanceBefore);

            vm.revertTo(snapId);
        }
    }

    function test_processRewards_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotOwnerOrManager.selector, address(this)));
        avatar.processRewards();
    }

    function test_processRewards_noRewards() public {
        vm.expectRevert(AuraAvatarTwoToken.NoRewards.selector);
        vm.prank(owner);
        avatar.processRewards();
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Keeper
    ////////////////////////////////////////////////////////////////////////////

    function test_checkUpkeep() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        skip(1 weeks);

        (bool upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);
    }

    function test_checkUpkeep_premature() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        bool upkeepNeeded;

        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);

        skip(1 weeks - 1);

        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);
    }

    function test_performUpkeep() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        skip(1 weeks);

        bool upkeepNeeded;
        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        forwardClFeed(BAL_USD_FEED, 1 weeks);
        forwardClFeed(ETH_USD_FEED, 1 weeks);

        vm.prank(keeper);
        avatar.performUpkeep(new bytes(0));

        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);
    }

    function test_performUpkeep_permissions() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        address[3] memory actors = [address(this), owner, manager];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotKeeper.selector, actors[i]));
            vm.prank(actors[i]);
            avatar.performUpkeep(new bytes(0));

            vm.revertTo(snapId);
        }
    }

    function test_performUpkeep_premature() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        skip(1 weeks - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                AuraAvatarTwoToken.TooSoon.selector, block.timestamp, avatar.lastClaimTimestamp(), avatar.claimFrequency()
            )
        );
        vm.prank(keeper);
        avatar.performUpkeep(new bytes(0));
    }

    ////////////////////////////////////////////////////////////////////////////
    // Internal helpers
    ////////////////////////////////////////////////////////////////////////////

    function forwardClFeed(IAggregatorV3 _feed) internal {
        int256 lastAnswer = _feed.latestAnswer();
        vm.etch(address(_feed), type(MockV3Aggregator).runtimeCode);
        MockV3Aggregator(address(_feed)).updateAnswer(lastAnswer);
    }

    function forwardClFeed(IAggregatorV3 _feed, uint256 _duration) internal {
        int256 lastAnswer = _feed.latestAnswer();
        uint256 lastTimestamp = _feed.latestTimestamp();
        vm.etch(address(_feed), type(MockV3Aggregator).runtimeCode);
        MockV3Aggregator(address(_feed)).updateAnswerAndTimestamp(lastAnswer, lastTimestamp + _duration);
    }
}
