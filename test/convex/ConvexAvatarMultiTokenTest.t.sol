// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "openzeppelin-contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "openzeppelin-contracts/proxy/transparent/ProxyAdmin.sol";
import {IERC20MetadataUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {ConvexAvatarMultiToken, TokenAmount} from "../../src/convex/ConvexAvatarMultiToken.sol";
import {BaseAvatarUtils} from "../../src/BaseAvatarUtils.sol";
import {ConvexAvatarUtils} from "../../src/convex/ConvexAvatarUtils.sol";
import {MAX_BPS, CHAINLINK_KEEPER_REGISTRY} from "../../src/BaseConstants.sol";

import {IBaseRewardPool} from "../../src/interfaces/aura/IBaseRewardPool.sol";
import {IStakingProxy} from "../../src/interfaces/convex/IStakingProxy.sol";
import {IFraxUnifiedFarm} from "../../src/interfaces/convex/IFraxUnifiedFarm.sol";
import {IAggregatorV3} from "../../src/interfaces/chainlink/IAggregatorV3.sol";

import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract ConvexAvatarMultiTokenTest is Test, ConvexAvatarUtils {
    ConvexAvatarMultiToken avatar;

    // Convex
    uint256 constant CONVEX_PID_BADGER_WBTC = 74;
    uint256 constant CONVEX_PID_BADGER_FRAXBP = 35;

    IERC20MetadataUpgradeable constant CURVE_LP_BADGER_WBTC =
        IERC20MetadataUpgradeable(0x137469B55D1f15651BA46A89D0588e97dD0B6562);
    IERC20MetadataUpgradeable constant CURVE_LP_BADGER_FRAXBP =
        IERC20MetadataUpgradeable(0x09b2E090531228d1b8E3d948C73b990Cb6e60720);
    IERC20MetadataUpgradeable constant WCVX_BADGER_FRAXBP =
        IERC20MetadataUpgradeable(0xb92e3fD365Fc5E038aa304Afe919FeE158359C88);
    IERC20MetadataUpgradeable constant CURVE_LP_SILO_FRAX =
        IERC20MetadataUpgradeable(0x2302aaBe69e6E7A1b0Aa23aAC68fcCB8A4D2B460);

    IBaseRewardPool constant BASE_REWARD_POOL_BADGER_WBTC = IBaseRewardPool(0x36c7E7F9031647A74687ce46A8e16BcEA84f3865);
    IBaseRewardPool constant BASE_REWARD_POOL_SILO_FRAX = IBaseRewardPool(0xE259d085f55825624bBA8571eD20984c125Ba720);
    IFraxUnifiedFarm constant UNIFIED_FARM_BADGER_FRAXBP = IFraxUnifiedFarm(0x5a92EF27f4baA7C766aee6d751f754EBdEBd9fae);

    // Token to test sweep
    IERC20MetadataUpgradeable constant BADGER = IERC20MetadataUpgradeable(0x3472A5A71965499acd81997a54BBA8D852C6E53d);

    address constant owner = address(1);
    address constant manager = address(2);
    address constant keeper = CHAINLINK_KEEPER_REGISTRY;
    address constant BADGER_WHALE = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    address[2] assetsExpected = [address(CURVE_LP_BADGER_WBTC), address(WCVX_BADGER_FRAXBP)];

    // vanilla convex vars
    uint256[1] VANILLA_PIDS = [CONVEX_PID_BADGER_WBTC];
    IERC20MetadataUpgradeable[1] CURVE_LPS = [CURVE_LP_BADGER_WBTC];
    IBaseRewardPool[1] BASE_REWARD_POOLS = [BASE_REWARD_POOL_BADGER_WBTC];

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

    event ManagerUpdated(address indexed oldManager, address indexed newManager);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);

    event ClaimFrequencyUpdated(uint256 oldClaimFrequency, uint256 newClaimFrequency);

    event MinOutBpsValUpdated(address tokenA, address tokenB, uint256 oldValue, uint256 newValue);
    event MinOutBpsMinUpdated(address tokenA, address tokenB, uint256 oldValue, uint256 newValue);

    event Deposit(address indexed token, uint256 amount, uint256 timestamp);
    event Withdraw(address indexed token, uint256 amount, uint256 timestamp);

    event RewardClaimed(address indexed token, uint256 amount, uint256 timestamp);
    event RewardsToStable(address indexed token, uint256 amount, uint256 timestamp);

    event ERC20Swept(address indexed token, uint256 amount);

    function setUp() public {
        // NOTE: pin a block where all required contracts already has being deployed
        vm.createSelectFork("mainnet", 16084000);

        // Labels
        vm.label(address(FXS), "FXS");
        vm.label(address(CRV), "CRV");
        vm.label(address(CVX), "CVX");
        vm.label(address(DAI), "DAI");
        vm.label(address(FRAX), "FRAX");
        vm.label(address(WETH), "WETH");
        vm.label(address(BADGER), "BADGER");

        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;

        uint256[] memory pidsFraxInit = new uint256[](1);
        pidsFraxInit[0] = CONVEX_PID_BADGER_FRAXBP;

        avatar = new ConvexAvatarMultiToken();
        avatar.initialize(owner, manager, pidsInit, pidsFraxInit);

        for (uint256 i = 0; i < assetsExpected.length; i++) {
            deal(assetsExpected[i], owner, 20e18, true);
        }

        vm.startPrank(owner);
        CURVE_LP_BADGER_WBTC.approve(address(avatar), 20e18);
        WCVX_BADGER_FRAXBP.approve(address(avatar), 20e18);
        vm.stopPrank();
    }

    ////////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////////
    function test_initialize() public {
        assertEq(avatar.owner(), owner);
        assertFalse(avatar.paused());

        assertEq(avatar.manager(), manager);

        uint256 bpsVal;
        uint256 bpsMin;

        (bpsVal, bpsMin) = avatar.minOutBps(address(CRV), address(WETH));
        assertEq(bpsVal, 9850);
        assertEq(bpsMin, 9500);

        (bpsVal, bpsMin) = avatar.minOutBps(address(CVX), address(WETH));
        assertEq(bpsVal, 9850);
        assertEq(bpsMin, 9500);

        (bpsVal, bpsMin) = avatar.minOutBps(address(FXS), address(FRAX));
        assertEq(bpsVal, 9850);
        assertEq(bpsMin, 9500);

        (bpsVal, bpsMin) = avatar.minOutBps(address(WETH), address(DAI));
        assertEq(bpsVal, 9850);
        assertEq(bpsMin, 9500);

        (bpsVal, bpsMin) = avatar.minOutBps(address(FRAX), address(DAI));
        assertEq(bpsVal, 9850);
        assertEq(bpsMin, 9500);

        uint256[] memory pids = avatar.getPids();
        address[] memory curveLps = avatar.getAssets();
        address[] memory baseRewardPools = avatar.getbaseRewardPools();

        for (uint256 i; i < pids.length; ++i) {
            assertEq(pids[i], VANILLA_PIDS[i]);
            assertEq(curveLps[i], address(CURVE_LPS[i]));
            assertEq(baseRewardPools[i], address(BASE_REWARD_POOLS[i]));
        }

        uint256[] memory privateVaultPids = avatar.getPrivateVaultPids();
        address privateVault = avatar.privateVaults(privateVaultPids[0]);

        assertEq(privateVaultPids[0], CONVEX_PID_BADGER_FRAXBP);
        assertEq(privateVault, CONVEX_FRAX_REGISTRY.vaultMap(CONVEX_PID_BADGER_FRAXBP, address(avatar)));

        // allowance checks
        assertEq(CRV.allowance(address(avatar), address(CRV_ETH_CURVE_POOL)), type(uint256).max);
        assertEq(CVX.allowance(address(avatar), address(CVX_ETH_CURVE_POOL)), type(uint256).max);
        assertEq(FRAX.allowance(address(avatar), address(FRAX_3CRV_CURVE_POOL)), type(uint256).max);
        assertEq(FXS.allowance(address(avatar), address(FRAXSWAP_ROUTER)), type(uint256).max);
        assertEq(WETH.allowance(address(avatar), address(UNIV3_ROUTER)), type(uint256).max);
    }

    function test_proxy_vars() public {
        ProxyAdmin proxyAdmin = new ProxyAdmin();

        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;

        uint256[] memory pidsFraxInit = new uint256[](1);
        pidsFraxInit[0] = CONVEX_PID_BADGER_FRAXBP;

        address logic = address(new ConvexAvatarMultiToken());

        bytes memory initData =
            abi.encodeCall(ConvexAvatarMultiToken.initialize, (owner, manager, pidsInit, pidsFraxInit));

        ConvexAvatarMultiToken avatarProxy = ConvexAvatarMultiToken(
            address(
                new TransparentUpgradeableProxy(
                    logic,
                    address(proxyAdmin),
                    initData
                )
            )
        );

        uint256[] memory pids = avatarProxy.getPids();
        address[] memory curveLps = avatarProxy.getAssets();
        address[] memory baseRewardPools = avatarProxy.getbaseRewardPools();

        for (uint256 i; i < pids.length; ++i) {
            assertEq(pids[i], VANILLA_PIDS[i]);
            assertEq(curveLps[i], address(CURVE_LPS[i]));
            assertEq(baseRewardPools[i], address(BASE_REWARD_POOLS[i]));
        }

        uint256[] memory privateVaultPids = avatarProxy.getPrivateVaultPids();
        address privateVault = avatarProxy.privateVaults(privateVaultPids[0]);

        assertEq(privateVaultPids[0], CONVEX_PID_BADGER_FRAXBP);
        assertEq(privateVault, CONVEX_FRAX_REGISTRY.vaultMap(CONVEX_PID_BADGER_FRAXBP, address(avatarProxy)));

        // allowance checks
        assertEq(CRV.allowance(address(avatarProxy), address(CRV_ETH_CURVE_POOL)), type(uint256).max);
        assertEq(CVX.allowance(address(avatarProxy), address(CVX_ETH_CURVE_POOL)), type(uint256).max);
        assertEq(FRAX.allowance(address(avatarProxy), address(FRAX_3CRV_CURVE_POOL)), type(uint256).max);
        assertEq(FXS.allowance(address(avatarProxy), address(FRAXSWAP_ROUTER)), type(uint256).max);
        assertEq(WETH.allowance(address(avatarProxy), address(UNIV3_ROUTER)), type(uint256).max);
    }

    function test_initialize_double() public {
        vm.expectRevert("Initializable: contract is already initialized");
        uint256[] memory pids;
        uint256[] memory fraxPids;
        avatar.initialize(address(this), address(this), pids, fraxPids);
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
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.NotOwnerOrManager.selector, (address(this))));
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

    function test_addCurveLp_position_info_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.addCurveLpPositionInfo(21);
    }

    function test_addCurveLp_position_info() public {
        // NOTE: use to track if length increased after adding in these sets
        address[] memory beforeAvatarAssets = avatar.getAssets();
        address[] memory beforeAvatarRewardPools = avatar.getbaseRewardPools();

        vm.prank(owner);
        avatar.addCurveLpPositionInfo(78);

        uint256[] memory avatarPids = avatar.getPids();
        address[] memory afterAvatarAssets = avatar.getAssets();
        address[] memory afterAvatarRewardPools = avatar.getbaseRewardPools();
        bool pidIsAdded;

        for (uint256 i = 0; i < avatarPids.length; i++) {
            if (avatarPids[i] == 78) {
                pidIsAdded = true;
                // NOTE: verify lptoken & base reward contract addresses save on set storage
                assertEq(afterAvatarAssets[i], address(CURVE_LP_SILO_FRAX));
                assertEq(afterAvatarRewardPools[i], address(BASE_REWARD_POOL_SILO_FRAX));
                break;
            }
        }

        assertTrue(pidIsAdded);
        assertGt(afterAvatarAssets.length, beforeAvatarAssets.length);
        assertGt(afterAvatarRewardPools.length, beforeAvatarRewardPools.length);
    }

    function test_addCurveLp_position_already_exists() public {
        vm.prank(owner);
        avatar.addCurveLpPositionInfo(21);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.PidAlreadyExist.selector, 21));
        avatar.addCurveLpPositionInfo(21);
    }

    function test_removeCurveLp_position_info_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.removeCurveLpPositionInfo(21);
    }

    function test_removeCurveLp_position_info_non_existent() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.PidNotIncluded.selector, 120));
        avatar.removeCurveLpPositionInfo(120);
    }

    function test_removeCurveLp_position_info_still_staked() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        vm.expectRevert(
            abi.encodeWithSelector(
                ConvexAvatarMultiToken.CurveLpStillStaked.selector,
                address(CURVE_LP_BADGER_WBTC),
                address(BASE_REWARD_POOL_BADGER_WBTC),
                20 ether
            )
        );
        vm.prank(owner);
        avatar.removeCurveLpPositionInfo(CONVEX_PID_BADGER_WBTC);
    }

    function test_removeCurveLp_position_claiming_reward() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skip(1 weeks);

        vm.prank(owner);
        avatar.withdraw(pidsInit, amountsDeposit);

        uint256 initialAvatarCrv = CRV.balanceOf(address(avatar));
        uint256 initialAvatarCvx = CVX.balanceOf(address(avatar));

        assertEq(initialAvatarCvx, 0);
        assertEq(initialAvatarCrv, 0);

        vm.prank(owner);
        avatar.removeCurveLpPositionInfo(CONVEX_PID_BADGER_WBTC);

        assertGt(CRV.balanceOf(address(avatar)), 0);
        assertGt(CVX.balanceOf(address(avatar)), 0);
    }

    function test_removeCurveLp_position_info() public {
        vm.prank(owner);
        avatar.removeCurveLpPositionInfo(CONVEX_PID_BADGER_WBTC);

        uint256[] memory avatarPids = avatar.getPids();

        bool pidIsPresent;

        for (uint256 i = 0; i < avatarPids.length; i++) {
            if (avatarPids[i] == CONVEX_PID_BADGER_WBTC) {
                pidIsPresent = true;
            }
        }

        assertFalse(pidIsPresent);
    }

    function test_sweep() public {
        vm.prank(owner);

        // NOTE: getting via deal `[FAIL. Reason: stdStorage find(StdStorage): Slot(s) not found.]`
        // deal(address(BADGER), address(avatar), 500 ether, true);

        uint256 ownerBalBefore = BADGER.balanceOf(owner);

        vm.prank(BADGER_WHALE);
        BADGER.transfer(address(avatar), 1 ether);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit ERC20Swept(address(BADGER), 1 ether);
        avatar.sweep(address(BADGER));

        assertGt(BADGER.balanceOf(owner), ownerBalBefore);
        assertEq(BADGER.balanceOf(address(avatar)), 0);
    }

    function test_sweep_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.sweep(address(BADGER));
    }

    function test_setMinOutBpsMin() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit MinOutBpsMinUpdated(address(CRV), address(WETH), 9500, 5000);
        avatar.setMinOutBpsMin(address(CRV), address(WETH), 5000);

        (, uint256 min) = avatar.minOutBps(address(CRV), address(WETH));
        assertEq(min, 5000);
    }

    function test_setMinOutBpsMin_invalidValues() public {
        vm.startPrank(owner);

        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.InvalidBps.selector, 60000));
        avatar.setMinOutBpsMin(address(CRV), address(WETH), 60000);

        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.MoreThanBpsVal.selector, 9950, 9850));
        avatar.setMinOutBpsMin(address(CRV), address(WETH), 9950);
    }

    function test_setMinOutBpsMin_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.setMinOutBpsMin(address(CRV), address(WETH), 5000);
    }

    ////////////////////////////////////////////////////////////////////////////
    // Config: Manager/Owner
    ////////////////////////////////////////////////////////////////////////////

    function test_setMinOutBpsVal() external {
        uint256 val;

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit MinOutBpsValUpdated(address(CRV), address(WETH), 9850, 9600);
        avatar.setMinOutBpsVal(address(CRV), address(WETH), 9600);
        (val,) = avatar.minOutBps(address(CRV), address(WETH));
        assertEq(val, 9600);

        vm.prank(manager);
        avatar.setMinOutBpsVal(address(CRV), address(WETH), 9820);
        (val,) = avatar.minOutBps(address(CRV), address(WETH));
        assertEq(val, 9820);
    }

    function test_setMinOutBpsVal_invalidValues() external {
        vm.startPrank(owner);
        avatar.setMinOutBpsVal(address(CRV), address(WETH), 9700);

        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.InvalidBps.selector, 60000));
        avatar.setMinOutBpsVal(address(CRV), address(WETH), 60000);

        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.LessThanBpsMin.selector, 1000, 9500));
        avatar.setMinOutBpsVal(address(CRV), address(WETH), 1000);
    }

    function test_setMinOutBpsVal_permissions() external {
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.NotOwnerOrManager.selector, (address(this))));
        avatar.setMinOutBpsVal(address(CRV), address(WETH), 9600);
    }

    function test_processRewards() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        uint256 daiBalanceBefore = DAI.balanceOf(owner);

        skipAndForwardFeeds(1 hours);

        address[2] memory actors = [owner, manager];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.prank(actors[i]);
            vm.expectEmit(false, false, false, false);
            emit RewardsToStable(address(DAI), 0, block.timestamp);
            TokenAmount[] memory processed = avatar.processRewards();

            assertEq(processed[0].token, address(DAI));
            assertGt(processed[0].amount, 0);

            assertEq(CRV.balanceOf(address(avatar)), 0);
            assertEq(CVX.balanceOf(address(avatar)), 0);
            assertEq(FXS.balanceOf(address(avatar)), 0);

            assertGt(DAI.balanceOf(owner), daiBalanceBefore);

            vm.revertTo(snapId);
        }
    }

    function test_processRewards_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.NotOwnerOrManager.selector, address(this)));
        avatar.processRewards();
    }

    function test_processRewards_noRewards() public {
        vm.prank(owner);
        vm.expectRevert(ConvexAvatarMultiToken.NoRewards.selector);
        avatar.processRewards();
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Owner
    ////////////////////////////////////////////////////////////////////////////

    function test_createPrivateVault() public {
        vm.prank(owner);
        avatar.createPrivateVault(28);

        uint256[] memory privateVaultPids = avatar.getPrivateVaultPids();

        // NOTE: we check 2nd index, since 1st was created in the `initialize`
        assertEq(privateVaultPids[1], 28);
        assertEq(avatar.privateVaults(28), CONVEX_FRAX_REGISTRY.vaultMap(28, address(avatar)));
    }

    function test_createPrivateVault_no_active() public {
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.PoolDeactivated.selector, 5));
        vm.prank(owner);
        avatar.createPrivateVault(5);
    }

    function test_createPrivateVault_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.createPrivateVault(5);
    }

    function test_deposit() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.expectEmit(true, false, false, true);
        emit Deposit(address(CURVE_LP_BADGER_WBTC), 20 ether, block.timestamp);
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        assertEq(CURVE_LP_BADGER_WBTC.balanceOf(owner), 0);
        assertEq(BASE_REWARD_POOL_BADGER_WBTC.balanceOf(address(avatar)), 20e18);
    }

    function test_deposit_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        avatar.deposit(pidsInit, amountsDeposit);
    }

    function test_deposit_empty() public {
        vm.expectRevert(ConvexAvatarMultiToken.NothingToDeposit.selector);
        vm.prank(owner);
        uint256[] memory amountsDeposit = new uint256[](1);
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        avatar.deposit(pidsInit, amountsDeposit);
    }

    function test_deposit_pid_not_in_storage() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = 120;
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.PidNotIncluded.selector, 120));
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);
    }

    function test_deposit_length_mismatch() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        uint256[] memory pidsInit = new uint256[](2);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.LengthMismatch.selector));
        avatar.deposit(pidsInit, amountsDeposit);
    }

    function test_totalAssets() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;

        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);
        vm.prank(owner);
        avatar.depositInPrivateVault(CONVEX_PID_BADGER_FRAXBP, 20 ether, false);

        (uint256[] memory vanillaAssetAmounts, uint256[] memory privateVaultAssetAmounts) = avatar.totalAssets();
        assertEq(vanillaAssetAmounts[0], 20 ether);
        assertEq(privateVaultAssetAmounts[0], 20 ether);
    }

    function test_depositPrivateVault() public {
        uint256 amountToLock = 20 ether;
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Deposit(address(WCVX_BADGER_FRAXBP), amountToLock, block.timestamp);
        bytes32 kekId = avatar.depositInPrivateVault(CONVEX_PID_BADGER_FRAXBP, amountToLock, false);

        address vaultAddr = avatar.privateVaults(CONVEX_PID_BADGER_FRAXBP);
        IStakingProxy proxy = IStakingProxy(vaultAddr);

        uint256 lockedBal = IFraxUnifiedFarm(proxy.stakingAddress()).lockedLiquidityOf(vaultAddr);

        assertEq(lockedBal, amountToLock);
        assertEq(WCVX_BADGER_FRAXBP.balanceOf(owner), 0);
        assertEq(kekId, avatar.kekIds(vaultAddr));
    }

    function test_depositPrivateVault_not_private_vault() public {
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.NoPrivateVaultForPid.selector, 80));
        vm.prank(owner);
        avatar.depositInPrivateVault(80, 20 ether, false);
    }

    function test_depositPrivateVault_additional_funds() public {
        uint256 amountToLock = 10 ether;
        vm.prank(owner);
        avatar.depositInPrivateVault(CONVEX_PID_BADGER_FRAXBP, amountToLock, false);

        // NOTE: ensure moving enough forward more than `lock_time_min`
        skip(3 weeks);

        vm.prank(owner);
        bytes32 kekId = avatar.depositInPrivateVault(CONVEX_PID_BADGER_FRAXBP, amountToLock, true);

        address vaultAddr = avatar.privateVaults(CONVEX_PID_BADGER_FRAXBP);
        IStakingProxy proxy = IStakingProxy(vaultAddr);

        uint256 lockedBal = IFraxUnifiedFarm(proxy.stakingAddress()).lockedLiquidityOf(vaultAddr);

        assertEq(lockedBal, amountToLock * 2);
        assertEq(WCVX_BADGER_FRAXBP.balanceOf(owner), 0);
        assertEq(kekId, avatar.kekIds(vaultAddr));
    }

    function test_depositPrivateVault_additionalFunds_not_lock_initiated() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                ConvexAvatarMultiToken.NoExistingLockInPrivateVault.selector,
                avatar.privateVaults(CONVEX_PID_BADGER_FRAXBP)
            )
        );
        uint256 amountToLock = 10 ether;
        vm.prank(owner);
        avatar.depositInPrivateVault(CONVEX_PID_BADGER_FRAXBP, amountToLock, true);
    }

    function test_depositPrivateVault_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.depositInPrivateVault(CONVEX_PID_BADGER_FRAXBP, 20 ether, false);
    }

    function test_depositPrivateVault_empty() public {
        vm.expectRevert(ConvexAvatarMultiToken.NothingToDeposit.selector);
        vm.prank(owner);
        avatar.depositInPrivateVault(CONVEX_PID_BADGER_FRAXBP, 0, false);
    }

    function test_withdrawAll() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Withdraw(address(CURVE_LP_BADGER_WBTC), 20 ether, block.timestamp);
        avatar.withdrawAll();

        assertEq(BASE_REWARD_POOL_BADGER_WBTC.balanceOf(address(avatar)), 0);
        assertEq(CURVE_LP_BADGER_WBTC.balanceOf(owner), 20e18);
    }

    function test_withdrawAll_nothing() public {
        vm.expectRevert(ConvexAvatarMultiToken.NothingToWithdraw.selector);
        vm.prank(owner);
        avatar.withdrawAll();
    }

    function test_withdrawAll_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.NotOwnerOrManager.selector, keeper));
        vm.prank(keeper);
        avatar.withdrawAll();
    }

    function test_withdraw() public {
        vm.startPrank(owner);
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        avatar.deposit(pidsInit, amountsDeposit);

        vm.expectEmit(true, false, false, true);
        emit Withdraw(address(CURVE_LP_BADGER_WBTC), 10e18, block.timestamp);
        uint256[] memory amountsWithdraw = new uint256[](1);
        amountsWithdraw[0] = 10 ether;
        avatar.withdraw(pidsInit, amountsWithdraw);

        assertEq(BASE_REWARD_POOL_BADGER_WBTC.balanceOf(address(avatar)), 10e18);
        assertEq(CURVE_LP_BADGER_WBTC.balanceOf(owner), 10e18);
    }

    function test_withdraw_emergency_manager() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;

        vm.startPrank(owner);
        avatar.deposit(pidsInit, amountsDeposit);
        vm.stopPrank();

        // NOTE: switch of role to manager, emergency testing!
        vm.startPrank(manager);
        vm.expectEmit(true, false, false, true);
        emit Withdraw(address(CURVE_LP_BADGER_WBTC), 10e18, block.timestamp);
        uint256[] memory amountsWithdraw = new uint256[](1);
        amountsWithdraw[0] = 10 ether;
        avatar.withdraw(pidsInit, amountsWithdraw);

        assertEq(BASE_REWARD_POOL_BADGER_WBTC.balanceOf(address(avatar)), 10e18);
        assertEq(CURVE_LP_BADGER_WBTC.balanceOf(owner), 10e18);
    }

    function test_withdraw_nothing() public {
        uint256[] memory amountsWithdraw = new uint256[](1);
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.expectRevert(ConvexAvatarMultiToken.NothingToWithdraw.selector);
        vm.prank(owner);
        avatar.withdraw(pidsInit, amountsWithdraw);
    }

    function test_withdraw_permissions() public {
        uint256[] memory amountsWithdraw = new uint256[](1);
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.NotOwnerOrManager.selector, keeper));
        vm.prank(keeper);
        avatar.withdraw(pidsInit, amountsWithdraw);
    }

    function test_withdraw_length_mismatch() public {
        uint256[] memory amountsWithdraw = new uint256[](1);
        uint256[] memory pidsInit = new uint256[](2);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.LengthMismatch.selector));
        avatar.withdraw(pidsInit, amountsWithdraw);
    }

    function test_withdrawFromPrivateVault() public {
        vm.prank(owner);
        avatar.depositInPrivateVault(CONVEX_PID_BADGER_FRAXBP, 20 ether, false);

        skip(2 weeks);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Withdraw(address(CURVE_LP_BADGER_FRAXBP), 20 ether, block.timestamp);
        avatar.withdrawFromPrivateVault(CONVEX_PID_BADGER_FRAXBP);

        address vaultAddr = avatar.privateVaults(CONVEX_PID_BADGER_FRAXBP);
        IStakingProxy proxy = IStakingProxy(vaultAddr);

        assertEq(IFraxUnifiedFarm(proxy.stakingAddress()).lockedLiquidityOf(vaultAddr), 0);

        assertEq(CURVE_LP_BADGER_FRAXBP.balanceOf(owner), 20e18);
    }

    function test_withdrawFromPrivateVault_emergency_manager() public {
        vm.prank(owner);
        avatar.depositInPrivateVault(CONVEX_PID_BADGER_FRAXBP, 20 ether, false);
        vm.stopPrank();

        skip(2 weeks);

        vm.prank(manager);
        vm.expectEmit(true, true, false, true);
        emit Withdraw(address(CURVE_LP_BADGER_FRAXBP), 20 ether, block.timestamp);
        avatar.withdrawFromPrivateVault(CONVEX_PID_BADGER_FRAXBP);

        address vaultAddr = avatar.privateVaults(CONVEX_PID_BADGER_FRAXBP);
        IStakingProxy proxy = IStakingProxy(vaultAddr);

        assertEq(IFraxUnifiedFarm(proxy.stakingAddress()).lockedLiquidityOf(vaultAddr), 0);

        assertEq(CURVE_LP_BADGER_FRAXBP.balanceOf(owner), 20e18);
    }

    function test_withdrawFromPrivateVault_not_private_vault() public {
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.NoPrivateVaultForPid.selector, 80));
        vm.prank(owner);
        avatar.withdrawFromPrivateVault(80);
    }

    function test_withdrawFromPrivateVault_not_lock_expired() public {
        vm.prank(owner);
        bytes32 kekId = avatar.depositInPrivateVault(CONVEX_PID_BADGER_FRAXBP, 20 ether, false);

        skip(3 days);

        vm.expectRevert(
            abi.encodeWithSelector(
                ConvexAvatarMultiToken.NoExpiredLock.selector, avatar.privateVaults(CONVEX_PID_BADGER_FRAXBP), kekId
            )
        );
        vm.prank(owner);
        avatar.withdrawFromPrivateVault(CONVEX_PID_BADGER_FRAXBP);
    }

    function test_withdrawFromPrivateVault_nothing() public {
        vm.expectRevert(ConvexAvatarMultiToken.NothingToWithdraw.selector);
        vm.prank(owner);
        avatar.withdrawFromPrivateVault(CONVEX_PID_BADGER_FRAXBP);
    }

    function test_withdrawFromPrivateVault_permissions() public {
        vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.NotOwnerOrManager.selector, keeper));
        vm.prank(keeper);
        avatar.withdrawFromPrivateVault(CONVEX_PID_BADGER_FRAXBP);
    }

    function test_claimRewardsAndSendToOwner() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        uint256 initialOwnerCrv = CRV.balanceOf(owner);
        uint256 initialOwnerCvx = CVX.balanceOf(owner);

        skip(1 hours);

        uint256 crvReward = BASE_REWARD_POOL_BADGER_WBTC.earned(address(avatar));

        assertGt(crvReward, 0);

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit RewardClaimed(address(CRV), crvReward, block.timestamp);
        avatar.claimRewardsAndSendToOwner();

        assertEq(BASE_REWARD_POOL_BADGER_WBTC.earned(address(avatar)), 0);

        assertEq(CRV.balanceOf(address(avatar)), 0);
        assertEq(CVX.balanceOf(address(avatar)), 0);

        assertGt(CRV.balanceOf(owner), initialOwnerCrv);
        assertGt(CVX.balanceOf(owner), initialOwnerCvx);
    }

    function test_claimRewardsAndSendToOwner_fxs_route() public {
        vm.prank(owner);
        avatar.depositInPrivateVault(CONVEX_PID_BADGER_FRAXBP, 20 ether, false);

        uint256 initialOwnerCrv = CRV.balanceOf(owner);
        uint256 initialOwnerCvx = CVX.balanceOf(owner);
        uint256 initialOwnerFxs = FXS.balanceOf(owner);

        skip(1 weeks);

        uint256 crvReward;
        uint256 fxsReward;

        IStakingProxy proxy = IStakingProxy(avatar.privateVaults(CONVEX_PID_BADGER_FRAXBP));

        (address[] memory tokenAddresses, uint256[] memory totalEarned) = proxy.earned();

        for (uint256 i; i < tokenAddresses.length;) {
            if (tokenAddresses[i] == address(CRV)) {
                crvReward = totalEarned[i];
                assertGt(crvReward, 0);
            }
            if (tokenAddresses[i] == address(FXS)) {
                fxsReward = totalEarned[i];
                assertGt(fxsReward, 0);
            }
            unchecked {
                ++i;
            }
        }

        vm.prank(owner);
        avatar.claimRewardsAndSendToOwner();

        (tokenAddresses, totalEarned) = proxy.earned();
        for (uint256 i; i < tokenAddresses.length;) {
            assertEq(totalEarned[i], 0);
            unchecked {
                ++i;
            }
        }

        assertEq(CRV.balanceOf(address(avatar)), 0);
        assertEq(CVX.balanceOf(address(avatar)), 0);
        assertEq(FXS.balanceOf(address(avatar)), 0);

        assertGt(CRV.balanceOf(owner), initialOwnerCrv);
        assertGt(CVX.balanceOf(owner), initialOwnerCvx);
        assertGt(FXS.balanceOf(owner), initialOwnerFxs);
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
        vm.expectRevert(ConvexAvatarMultiToken.NoRewards.selector);
        vm.prank(owner);
        avatar.claimRewardsAndSendToOwner();
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Keeper
    ////////////////////////////////////////////////////////////////////////////

    function test_checkUpKeep() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skip(1 weeks);

        (bool upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);
    }

    function test_checkUpkeep_premature() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skipAndForwardFeeds(1 weeks);

        bool upkeepNeeded;

        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        vm.prank(keeper);
        avatar.performUpkeep(new bytes(0));

        skip(1 weeks - 1);

        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);
    }

    function test_performUpKeep() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);
        vm.prank(owner);
        avatar.depositInPrivateVault(CONVEX_PID_BADGER_FRAXBP, 20 ether, false);

        skipAndForwardFeeds(1 weeks);

        uint256 daiBalanceBefore = DAI.balanceOf(owner);

        bool upkeepNeeded;
        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        address privateVault = avatar.privateVaults(CONVEX_PID_BADGER_FRAXBP);

        vm.prank(keeper);
        vm.expectEmit(true, false, false, false);
        emit RewardsToStable(address(DAI), 0, block.timestamp);
        avatar.performUpkeep(new bytes(0));

        // Ensure that rewards were processed properly
        assertEq(BASE_REWARD_POOL_BADGER_WBTC.earned(address(avatar)), 0);
        uint256[] memory accruedRewards = UNIFIED_FARM_BADGER_FRAXBP.earned(privateVault);
        for (uint256 i; i < accruedRewards.length; i++) {
            assertEq(accruedRewards[i], 0);
        }

        // DAI balance increased on owner
        assertGt(DAI.balanceOf(owner), daiBalanceBefore);

        // Upkeep is not needed anymore
        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);
    }

    function test_performUpkeep_staleFeed() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skip(1 weeks);

        vm.expectRevert(
            abi.encodeWithSelector(
                BaseAvatarUtils.StalePriceFeed.selector, block.timestamp, CRV_ETH_FEED.latestTimestamp(), 24 hours
            )
        );
        vm.prank(keeper);
        avatar.performUpkeep(new bytes(0));
    }

    function test_performUpkeep_permissions() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        address[3] memory actors = [address(this), owner, manager];
        for (uint256 i; i < actors.length; ++i) {
            uint256 snapId = vm.snapshot();

            vm.prank(actors[i]);
            vm.expectRevert(abi.encodeWithSelector(ConvexAvatarMultiToken.NotKeeper.selector, actors[i]));
            avatar.performUpkeep(new bytes(0));

            vm.revertTo(snapId);
        }
    }

    function test_performUpkeep_premature() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = CONVEX_PID_BADGER_WBTC;
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skipAndForwardFeeds(1 weeks);

        bool upkeepNeeded;

        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        vm.prank(keeper);
        avatar.performUpkeep(new bytes(0));

        skip(1 weeks - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                ConvexAvatarMultiToken.TooSoon.selector,
                block.timestamp,
                avatar.lastClaimTimestamp(),
                avatar.claimFrequency()
            )
        );
        vm.prank(keeper);
        avatar.performUpkeep(new bytes(0));
    }

    ////////////////////////////////////////////////////////////////////////////
    // Internal helpers
    ////////////////////////////////////////////////////////////////////////////

    function skipAndForwardFeeds(uint256 _duration) internal {
        skip(_duration);
        forwardClFeed(FXS_USD_FEED, _duration);
        forwardClFeed(CRV_ETH_FEED, _duration);
        forwardClFeed(CVX_ETH_FEED, _duration);
        forwardClFeed(DAI_ETH_FEED, _duration);
        forwardClFeed(FRAX_USD_FEED, _duration);
        forwardClFeed(DAI_USD_FEED, _duration);
    }

    function forwardClFeed(IAggregatorV3 _feed, uint256 _duration) internal {
        int256 lastAnswer = _feed.latestAnswer();
        uint256 lastTimestamp = _feed.latestTimestamp();
        vm.etch(address(_feed), type(MockV3Aggregator).runtimeCode);
        MockV3Aggregator(address(_feed)).updateAnswerAndTimestamp(lastAnswer, lastTimestamp + _duration);
    }
}
