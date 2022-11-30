// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {IERC20MetadataUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {ConvexAvatarMultiToken, TokenAmount} from "../../src/convex/ConvexAvatarMultiToken.sol";
import {ConvexAvatarUtils} from "../../src/convex/ConvexAvatarUtils.sol";
import {CONVEX_PID_BADGER_WBTC, CONVEX_PID_BADGER_FRAXBP} from "../../src/BaseConstants.sol";

import {IBaseRewardPool} from "../../src/interfaces/aura/IBaseRewardPool.sol";
import {IAggregatorV3} from "../../src/interfaces/chainlink/IAggregatorV3.sol";

import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract ConvexAvatarMultiTokenTest is Test, ConvexAvatarUtils {
    ConvexAvatarMultiToken avatar;

    IERC20MetadataUpgradeable constant CURVE_LP_BADGER_WBTC =
        IERC20MetadataUpgradeable(0x137469B55D1f15651BA46A89D0588e97dD0B6562);
    IERC20MetadataUpgradeable constant WCVX_BADGER_FRAXBP =
        IERC20MetadataUpgradeable(0xb92e3fD365Fc5E038aa304Afe919FeE158359C88);

    IBaseRewardPool constant BASE_REWARD_POOL_BADGER_WBTC = IBaseRewardPool(0x36c7E7F9031647A74687ce46A8e16BcEA84f3865);

    address constant owner = address(1);
    address constant manager = address(2);
    address constant keeper = address(3);

    uint256[1] pidsExpected = [CONVEX_PID_BADGER_WBTC];
    address[2] assetsExpected = [address(CURVE_LP_BADGER_WBTC), address(WCVX_BADGER_FRAXBP)];

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

        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = pidsExpected[0];

        avatar = new ConvexAvatarMultiToken();
        avatar.initialize(owner, manager, keeper, pidsInit);

        for (uint256 i = 0; i < assetsExpected.length; i++) {
            deal(assetsExpected[i], owner, 20e18, true);
        }

        vm.startPrank(owner);
        CURVE_LP_BADGER_WBTC.approve(address(avatar), 20e18);
        WCVX_BADGER_FRAXBP.approve(address(avatar), 20e18);
        vm.stopPrank();
    }

    ////////////////////////////////////////////////////////////////////////////
    // Actions: Keeper
    ////////////////////////////////////////////////////////////////////////////

    function test_checkUpKeep() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = pidsExpected[0];
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skip(1 weeks);

        (bool upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);
    }

    function test_performUpKeep() public {
        uint256[] memory amountsDeposit = new uint256[](1);
        amountsDeposit[0] = 20 ether;
        uint256[] memory pidsInit = new uint256[](1);
        pidsInit[0] = pidsExpected[0];
        vm.prank(owner);
        avatar.deposit(pidsInit, amountsDeposit);

        skipAndForwardFeeds(1 weeks);

        uint256 daiBalanceBefore = DAI.balanceOf(owner);

        bool upkeepNeeded;
        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertTrue(upkeepNeeded);

        vm.prank(keeper);
        avatar.performUpkeep(new bytes(0));

        // Ensure that rewards were processed properly
        assertEq(BASE_REWARD_POOL_BADGER_WBTC.earned(address(avatar)), 0);

        // DAI balance increased on owner
        assertGt(DAI.balanceOf(owner), daiBalanceBefore);

        // Upkeep is not needed anymore
        (upkeepNeeded,) = avatar.checkUpkeep(new bytes(0));
        assertFalse(upkeepNeeded);
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
