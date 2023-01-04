// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2 as console} from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "openzeppelin-contracts/proxy/transparent/ProxyAdmin.sol";
import {IERC20MetadataUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {AuraAvatarMultiToken, TokenAmount} from "../../src/aura/AuraAvatarMultiToken.sol";
import {AuraAvatarUtils} from "../../src/aura/AuraAvatarUtils.sol";
import {
    MAX_BPS,
    PID_80BADGER_20WBTC,
    PID_40WBTC_40DIGG_20GRAVIAURA,
    PID_50BADGER_50RETH
} from "../../src/BaseConstants.sol";
import {AuraConstants} from "../../src/aura/AuraConstants.sol";
import {IAsset} from "../../src/interfaces/balancer/IAsset.sol";
import {IBalancerVault, JoinKind} from "../../src/interfaces/balancer/IBalancerVault.sol";
import {IPriceOracle} from "../../src/interfaces/balancer/IPriceOracle.sol";
import {IBaseRewardPool} from "../../src/interfaces/aura/IBaseRewardPool.sol";
import {IAggregatorV3} from "../../src/interfaces/chainlink/IAggregatorV3.sol";

import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract AuraAvatarMultiTokenTest is Test, AuraAvatarUtils {
    AuraAvatarMultiToken avatar;

    IERC20MetadataUpgradeable constant BPT_80BADGER_20WBTC =
        IERC20MetadataUpgradeable(0xb460DAa847c45f1C4a41cb05BFB3b51c92e41B36);
    IERC20MetadataUpgradeable constant BPT_40WBTC_40DIGG_20GRAVIAURA =
        IERC20MetadataUpgradeable(0x8eB6c82C3081bBBd45DcAC5afA631aaC53478b7C);
    IERC20MetadataUpgradeable constant BPT_50BADGER_50RETH =
        IERC20MetadataUpgradeable(0xe340EBfcAA544da8bB1Ee9005F1a346D50Ec422e);

    IBaseRewardPool constant BASE_REWARD_POOL_80BADGER_20WBTC =
        IBaseRewardPool(0x4EFc8DED860Bc472FA8d938dc3fD4946Bc1A0a18);
    IBaseRewardPool constant BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA =
        IBaseRewardPool(0xD7c9c6922db15F47EF3131F2830d8E87f7637210);
    IBaseRewardPool constant BASE_REWARD_POOL_50BADGER_50RETH =
        IBaseRewardPool(0x4E867c6c76173539538B7a9335E89b00434Aec10);

    address constant owner = address(1);
    address constant manager = address(2);
    address constant keeper = CHAINLINK_KEEPER_REGISTRY;

    uint256[3] PIDS = [PID_80BADGER_20WBTC, PID_40WBTC_40DIGG_20GRAVIAURA, PID_50BADGER_50RETH];
    IERC20MetadataUpgradeable[3] BPTS = [BPT_80BADGER_20WBTC, BPT_40WBTC_40DIGG_20GRAVIAURA, BPT_50BADGER_50RETH];
    IBaseRewardPool[3] BASE_REWARD_POOLS =
        [BASE_REWARD_POOL_80BADGER_20WBTC, BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA, BASE_REWARD_POOL_50BADGER_50RETH];

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

    event ManagerUpdated(address indexed oldManager, address indexed newManager);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);

    event TwapPeriodUpdated(uint256 newTwapPeriod, uint256 oldTwapPeriod);
    event ClaimFrequencyUpdated(uint256 oldClaimFrequency, uint256 newClaimFrequency);

    event SellBpsAuraToUsdcUpdated(uint256 newValue, uint256 oldValue);

    event MinOutBpsBalToUsdcMinUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsAuraToUsdcMinUpdated(uint256 oldValue, uint256 newValue);

    event MinOutBpsBalToUsdcValUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsAuraToUsdcValUpdated(uint256 oldValue, uint256 newValue);

    event Deposit(address indexed token, uint256 amount, uint256 timestamp);
    event Withdraw(address indexed token, uint256 amount, uint256 timestamp);

    event RewardClaimed(address indexed token, uint256 amount, uint256 timestamp);
    event RewardsToStable(address indexed token, uint256 amount, uint256 timestamp);

    function setUp() public {
        // TODO: Remove hardcoded block
        vm.createSelectFork("mainnet", 16221000);

        // Labels
        vm.label(address(AURA), "AURA");
        vm.label(address(BAL), "BAL");
        vm.label(address(WETH), "WETH");
        vm.label(address(USDC), "USDC");

        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];
        avatar = new AuraAvatarMultiToken();
        avatar.initialize(owner, manager, pidsInit);

        for (uint256 i; i < PIDS.length; ++i) {
            deal(address(BPTS[i]), owner, 20e18, true);

            vm.prank(owner);
            BPTS[i].approve(address(avatar), 20e18);
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////////

    function test_constructor() public {
        uint256[] memory pids = avatar.getPids();
        address[] memory bpts = avatar.getAssets();
        address[] memory baseRewardPools = avatar.getbaseRewardPools();

        for (uint256 i; i < pids.length; ++i) {
            assertEq(pids[i], PIDS[i]);
            assertEq(bpts[i], address(BPTS[i]));
            assertEq(baseRewardPools[i], address(BASE_REWARD_POOLS[i]));
        }
    }

    function test_initialize() public {
        assertEq(avatar.owner(), owner);
        assertFalse(avatar.paused());

        assertEq(avatar.manager(), manager);

        uint256 bpsVal;
        uint256 bpsMin;

        (bpsVal, bpsMin) = avatar.minOutBpsBalToUsdc();
        assertEq(bpsVal, 9750);
        assertEq(bpsMin, 9000);

        (bpsVal, bpsMin) = avatar.minOutBpsAuraToUsdc();
        assertEq(bpsVal, 9750);
        assertEq(bpsMin, 9000);
    }

    function test_proxy_vars() public {
        ProxyAdmin proxyAdmin = new ProxyAdmin();

        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        address logic = address(new AuraAvatarMultiToken());

        bytes memory initData = abi.encodeCall(AuraAvatarMultiToken.initialize, (owner, manager, pidsInit));
        AuraAvatarMultiToken avatarProxy = AuraAvatarMultiToken(
            address(
                new TransparentUpgradeableProxy(
                    logic,
                    address(proxyAdmin),
                    initData
                )
            )
        );

        uint256[] memory pids = avatarProxy.getPids();
        address[] memory bpts = avatarProxy.getAssets();
        address[] memory baseRewardPools = avatarProxy.getbaseRewardPools();
        for (uint256 i; i < pids.length; ++i) {
            assertEq(pids[i], PIDS[i]);
            assertEq(bpts[i], address(BPTS[i]));
            assertEq(baseRewardPools[i], address(BASE_REWARD_POOLS[i]));
        }
    }

    function test_pendingRewards() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;

        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skip(1 weeks);

        (uint256 pendingBal, uint256 pendingAura) = avatar.pendingRewards();

        uint256 totalBal = BAL.balanceOf(address(avatar));
        uint256 totalAura = AURA.balanceOf(address(avatar));
        for (uint256 i; i < PIDS.length; ++i) {
            IBaseRewardPool baseRewardPool = IBaseRewardPool(BASE_REWARD_POOLS[i]);

            uint256 balEarned = baseRewardPool.earned(address(avatar));
            uint256 balEarnedAdjusted = (balEarned * AURA_BOOSTER.getRewardMultipliers(address(baseRewardPool)))
                / AURA_REWARD_MULTIPLIER_DENOMINATOR;

            totalBal += balEarned;
            totalAura += getMintableAuraForBalAmount(balEarnedAdjusted);
        }

        assertEq(pendingBal, totalBal);
        assertEq(pendingAura, totalAura);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Ownership
    ////////////////////////////////////////////////////////////////////////////

    function test_transferOwnership() public {
        vm.prank(owner);
        avatar.transferOwnership(address(this));

        assertEq(avatar.owner(), address(this));
    }

    function test_transferOwnership_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.transferOwnership(address(this));
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

            // Test pausable action to ensure modifier works
            vm.startPrank(keeper);

            vm.expectRevert("Pausable: paused");
            avatar.performUpkeep(new bytes(0));

            vm.expectRevert("Pausable: paused");
            avatar.processRewardsKeeper(0);

            vm.stopPrank();

            vm.revertTo(snapId);
        }
    }

    function test_pause_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.NotOwnerOrManager.selector, (address(this))));
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
        vm.expectEmit(true, true, false, false);
        emit ManagerUpdated(address(this), manager);
        avatar.setManager(address(this));

        assertEq(avatar.manager(), address(this));
    }

    function test_setManager_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setManager(address(0));
    }

    function test_setTwapPeriod() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit TwapPeriodUpdated(4 hours, 1 hours);
        avatar.setTwapPeriod(4 hours);

        assertEq(avatar.twapPeriod(), 4 hours);
    }

    function test_setTwapPeriod_zero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.ZeroTwapPeriod.selector));
        avatar.setTwapPeriod(0);
    }

    function test_setTwapPeriod_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setTwapPeriod(2 weeks);
    }

    function test_setClaimFrequency() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit ClaimFrequencyUpdated(2 weeks, 1 weeks);
        avatar.setClaimFrequency(2 weeks);

        assertEq(avatar.claimFrequency(), 2 weeks);
    }

    function test_setClaimFrequency_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setClaimFrequency(2 weeks);
    }

    function test_setSellBpsAuraToUsdc() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit SellBpsAuraToUsdcUpdated(5000, 0);
        avatar.setSellBpsAuraToUsdc(5000);

        assertEq(avatar.sellBpsAuraToUsdc(), 5000);
    }

    function test_setSellBpsAuraToUsd_invalidValues() external {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.InvalidBps.selector, 1000000));
        avatar.setSellBpsAuraToUsdc(1000000);
    }

    function test_setSellBpsAuraToUsd_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setSellBpsAuraToUsdc(5000);
    }

    function test_setMinOutBpsBalToUsdcMin() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit MinOutBpsBalToUsdcMinUpdated(5000, 9000);
        avatar.setMinOutBpsBalToUsdcMin(5000);

        (, uint256 val) = avatar.minOutBpsBalToUsdc();
        assertEq(val, 5000);
    }

    function test_setMinOutBpsBalToUsdcMin_invalidValues() external {
        vm.startPrank(owner);
        avatar.setMinOutBpsBalToUsdcVal(9500);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToUsdcMin(1000000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.MoreThanBpsVal.selector, 9600, 9500));
        avatar.setMinOutBpsBalToUsdcMin(9600);
    }

    function test_setMinOutBpsBalToUsdcMin_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setMinOutBpsBalToUsdcMin(5000);
    }

    function test_setMinOutBpsAuraToUsdcMin() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit MinOutBpsAuraToUsdcMinUpdated(5000, 9000);
        avatar.setMinOutBpsAuraToUsdcMin(5000);

        (, uint256 val) = avatar.minOutBpsAuraToUsdc();
        assertEq(val, 5000);
    }

    function test_setMinOutBpsAuraToUsdcMin_invalidValues() external {
        vm.startPrank(owner);
        avatar.setMinOutBpsAuraToUsdcVal(9500);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsAuraToUsdcMin(1000000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.MoreThanBpsVal.selector, 9600, 9500));
        avatar.setMinOutBpsAuraToUsdcMin(9600);
    }

    function test_setMinOutBpsAuraToUsdcMin_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setMinOutBpsAuraToUsdcMin(5000);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Config: Manager/Owner
    ////////////////////////////////////////////////////////////////////////////

    function test_setMinOutBpsBalToUsdcVal() external {
        uint256 val;

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit MinOutBpsBalToUsdcValUpdated(9100, 9750);
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

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToUsdcVal(1000000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.LessThanBpsMin.selector, 1000, 9000));
        avatar.setMinOutBpsBalToUsdcVal(1000);
    }

    function test_setMinOutBpsBalToUsdcVal_permissions() external {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.NotOwnerOrManager.selector, (address(this))));
        avatar.setMinOutBpsBalToUsdcVal(9100);
    }

    function test_setMinOutBpsAuraToUsdcVal() external {
        uint256 val;

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit MinOutBpsAuraToUsdcValUpdated(9100, 9750);
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

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsAuraToUsdcVal(1000000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.LessThanBpsMin.selector, 1000, 9000));
        avatar.setMinOutBpsAuraToUsdcVal(1000);
    }

    function test_setMinOutBpsAuraToUsdcVal_permissions() external {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.NotOwnerOrManager.selector, address(this)));
        avatar.setMinOutBpsAuraToUsdcVal(9100);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Owner
    ////////////////////////////////////////////////////////////////////////////

    function test_deposit() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20e18;
        amountsDeposit[1] = 10e18;
        amountsDeposit[2] = 5e18;

        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        // Deposit all BPTS
        vm.prank(owner);
        for (uint256 i; i < PIDS.length; ++i) {
            vm.expectEmit(true, false, false, true);
            emit Deposit(address(BPTS[i]), amountsDeposit[i], block.timestamp);
        }
        avatar.deposit(pidsInit, amountsDeposit);

        for (uint256 i; i < PIDS.length; ++i) {
            assertEq(BASE_REWARD_POOLS[i].balanceOf(address(avatar)), amountsDeposit[i]);
        }

        assertEq(BPT_80BADGER_20WBTC.balanceOf(owner), 0);
        assertEq(BPT_40WBTC_40DIGG_20GRAVIAURA.balanceOf(owner), 10e18);
        assertEq(BPT_50BADGER_50RETH.balanceOf(owner), 15e18);

        assertEq(avatar.lastClaimTimestamp(), 0);

        // Advancing in time
        skip(1 hours);

        // Single asset deposit
        amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 10 ether;
        pidsInit = new uint256[](1);
        pidsInit[0] = PIDS[1];

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Deposit(address(BPT_40WBTC_40DIGG_20GRAVIAURA), 10e18, block.timestamp);
        avatar.deposit(pidsInit, amountsDeposit);

        assertEq(BPT_40WBTC_40DIGG_20GRAVIAURA.balanceOf(owner), 0);

        assertEq(BASE_REWARD_POOL_80BADGER_20WBTC.balanceOf(address(avatar)), 20e18);
        assertEq(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.balanceOf(address(avatar)), 20e18);

        // lastClaimTimestamp is zero at cost of quick 1st harvest
        assertEq(avatar.lastClaimTimestamp(), 0);
    }

    function test_deposit_permissions() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.expectRevert("Ownable: caller is not the owner");
        avatar.deposit(pidsInit, amountsDeposit);
    }

    function test_deposit_empty() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.expectRevert(AuraAvatarMultiToken.NothingToDeposit.selector);
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);
    }

    function test_deposit_pidNotInStorage() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = 120;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.PidNotIncluded.selector, 120));
        avatar.deposit(pidsInit, amountsDeposit);
    }

    function test_deposit_lengthMismatch() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        uint256[] memory pidsInit = new uint256[](2);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.LengthMismatch.selector));
        avatar.deposit(pidsInit, amountsDeposit);
    }

    function test_totalAssets() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        uint256[] memory assetAmounts = avatar.totalAssets();
        assertEq(assetAmounts[0], 20 ether);
        assertEq(assetAmounts[1], 10 ether);
        assertEq(assetAmounts[2], 5 ether);
    }

    function test_withdrawAll() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        vm.prank(owner);
        for (uint256 i; i < PIDS.length; ++i) {
            vm.expectEmit(true, false, false, true);
            emit Withdraw(address(BPTS[i]), amountsDeposit[i], block.timestamp);
        }
        avatar.withdrawAll();

        for (uint256 i; i < PIDS.length; ++i) {
            assertEq(BASE_REWARD_POOLS[i].balanceOf(address(avatar)), 0);
            assertEq(BPTS[i].balanceOf(owner), 20e18);
        }
    }

    function test_withdrawAll_nothing() public {
        vm.expectRevert(AuraAvatarMultiToken.NothingToWithdraw.selector);
        vm.prank(owner);
        avatar.withdrawAll();
    }

    function test_withdrawAll_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.NotOwnerOrManager.selector, keeper));
        vm.prank(keeper);
        avatar.withdrawAll();
    }

    function test_withdraw() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 12 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.startPrank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        uint256[] memory amountsWithdraw = new uint256[](PIDS.length);
        amountsWithdraw[0] = 10 ether;
        amountsWithdraw[1] = 5 ether;
        amountsWithdraw[2] = 6 ether;
        for (uint256 i; i < PIDS.length; ++i) {
            vm.expectEmit(true, false, false, true);
            emit Withdraw(address(BPTS[i]), amountsWithdraw[i], block.timestamp);
        }
        avatar.withdraw(pidsInit, amountsWithdraw);

        assertEq(BPT_80BADGER_20WBTC.balanceOf(owner), 10e18);
        assertEq(BPT_40WBTC_40DIGG_20GRAVIAURA.balanceOf(owner), 15e18);
        assertEq(BPT_50BADGER_50RETH.balanceOf(owner), 14e18);
    }

    function test_withdraw_nothing() public {
        uint256[] memory amountsWithdraw = new uint256[](PIDS.length);
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.expectRevert(AuraAvatarMultiToken.NothingToWithdraw.selector);
        vm.prank(owner);
        avatar.withdraw(pidsInit, amountsWithdraw);
    }

    function test_withdraw_permissions() public {
        uint256[] memory amountsWithdraw = new uint256[](PIDS.length);
        amountsWithdraw[0] = 20 ether;
        amountsWithdraw[1] = 10 ether;
        amountsWithdraw[1] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.NotOwnerOrManager.selector, keeper));
        vm.prank(keeper);
        avatar.withdraw(pidsInit, amountsWithdraw);
    }

    function test_withdraw_lengthMismatch() public {
        uint256[] memory amountsWithdraw = new uint256[](1);
        uint256[] memory pidsInit = new uint256[](2);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.LengthMismatch.selector));
        avatar.withdraw(pidsInit, amountsWithdraw);
    }

    function test_claimRewardsAndSendToOwner() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        uint256 initialOwnerBal = BAL.balanceOf(owner);
        uint256 initialOwnerAura = AURA.balanceOf(owner);

        skip(1 hours);

        uint256 totalBalReward;
        for (uint256 i; i < PIDS.length; ++i) {
            uint256 balReward = BASE_REWARD_POOLS[i].earned(address(avatar));
            assertGt(balReward, 0);

            totalBalReward += balReward;
        }

        uint256 totalAuraReward = getMintableAuraForBalAmount(totalBalReward);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit RewardClaimed(address(BAL), totalBalReward, block.timestamp);
        vm.expectEmit(true, false, false, true);
        emit RewardClaimed(address(AURA), totalAuraReward, block.timestamp);
        avatar.claimRewardsAndSendToOwner();

        for (uint256 i; i < PIDS.length; ++i) {
            assertEq(BASE_REWARD_POOLS[i].earned(address(avatar)), 0);
        }

        assertEq(BAL.balanceOf(address(avatar)), 0);
        assertEq(AURA.balanceOf(address(avatar)), 0);

        assertEq(BAL.balanceOf(owner) - initialOwnerBal, totalBalReward);
        assertEq(AURA.balanceOf(owner) - initialOwnerAura, totalAuraReward);
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
        vm.expectRevert(AuraAvatarMultiToken.NoRewards.selector);
        vm.prank(owner);
        avatar.claimRewardsAndSendToOwner();
    }

    function test_addBptPositionInfo__permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.addBptPositionInfo(21);
    }

    function test_addBptPositionInfo() public {
        vm.prank(owner);
        avatar.addBptPositionInfo(21);

        uint256[] memory avatarPids = avatar.getPids();
        bool pidIsAdded;

        for (uint256 i; i < avatarPids.length; ++i) {
            if (avatarPids[i] == 21) {
                pidIsAdded = true;
                break;
            }
        }

        assertTrue(pidIsAdded);
    }

    function test_addBptPositionInfo_alreadyExists() public {
        vm.prank(owner);
        avatar.addBptPositionInfo(21);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.PidAlreadyExist.selector, 21));
        avatar.addBptPositionInfo(21);
    }

    function test_removeBptPositionInfo_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.removeBptPositionInfo(21);
    }

    function test_removeBptPositionInfo_nonExistent() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.PidNotIncluded.selector, 120));
        avatar.removeBptPositionInfo(120);
    }

    function test_removeBptPositionInfo_stillStaked() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.startPrank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        vm.expectRevert(
            abi.encodeWithSelector(
                AuraAvatarMultiToken.BptStillStaked.selector,
                address(BPT_80BADGER_20WBTC),
                address(BASE_REWARD_POOL_80BADGER_20WBTC),
                20 ether
            )
        );
        avatar.removeBptPositionInfo(PID_80BADGER_20WBTC);
    }

    function test_removeBptPositionInfo() public {
        vm.prank(owner);
        avatar.removeBptPositionInfo(PID_80BADGER_20WBTC);

        uint256[] memory avatarPids = avatar.getPids();

        bool pidIsPresent;
        for (uint256 i = 0; i < avatarPids.length; i++) {
            if (avatarPids[i] == 21) {
                pidIsPresent = true;
                break;
            }
        }

        assertFalse(pidIsPresent);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Owner/Manager
    ////////////////////////////////////////////////////////////////////////////

    function checked_processRewards(uint256 _auraPriceInUsd) internal {
        (,, uint256 voterBalanceBefore,) = AURA_LOCKER.lockedBalances(BADGER_VOTER);
        uint256 usdcBalanceBefore = USDC.balanceOf(owner);

        for (uint256 i; i < PIDS.length; ++i) {
            assertGt(BASE_REWARD_POOLS[i].earned(address(avatar)), 0);
        }

        address[2] memory actors = [owner, manager];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.prank(actors[i]);
            vm.expectEmit(false, false, false, false);
            emit RewardsToStable(address(USDC), 0, block.timestamp);
            TokenAmount[] memory processed = avatar.processRewards(_auraPriceInUsd);

            (,, uint256 voterBalanceAfter,) = AURA_LOCKER.lockedBalances(BADGER_VOTER);

            assertEq(processed[0].token, address(USDC));
            assertEq(processed[1].token, address(AURA));

            assertGt(processed[0].amount, 0);
            assertGt(processed[1].amount, 0);

            for (uint256 j; j < PIDS.length; ++j) {
                assertEq(BASE_REWARD_POOLS[j].earned(address(avatar)), 0);
            }

            assertEq(BAL.balanceOf(address(avatar)), 0);
            assertEq(AURA.balanceOf(address(avatar)), 0);

            assertGt(voterBalanceAfter, voterBalanceBefore);
            assertGt(USDC.balanceOf(owner), usdcBalanceBefore);

            vm.revertTo(snapId);
        }
    }

    function test_processRewards() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skipAndForwardFeeds(1 hours);

        (, uint256 pendingAura) = avatar.pendingRewards();
        checked_processRewards(getAuraPriceInUsdSpot(pendingAura));
    }

    function test_processRewards_noAuraPrice() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skipAndForwardFeeds(1 hours);

        checked_processRewards(0);
    }

    function test_processRewards_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.NotOwnerOrManager.selector, address(this)));
        avatar.processRewards(0);
    }

    function test_processRewards_noRewards() public {
        vm.prank(owner);
        vm.expectRevert(AuraAvatarMultiToken.NoRewards.selector);
        avatar.processRewards(0);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Keeper
    ////////////////////////////////////////////////////////////////////////////

    function test_checkUpkeep() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skip(1 weeks);

        (bool upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);
    }

    function test_checkUpkeep_premature() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);
        skipAndForwardFeeds(1 weeks);

        bool upkeepNeeded;

        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        vm.prank(keeper);
        avatar.performUpkeep(abi.encodeCall(AuraAvatarMultiToken.processRewardsKeeper, uint256(0)));

        skip(1 weeks - 1);

        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);
    }

    function test_performUpkeep() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        (,, uint256 voterBalanceBefore,) = AURA_LOCKER.lockedBalances(BADGER_VOTER);
        uint256 usdcBalanceBefore = USDC.balanceOf(owner);

        skipAndForwardFeeds(1 weeks);

        vm.prank(BADGER_VOTER);
        AURA_LOCKER.processExpiredLocks(true);

        bool upkeepNeeded;
        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        vm.prank(keeper);
        vm.expectEmit(false, false, false, false);
        emit RewardsToStable(address(USDC), 0, block.timestamp);
        avatar.performUpkeep(abi.encodeCall(AuraAvatarMultiToken.processRewardsKeeper, uint256(0)));

        // Ensure that rewards were processed properly
        for (uint256 i; i < PIDS.length; ++i) {
            assertEq(BASE_REWARD_POOLS[i].earned(address(avatar)), 0);
        }

        assertEq(BAL.balanceOf(address(avatar)), 0);
        assertEq(AURA.balanceOf(address(avatar)), 0);

        (,, uint256 voterBalanceAfter,) = AURA_LOCKER.lockedBalances(BADGER_VOTER);
        assertGt(voterBalanceAfter, voterBalanceBefore);
        assertGt(USDC.balanceOf(owner), usdcBalanceBefore);

        // Upkeep is not needed anymore
        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);
    }

    function test_performUpkeep_permissions() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        address[3] memory actors = [address(this), owner, manager];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.prank(actors[i]);
            vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.NotKeeper.selector, actors[i]));
            avatar.performUpkeep(new bytes(0));

            vm.revertTo(snapId);
        }
    }

    function test_performUpkeep_premature() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skipAndForwardFeeds(1 weeks);

        vm.prank(BADGER_VOTER);
        AURA_LOCKER.processExpiredLocks(true);

        (bool upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        vm.prank(keeper);
        avatar.performUpkeep(abi.encodeCall(AuraAvatarMultiToken.processRewardsKeeper, uint256(0)));

        skip(1 weeks - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                AuraAvatarMultiToken.TooSoon.selector,
                block.timestamp,
                avatar.lastClaimTimestamp(),
                avatar.claimFrequency()
            )
        );
        vm.prank(keeper);
        avatar.performUpkeep(abi.encodeCall(AuraAvatarMultiToken.processRewardsKeeper, uint256(0)));
    }

    function test_performUpkeep_staleFeed() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skip(1 weeks);

        vm.prank(BADGER_VOTER);
        AURA_LOCKER.processExpiredLocks(true);

        vm.expectRevert(
            abi.encodeWithSelector(
                AuraAvatarUtils.StalePriceFeed.selector, block.timestamp, BAL_USD_FEED.latestTimestamp(), 24 hours
            )
        );
        vm.prank(keeper);
        avatar.performUpkeep(abi.encodeCall(AuraAvatarMultiToken.processRewardsKeeper, uint256(0)));
    }

    function test_processRewardsKeeper_permissions() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        address[3] memory actors = [address(this), owner, manager];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.expectRevert(abi.encodeWithSelector(AuraAvatarMultiToken.NotKeeper.selector, actors[i]));
            vm.prank(actors[i]);
            avatar.processRewardsKeeper(0);

            vm.revertTo(snapId);
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // MISC
    ////////////////////////////////////////////////////////////////////////////

    function test_getAuraPriceInUsdSpot() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.startPrank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skipAndForwardFeeds(1 hours);

        (, uint256 pendingAura) = avatar.pendingRewards();

        uint256 spotPrice = getAuraPriceInUsdSpot(pendingAura) / 1e2;
        uint256 twapPrice = getAuraAmountInUsdc(1e18, 1 hours);

        // Spot price is within 2.5% of TWAP
        assertApproxEqRel(spotPrice, twapPrice, 0.025e18);
    }

    function test_checkUpkeep_price() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.startPrank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skip(1 weeks);
        (, uint256 pendingAura) = avatar.pendingRewards();
        console.log(getAuraPriceInUsdSpot(pendingAura));

        (, bytes memory performData) = avatar.checkUpkeep(new bytes(0));
        uint256 auraPriceInUsd = getPriceFromPerformData(performData);

        uint256 spotPrice = getAuraPriceInUsdSpot(pendingAura);

        assertEq(auraPriceInUsd, spotPrice);
    }

    function test_debug() public {
        console.log(getBalAmountInUsdc(1e18));
        console.log(getAuraAmountInUsdc(1e18, avatar.twapPeriod()));

        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.startPrank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skip(1 weeks);
        (, uint256 pendingAura) = avatar.pendingRewards();
        console.log(getAuraPriceInUsdSpot(pendingAura));

        (, bytes memory performData) = avatar.checkUpkeep(new bytes(0));
        uint256 auraPriceInUsd = getPriceFromPerformData(performData);
        console.log(auraPriceInUsd);
    }

    function test_processRewards_highBalMinBps() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.startPrank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skip(1 hours);

        avatar.setMinOutBpsBalToUsdcVal(MAX_BPS);

        vm.expectRevert("BAL#507");
        avatar.processRewards(0);
    }

    function test_upkeep() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skipAndForwardFeeds(1 weeks);

        (bool upkeepNeeded, bytes memory performData) = avatar.checkUpkeep(new bytes(0));

        assertTrue(upkeepNeeded);

        vm.prank(keeper);
        avatar.performUpkeep(performData);
    }

    function test_processRewardsKeeper() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skipAndForwardFeeds(1 weeks);

        (bool upkeepNeeded, bytes memory performData) = avatar.checkUpkeep(new bytes(0));
        uint256 auraPriceInUsd = getPriceFromPerformData(performData);

        assertTrue(upkeepNeeded);
        assertGt(auraPriceInUsd, 0);

        assertTrue(upkeepNeeded);

        uint256 snapId = vm.snapshot();

        vm.prank(keeper);
        avatar.performUpkeep(performData);

        // Upkeep is not needed anymore
        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);

        vm.revertTo(snapId);

        vm.prank(keeper);
        avatar.processRewardsKeeper(auraPriceInUsd);

        // Upkeep is not needed anymore
        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);
    }

    function test_upkeep_allUsdc() public {
        uint256[] memory amountsDeposit = new uint256[](PIDS.length);
        amountsDeposit[0] = 20 ether;
        amountsDeposit[1] = 10 ether;
        amountsDeposit[2] = 5 ether;
        uint256[] memory pidsInit = new uint256[](PIDS.length);
        pidsInit[0] = PIDS[0];
        pidsInit[1] = PIDS[1];
        pidsInit[2] = PIDS[2];

        vm.startPrank(owner);
        avatar.setSellBpsAuraToUsdc(MAX_BPS);

        avatar.deposit(pidsInit, amountsDeposit);
        vm.stopPrank();

        skipAndForwardFeeds(1 weeks);

        (, bytes memory performData) = avatar.checkUpkeep(new bytes(0));

        uint256 usdcBalBefore = USDC.balanceOf(owner);
        (,, uint256 voterBalanceBefore,) = AURA_LOCKER.lockedBalances(BADGER_VOTER);

        vm.prank(keeper);
        avatar.performUpkeep(performData);

        (,, uint256 voterBalanceAfter,) = AURA_LOCKER.lockedBalances(BADGER_VOTER);

        // Check expected behaviour when all goes to usdc
        assertGt(USDC.balanceOf(owner), usdcBalBefore);
        assertEq(voterBalanceAfter, voterBalanceBefore);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Internal helpers
    ////////////////////////////////////////////////////////////////////////////

    function skipAndForwardFeeds(uint256 _duration) internal {
        skip(_duration);
        forwardClFeed(BAL_USD_FEED, _duration);
        forwardClFeed(BAL_ETH_FEED, _duration);
        forwardClFeed(ETH_USD_FEED, _duration);
    }

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

    function getPriceFromPerformData(bytes memory _performData) internal pure returns (uint256 auraPriceInUsd_) {
        assembly {
            auraPriceInUsd_ := mload(add(_performData, 36))
        }
    }
}
