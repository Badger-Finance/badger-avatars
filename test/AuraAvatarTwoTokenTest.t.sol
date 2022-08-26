// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {console2 as console} from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {IERC20Upgradeable} from "openzeppelin-contracts-upgradeable/interfaces/IERC20Upgradeable.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IBaseRewardPool} from "../src/interfaces/aura/IBaseRewardPool.sol";
import {IAggregatorV3} from "../src/interfaces/chainlink/IAggregatorV3.sol";
import {AuraAvatarTwoToken, TokenAmount} from "../src/avatars/aura/AuraAvatarTwoToken.sol";
import {AuraConstants} from "../src/avatars/aura/AuraConstants.sol";

import {MockV3Aggregator} from "./mocks/MockV3Aggregator.sol";

uint256 constant PID_80BADGER_20WBTC = 11;
uint256 constant PID_40WBTC_40DIGG_20GRAVIAURA = 18;

// TODO: Add event tests
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
        // TODO: Remove hardcoded block
        vm.createSelectFork("mainnet", 15397859);

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

        assertGt(avatar.sellBpsBalToUsdc(), 0);
        assertGt(avatar.sellBpsAuraToUsdc(), 0);

        uint256 bpsVal;
        uint256 bpsMin;

        (bpsVal, bpsMin) = avatar.minOutBpsBalToUsdc();
        assertGt(bpsVal, 0);
        assertGt(bpsMin, 0);

        (bpsVal, bpsMin) = avatar.minOutBpsAuraToUsdc();
        assertGt(bpsVal, 0);
        assertGt(bpsMin, 0);

        (bpsVal, bpsMin) = avatar.minOutBpsBalToBpt();
        assertGt(bpsVal, 0);
        assertGt(bpsMin, 0);
    }

    function test_proxy_immutables() public {
        address logic = address(new AuraAvatarTwoToken(PID_80BADGER_20WBTC, PID_40WBTC_40DIGG_20GRAVIAURA));
        AuraAvatarTwoToken avatarProxy = AuraAvatarTwoToken(
            address(
                new TransparentUpgradeableProxy(logic, address(4), 
                                                abi.encodeCall(
                                                    AuraAvatarTwoToken.initialize,
                                                    (owner, manager, keeper)
                                                )
                                        )
            )
        );

        assertEq(avatarProxy.pid1(), PID_80BADGER_20WBTC);
        assertEq(avatarProxy.pid2(), PID_40WBTC_40DIGG_20GRAVIAURA);

        assertEq(address(avatarProxy.asset1()), address(BPT_80BADGER_20WBTC));
        assertEq(address(avatarProxy.asset2()), address(BPT_40WBTC_40DIGG_20GRAVIAURA));

        assertEq(address(avatarProxy.baseRewardPool1()), address(BASE_REWARD_POOL_80BADGER_20WBTC));
        assertEq(address(avatarProxy.baseRewardPool2()), address(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA));
    }

    // TODO: Test double init fails

    // TODO: Test ownership transfer

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

    function test_setSellBpsBalToUsdc() public {
        vm.prank(owner);
        avatar.setSellBpsBalToUsdc(5000);

        assertEq(avatar.sellBpsBalToUsdc(), 5000);
    }

    function test_setSellBpsBalToUsd_invalidValues() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setSellBpsBalToUsdc(1000000);
    }

    function test_setSellBpsBalToUsd_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setSellBpsBalToUsdc(5000);
    }

    function test_setSellBpsAuraToUsdc() public {
        vm.prank(owner);
        avatar.setSellBpsAuraToUsdc(5000);

        assertEq(avatar.sellBpsAuraToUsdc(), 5000);
    }

    function test_setSellBpsAuraToUsd_invalidValues() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setSellBpsAuraToUsdc(1000000);
    }

    function test_setSellBpsAuraToUsd_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setSellBpsAuraToUsdc(5000);
    }

    function test_setMinOutBpsBalToUsdcMin() public {
        vm.prank(owner);
        avatar.setMinOutBpsBalToUsdcMin(5000);

        (, uint256 val) = avatar.minOutBpsBalToUsdc();
        assertEq(val, 5000);
    }

    function test_setMinOutBpsBalToUsdcMin_invalidValues() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToUsdcMin(1000000);
    }

    function test_setMinOutBpsBalToUsdcMin_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setMinOutBpsBalToUsdcMin(5000);
    }

    function test_setMinOutBpsAuraToUsdcMin() public {
        vm.prank(owner);
        avatar.setMinOutBpsAuraToUsdcMin(5000);

        (, uint256 val) = avatar.minOutBpsAuraToUsdc();
        assertEq(val, 5000);
    }

    function test_setMinOutBpsAuraToUsdcMin_invalidValues() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsAuraToUsdcMin(1000000);
    }

    function test_setMinOutBpsAuraToUsdcMin_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setMinOutBpsAuraToUsdcMin(5000);
    }

    function test_setMinOutBpsBalToBptMin() public {
        vm.prank(owner);
        avatar.setMinOutBpsBalToBptMin(5000);

        (, uint256 val) = avatar.minOutBpsBalToBpt();
        assertEq(val, 5000);
    }

    function test_setMinOutBpsBalToBptMin_invalidValues() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToBptMin(1000000);
    }

    function test_setMinOutBpsBalToBptMin_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setMinOutBpsBalToBptMin(5000);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Config: Manager/Owner
    ////////////////////////////////////////////////////////////////////////////

    function test_setMinOutBpsBalToUsdcVal() external {
        uint256 val;

        vm.prank(owner);
        avatar.setMinOutBpsBalToUsdcVal(9100);
        (val,) = avatar.minOutBpsBalToUsdc();
        assertEq(val, 9100);

        vm.prank(manager);
        avatar.setMinOutBpsBalToUsdcVal(9200);
        (val,) = avatar.minOutBpsBalToUsdc();
        assertEq(val, 9200);
    }

    function test_setMinOutBpsBalToUsdcVal_invalidValues() external {
        vm.startPrank(owner);
        avatar.setMinOutBpsBalToUsdcMin(9000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.LessThanMinBps.selector, 1000, 9000));
        avatar.setMinOutBpsBalToUsdcVal(1000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToUsdcVal(1000000);
    }

    function test_setMinOutBpsBalToUsdcVal_permissions() external {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotOwnerOrManager.selector, (address(this))));
        avatar.setMinOutBpsBalToUsdcVal(9100);
    }

    function test_setMinOutBpsAuraToUsdcVal() external {
        uint256 val;

        vm.prank(owner);
        avatar.setMinOutBpsAuraToUsdcVal(9100);
        (val,) = avatar.minOutBpsAuraToUsdc();
        assertEq(val, 9100);

        vm.prank(manager);
        avatar.setMinOutBpsAuraToUsdcVal(9200);
        (val,) = avatar.minOutBpsAuraToUsdc();
        assertEq(val, 9200);
    }

    function test_setMinOutBpsAuraToUsdcVal_invalidValues() external {
        vm.startPrank(owner);
        avatar.setMinOutBpsAuraToUsdcMin(9000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.LessThanMinBps.selector, 1000, 9000));
        avatar.setMinOutBpsAuraToUsdcVal(1000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsAuraToUsdcVal(1000000);
    }

    function test_setMinOutBpsAuraToUsdcVal_permissions() external {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotOwnerOrManager.selector, address(this)));
        avatar.setMinOutBpsAuraToUsdcVal(9100);
    }

    function test_setMinOutBpsBalToBptVal() external {
        uint256 val;

        vm.prank(owner);
        avatar.setMinOutBpsBalToBptVal(9100);
        (val,) = avatar.minOutBpsBalToBpt();
        assertEq(val, 9100);

        vm.prank(manager);
        avatar.setMinOutBpsBalToBptVal(9200);
        (val,) = avatar.minOutBpsBalToBpt();
        assertEq(val, 9200);
    }

    function test_setMinOutBpsBalToBptVal_invalidValues() external {
        vm.startPrank(owner);
        avatar.setMinOutBpsBalToBptMin(9000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.LessThanMinBps.selector, 1000, 9000));
        avatar.setMinOutBpsBalToBptVal(1000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToBptVal(1000000);
    }

    function test_setMinOutBpsBalToBptVal_permissions() external {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotOwnerOrManager.selector, (address(this))));
        avatar.setMinOutBpsBalToBptVal(9100);
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
    // MISC
    ////////////////////////////////////////////////////////////////////////////

    // TODO: Add failing test when slippage tolerance is 100% or high (as a sanity check for oracles)
    // TODO: Test BAL/ETH bpt => auraBAL through both pools

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
