// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2 as console} from "forge-std/console2.sol";
import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "openzeppelin-contracts/proxy/transparent/ProxyAdmin.sol";
import {IERC20MetadataUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {AuraAvatarTwoToken, TokenAmount} from "../../src/aura/AuraAvatarTwoToken.sol";
import {AuraAvatarUtils} from "../../src/aura/AuraAvatarUtils.sol";
import {MAX_BPS, PID_80BADGER_20WBTC, PID_40WBTC_40DIGG_20GRAVIAURA} from "../../src/BaseConstants.sol";
import {AuraConstants} from "../../src/aura/AuraConstants.sol";
import {IAsset} from "../../src/interfaces/balancer/IAsset.sol";
import {IBalancerVault, JoinKind} from "../../src/interfaces/balancer/IBalancerVault.sol";
import {IPriceOracle} from "../../src/interfaces/balancer/IPriceOracle.sol";
import {IBaseRewardPool} from "../../src/interfaces/aura/IBaseRewardPool.sol";
import {IAggregatorV3} from "../../src/interfaces/chainlink/IAggregatorV3.sol";

import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract AuraAvatarTwoTokenTest is Test, AuraAvatarUtils {
    AuraAvatarTwoToken avatar;

    IERC20MetadataUpgradeable constant BPT_80BADGER_20WBTC =
        IERC20MetadataUpgradeable(0xb460DAa847c45f1C4a41cb05BFB3b51c92e41B36);
    IERC20MetadataUpgradeable constant BPT_40WBTC_40DIGG_20GRAVIAURA =
        IERC20MetadataUpgradeable(0x8eB6c82C3081bBBd45DcAC5afA631aaC53478b7C);

    IBaseRewardPool constant BASE_REWARD_POOL_80BADGER_20WBTC =
        IBaseRewardPool(0x05df1E87f41F793D9e03d341Cdc315b76595654C);
    IBaseRewardPool constant BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA =
        IBaseRewardPool(0xe86f0312b06126855810B4a13a43c3E2b1B8DD90);

    address constant owner = address(1);
    address constant manager = address(2);
    address constant keeper = address(3);

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

    event ManagerUpdated(address indexed oldManager, address indexed newManager);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);

    event TwapPeriodUpdated(uint256 newTwapPeriod, uint256 oldTwapPeriod);
    event ClaimFrequencyUpdated(uint256 oldClaimFrequency, uint256 newClaimFrequency);

    event SellBpsBalToUsdcUpdated(uint256 oldValue, uint256 newValue);
    event SellBpsAuraToUsdcUpdated(uint256 oldValue, uint256 newValue);

    event MinOutBpsBalToUsdcMinUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsAuraToUsdcMinUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsBalToBptMinUpdated(uint256 oldValue, uint256 newValue);

    event MinOutBpsBalToUsdcValUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsAuraToUsdcValUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsBalToBptValUpdated(uint256 oldValue, uint256 newValue);

    event Deposit(address indexed token, uint256 amount, uint256 timestamp);
    event Withdraw(address indexed token, uint256 amount, uint256 timestamp);

    event RewardClaimed(address indexed token, uint256 amount, uint256 timestamp);
    event RewardsToStable(address indexed token, uint256 amount, uint256 timestamp);

    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        // TODO: Remove hardcoded block
        vm.createSelectFork("mainnet", 15617600);

        // Labels
        vm.label(address(AURA), "AURA");
        vm.label(address(BAL), "BAL");
        vm.label(address(WETH), "WETH");
        vm.label(address(USDC), "USDC");
        vm.label(address(AURABAL), "AURABAL");
        vm.label(address(BPT_80BAL_20WETH), "BPT_80BAL_20WETH");

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
        assertEq(bpsVal, 9750);
        assertEq(bpsMin, 9000);

        (bpsVal, bpsMin) = avatar.minOutBpsAuraToUsdc();
        assertEq(bpsVal, 9750);
        assertEq(bpsMin, 9000);

        (bpsVal, bpsMin) = avatar.minOutBpsBalToBpt();
        assertEq(bpsVal, 9950);
        assertEq(bpsMin, 9000);
    }

    function test_proxy_immutables() public {
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        address logic = address(new AuraAvatarTwoToken(PID_80BADGER_20WBTC, PID_40WBTC_40DIGG_20GRAVIAURA));
        bytes memory initData = abi.encodeCall(AuraAvatarTwoToken.initialize, (owner, manager, keeper));
        AuraAvatarTwoToken avatarProxy =
            AuraAvatarTwoToken(address(new TransparentUpgradeableProxy(logic, address(proxyAdmin), initData)));

        assertEq(avatarProxy.pid1(), PID_80BADGER_20WBTC);
        assertEq(avatarProxy.pid2(), PID_40WBTC_40DIGG_20GRAVIAURA);

        assertEq(address(avatarProxy.asset1()), address(BPT_80BADGER_20WBTC));
        assertEq(address(avatarProxy.asset2()), address(BPT_40WBTC_40DIGG_20GRAVIAURA));

        assertEq(address(avatarProxy.baseRewardPool1()), address(BASE_REWARD_POOL_80BADGER_20WBTC));
        assertEq(address(avatarProxy.baseRewardPool2()), address(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA));
    }

    function test_initialize_double() public {
        vm.expectRevert("Initializable: contract is already initialized");
        avatar.initialize(address(this), address(this), address(this));
    }

    function test_pendingRewards() public {
        (uint256 pendingBal, uint256 pendingAura) = avatar.pendingRewards();

        assertEq(pendingBal, BASE_REWARD_POOL_80BADGER_20WBTC.earned(address(avatar)));
        assertEq(pendingAura, BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.earned(address(avatar)));
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
            vm.stopPrank();

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
        vm.expectEmit(true, true, false, false);
        emit ManagerUpdated(address(this), manager);
        avatar.setManager(address(this));

        assertEq(avatar.manager(), address(this));
    }

    function test_setManager_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setManager(address(0));
    }

    function test_setKeeper() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit KeeperUpdated(address(this), keeper);
        avatar.setKeeper(address(this));

        assertEq(avatar.keeper(), address(this));
    }

    function test_setKeeper_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setKeeper(address(0));
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
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.ZeroTwapPeriod.selector));
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

    function test_setSellBpsBalToUsdc() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit SellBpsBalToUsdcUpdated(5000, 7000);
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
        vm.expectEmit(false, false, false, true);
        emit SellBpsAuraToUsdcUpdated(5000, 3000);
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
        vm.expectEmit(false, false, false, true);
        emit MinOutBpsBalToUsdcMinUpdated(5000, 9000);
        avatar.setMinOutBpsBalToUsdcMin(5000);

        (, uint256 val) = avatar.minOutBpsBalToUsdc();
        assertEq(val, 5000);
    }

    function test_setMinOutBpsBalToUsdcMin_invalidValues() external {
        vm.startPrank(owner);
        avatar.setMinOutBpsBalToUsdcVal(9500);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToUsdcMin(1000000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.MoreThanBpsVal.selector, 9600, 9500));
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

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsAuraToUsdcMin(1000000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.MoreThanBpsVal.selector, 9600, 9500));
        avatar.setMinOutBpsAuraToUsdcMin(9600);
    }

    function test_setMinOutBpsAuraToUsdcMin_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setMinOutBpsAuraToUsdcMin(5000);
    }

    function test_setMinOutBpsBalToBptMin() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit MinOutBpsBalToBptMinUpdated(5000, 9000);
        avatar.setMinOutBpsBalToBptMin(5000);

        (, uint256 val) = avatar.minOutBpsBalToBpt();
        assertEq(val, 5000);
    }

    function test_setMinOutBpsBalToBptMin_invalidValues() external {
        vm.startPrank(owner);
        avatar.setMinOutBpsBalToBptVal(9500);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToBptMin(1000000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.MoreThanBpsVal.selector, 9600, 9500));
        avatar.setMinOutBpsBalToBptMin(9600);
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

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToUsdcVal(1000000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.LessThanBpsMin.selector, 1000, 9000));
        avatar.setMinOutBpsBalToUsdcVal(1000);
    }

    function test_setMinOutBpsBalToUsdcVal_permissions() external {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotOwnerOrManager.selector, (address(this))));
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

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsAuraToUsdcVal(1000000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.LessThanBpsMin.selector, 1000, 9000));
        avatar.setMinOutBpsAuraToUsdcVal(1000);
    }

    function test_setMinOutBpsAuraToUsdcVal_permissions() external {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotOwnerOrManager.selector, address(this)));
        avatar.setMinOutBpsAuraToUsdcVal(9100);
    }

    function test_setMinOutBpsBalToBptVal() external {
        uint256 val;

        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit MinOutBpsBalToBptValUpdated(9100, 9950);
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

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.InvalidBps.selector, 1000000));
        avatar.setMinOutBpsBalToBptVal(1000000);

        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.LessThanBpsMin.selector, 1000, 9000));
        avatar.setMinOutBpsBalToBptVal(1000);
    }

    function test_setMinOutBpsBalToBptVal_permissions() external {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotOwnerOrManager.selector, (address(this))));
        avatar.setMinOutBpsBalToBptVal(9100);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Owner
    ////////////////////////////////////////////////////////////////////////////

    function test_deposit() public {
        // Deposit both assets
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Deposit(address(BPT_80BADGER_20WBTC), 10e18, block.timestamp);
        vm.expectEmit(true, false, false, true);
        emit Deposit(address(BPT_40WBTC_40DIGG_20GRAVIAURA), 10e18, block.timestamp);
        avatar.deposit(10e18, 10e18);

        assertEq(BPT_80BADGER_20WBTC.balanceOf(owner), 0);
        assertEq(BPT_40WBTC_40DIGG_20GRAVIAURA.balanceOf(owner), 10e18);

        assertEq(BASE_REWARD_POOL_80BADGER_20WBTC.balanceOf(address(avatar)), 10e18);
        assertEq(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.balanceOf(address(avatar)), 10e18);

        // lastClaimTimestamp matches current timestamp since it is the first deposit
        // NOTE: Trick solidity compiler into not optimizing this
        uint256 initialTimestamp = block.timestamp * 1;

        assertEq(avatar.lastClaimTimestamp(), initialTimestamp);

        // Advancing in time
        skip(1 hours);

        // Single asset deposit
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Deposit(address(BPT_40WBTC_40DIGG_20GRAVIAURA), 10e18, block.timestamp);
        avatar.deposit(0, 10e18);

        assertEq(BPT_40WBTC_40DIGG_20GRAVIAURA.balanceOf(owner), 0);

        assertEq(BASE_REWARD_POOL_80BADGER_20WBTC.balanceOf(address(avatar)), 10e18);
        assertEq(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.balanceOf(address(avatar)), 20e18);

        // lastClaimTimestamp is not set after further deposits
        assertFalse(avatar.lastClaimTimestamp() == block.timestamp);
        assertEq(avatar.lastClaimTimestamp(), initialTimestamp);
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

        (uint256 asset1Amount, uint256 asset2Amount) = avatar.totalAssets();
        assertEq(asset1Amount, 10e18);
        assertEq(asset2Amount, 20e18);
    }

    function test_withdrawAll() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Withdraw(address(BPT_80BADGER_20WBTC), 10e18, block.timestamp);
        vm.expectEmit(true, false, false, true);
        emit Withdraw(address(BPT_40WBTC_40DIGG_20GRAVIAURA), 20e18, block.timestamp);
        avatar.withdrawAll();

        assertEq(BASE_REWARD_POOL_80BADGER_20WBTC.balanceOf(address(avatar)), 0);
        assertEq(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.balanceOf(address(avatar)), 0);

        assertEq(BPT_80BADGER_20WBTC.balanceOf(owner), 10e18);
        assertEq(BPT_40WBTC_40DIGG_20GRAVIAURA.balanceOf(owner), 20e18);
    }

    function test_withdrawAll_nothing() public {
        vm.expectRevert(AuraAvatarTwoToken.NothingToWithdraw.selector);
        vm.prank(owner);
        avatar.withdrawAll();
    }

    function test_withdrawAll_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.withdrawAll();
    }

    function test_withdraw() public {
        vm.startPrank(owner);
        avatar.deposit(10e18, 20e18);

        vm.expectEmit(true, false, false, true);
        emit Withdraw(address(BPT_80BADGER_20WBTC), 10e18, block.timestamp);
        vm.expectEmit(true, false, false, true);
        emit Withdraw(address(BPT_40WBTC_40DIGG_20GRAVIAURA), 20e18, block.timestamp);
        avatar.withdraw(10e18, 20e18);

        assertEq(BPT_80BADGER_20WBTC.balanceOf(owner), 10e18);
        assertEq(BPT_40WBTC_40DIGG_20GRAVIAURA.balanceOf(owner), 20e18);
    }

    function test_withdraw_nothing() public {
        vm.expectRevert(AuraAvatarTwoToken.NothingToWithdraw.selector);
        vm.prank(owner);
        avatar.withdraw(0, 0);
    }

    function test_withdraw_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.withdraw(10e18, 20e18);
    }

    function test_claimRewardsAndSendToOwner() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        uint256 initialOwnerBal = BAL.balanceOf(owner);
        uint256 initialOwnerAura = AURA.balanceOf(owner);

        skip(1 hours);

        uint256 balReward1 = BASE_REWARD_POOL_80BADGER_20WBTC.earned(address(avatar));
        uint256 balReward2 = BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.earned(address(avatar));

        uint256 auraReward = getMintableAuraForBalAmount(balReward1 + balReward2);

        assertGt(balReward1, 0);
        assertGt(balReward2, 0);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit RewardClaimed(address(BAL), balReward1 + balReward2, block.timestamp);
        vm.expectEmit(true, false, false, true);
        emit RewardClaimed(address(AURA), auraReward, block.timestamp);
        avatar.claimRewardsAndSendToOwner();

        assertEq(BASE_REWARD_POOL_80BADGER_20WBTC.earned(address(avatar)), 0);
        assertEq(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.earned(address(avatar)), 0);

        assertEq(BAL.balanceOf(address(avatar)), 0);
        assertEq(AURA.balanceOf(address(avatar)), 0);

        assertEq(BAL.balanceOf(owner) - initialOwnerBal, balReward1 + balReward2);
        assertEq(AURA.balanceOf(owner) - initialOwnerAura, auraReward);
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

    function checked_processRewards(uint256 _auraPriceInUsd) internal {
        (,, uint256 voterBalanceBefore,) = AURA_LOCKER.lockedBalances(BADGER_VOTER);
        uint256 bauraBalBalanceBefore = BAURABAL.balanceOf(owner);
        uint256 usdcBalanceBefore = USDC.balanceOf(owner);

        assertGt(BASE_REWARD_POOL_80BADGER_20WBTC.earned(address(avatar)), 0);
        assertGt(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.earned(address(avatar)), 0);

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
            assertEq(processed[2].token, address(BAURABAL));

            assertGt(processed[0].amount, 0);
            assertGt(processed[1].amount, 0);
            assertGt(processed[2].amount, 0);

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

    function test_processRewards() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        skipAndForwardFeeds(1 hours);

        (, uint256 pendingAura) = avatar.pendingRewards();
        checked_processRewards(getAuraPriceInUsdSpot(pendingAura));
    }

    function test_processRewards_noAuraPrice() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        skipAndForwardFeeds(1 hours);

        checked_processRewards(0);
    }

    function test_processRewards_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(AuraAvatarTwoToken.NotOwnerOrManager.selector, address(this)));
        avatar.processRewards(0);
    }

    function test_processRewards_noRewards() public {
        vm.expectRevert(AuraAvatarTwoToken.NoRewards.selector);
        vm.prank(owner);
        avatar.processRewards(0);
    }

    function test_processRewards_highAuraPrice() public {
        vm.startPrank(owner);
        avatar.deposit(10e18, 20e18);

        skipAndForwardFeeds(1 hours);

        (, uint256 pendingAura) = avatar.pendingRewards();
        uint256 auraPriceInUsd = getAuraPriceInUsdSpot(pendingAura);

        vm.expectRevert("BAL#507");
        avatar.processRewards(2 * auraPriceInUsd);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Keeper
    ////////////////////////////////////////////////////////////////////////////

    function test_checkUpkeep() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        skip(1 weeks);

        (bool upkeepNeeded, bytes memory performData) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        uint256 auraPriceInUsd = abi.decode(performData, (uint256));
        assertGt(auraPriceInUsd, 0);
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

        (,, uint256 voterBalanceBefore,) = AURA_LOCKER.lockedBalances(BADGER_VOTER);
        uint256 bauraBalBalanceBefore = BAURABAL.balanceOf(owner);
        uint256 usdcBalanceBefore = USDC.balanceOf(owner);

        skipAndForwardFeeds(1 weeks);

        bool upkeepNeeded;
        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        vm.prank(keeper);
        vm.expectEmit(false, false, false, false);
        emit RewardsToStable(address(USDC), 0, block.timestamp);
        avatar.performUpkeep(abi.encodeCall(AuraAvatarTwoToken.processRewardsKeeper, uint256(0)));

        // Ensure that rewards were processed properly
        assertEq(BASE_REWARD_POOL_80BADGER_20WBTC.earned(address(avatar)), 0);
        assertEq(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.earned(address(avatar)), 0);

        assertEq(BAL.balanceOf(address(avatar)), 0);
        assertEq(AURA.balanceOf(address(avatar)), 0);

        (,, uint256 voterBalanceAfter,) = AURA_LOCKER.lockedBalances(BADGER_VOTER);
        assertGt(voterBalanceAfter, voterBalanceBefore);
        assertGt(BAURABAL.balanceOf(owner), bauraBalBalanceBefore);
        assertGt(USDC.balanceOf(owner), usdcBalanceBefore);

        // Upkeep is not needed anymore
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
                AuraAvatarTwoToken.TooSoon.selector,
                block.timestamp,
                avatar.lastClaimTimestamp(),
                avatar.claimFrequency()
            )
        );
        vm.prank(keeper);
        avatar.performUpkeep(abi.encodeCall(AuraAvatarTwoToken.processRewardsKeeper, uint256(0)));
    }

    function test_performUpkeep_staleFeed() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        skip(1 weeks);
        vm.expectRevert(
            abi.encodeWithSelector(
                AuraAvatarUtils.StalePriceFeed.selector, block.timestamp, BAL_USD_FEED.latestTimestamp(), 24 hours
            )
        );
        vm.prank(keeper);
        avatar.performUpkeep(abi.encodeCall(AuraAvatarTwoToken.processRewardsKeeper, uint256(0)));
    }

    ////////////////////////////////////////////////////////////////////////////
    // MISC
    ////////////////////////////////////////////////////////////////////////////

    function test_getBptPriceInBal() public {
        uint256 clPrice = getBptPriceInBal();
        uint256 spotPrice = IPriceOracle(address(BPT_80BAL_20WETH)).getLatest(IPriceOracle.Variable.BPT_PRICE);

        // CL price is within 1% of spot price
        assertApproxEqRel(clPrice, spotPrice, 0.01e18);
    }

    function test_getAuraPriceInUsdSpot() public {
        vm.startPrank(owner);
        avatar.deposit(10e18, 20e18);

        skipAndForwardFeeds(1 hours);

        (, uint256 pendingAura) = avatar.pendingRewards();

        uint256 spotPrice = getAuraPriceInUsdSpot(pendingAura) / 1e2;
        uint256 twapPrice = getAuraAmountInUsdc(1e18, 1 hours);

        // Spot price is within 2.5% of TWAP
        assertApproxEqRel(spotPrice, twapPrice, 0.025e18);
    }

    function test_debug() public {
        console.log(getBalAmountInUsdc(1e18));
        console.log(getAuraAmountInUsdc(1e18, avatar.twapPeriod()));

        console.log(getBptPriceInBal());

        vm.startPrank(owner);
        avatar.deposit(10e18, 20e18);

        skip(1 hours);
        (, uint256 pendingAura) = avatar.pendingRewards();
        console.log(getAuraPriceInUsdSpot(pendingAura));
    }

    function test_processRewards_highBalMinBps() public {
        vm.startPrank(owner);
        avatar.deposit(10e18, 20e18);

        skip(1 hours);

        avatar.setMinOutBpsBalToUsdcVal(MAX_BPS);

        vm.expectRevert("BAL#507");
        avatar.processRewards(0);
    }

    // TODO: This might not revert, maybe remove?
    function test_processRewards_highAuraMinBps() public {
        vm.startPrank(owner);
        avatar.deposit(10e18, 20e18);

        skipAndForwardFeeds(1 hours);

        avatar.setMinOutBpsAuraToUsdcVal(MAX_BPS);

        vm.expectRevert("BAL#507");
        avatar.processRewards(0);
    }

    function test_processRewards_aurabalDeposit() public {
        (, uint256[] memory balances,) = BALANCER_VAULT.getPoolTokens(AURABAL_BAL_WETH_POOL_ID);

        uint256 totalSupplyBefore = AURABAL.totalSupply();

        if (balances[1] > balances[0]) {
            uint256 bptAmount = 2 * (balances[1] - balances[0]);

            deal(address(BPT_80BAL_20WETH), address(this), bptAmount, true);
            BPT_80BAL_20WETH.approve(address(BALANCER_VAULT), bptAmount);

            IAsset[] memory assetArray = new IAsset[](2);
            assetArray[0] = IAsset(address(BPT_80BAL_20WETH));
            assetArray[1] = IAsset(address(AURABAL));

            uint256[] memory maxAmountsIn = new uint256[](2);
            maxAmountsIn[0] = bptAmount;
            maxAmountsIn[1] = 0;

            BALANCER_VAULT.joinPool(
                AURABAL_BAL_WETH_POOL_ID,
                address(this),
                address(this),
                IBalancerVault.JoinPoolRequest({
                    assets: assetArray,
                    maxAmountsIn: maxAmountsIn,
                    userData: abi.encode(JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT, maxAmountsIn, 0),
                    fromInternalBalance: false
                })
            );
        }

        vm.startPrank(owner);
        avatar.deposit(10e18, 20e18);

        skipAndForwardFeeds(1 hours);

        // auraBAL is minted since trading for it is not efficient
        vm.expectEmit(true, true, false, false);
        emit Transfer(address(0), address(avatar), 0);
        avatar.processRewards(0);

        // Confirm minting of auraBAL by checking increase in totalSupply
        assertGt(AURABAL.totalSupply(), totalSupplyBefore);
    }

    function test_upkeep() public {
        vm.prank(owner);
        avatar.deposit(10e18, 20e18);

        skipAndForwardFeeds(1 weeks);

        (bool upkeepNeeded, bytes memory performData) = avatar.checkUpkeep(new bytes(0));
        uint256 auraPriceInUsd = abi.decode(performData, (uint256));

        assertTrue(upkeepNeeded);
        assertGt(auraPriceInUsd, 0);

        vm.prank(keeper);
        avatar.performUpkeep(performData);
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
}
