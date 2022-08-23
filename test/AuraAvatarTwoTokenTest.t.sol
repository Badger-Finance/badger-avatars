// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {Test} from "forge-std/Test.sol";
import {IERC20Upgradeable} from "openzeppelin-contracts-upgradeable/interfaces/IERC20Upgradeable.sol";

import {IBaseRewardPool} from "../src/interfaces/aura/IBaseRewardPool.sol";
import {AuraAvatarTwoToken, TokenAmount} from "../src/avatars/aura/AuraAvatarTwoToken.sol";
import {AuraConstants} from "../src/avatars/aura/AuraConstants.sol";

uint256 constant PID_80BADGER_20WBTC = 11;
uint256 constant PID_40WBTC_40DIGG_20GRAVIAURA = 18;

contract AuraAvatarTwoTokenTest is Test, AuraConstants {
    AuraAvatarTwoToken avatar;

    IERC20Upgradeable constant BPT_80BADGER_20WBTC = IERC20Upgradeable(0xb460DAa847c45f1C4a41cb05BFB3b51c92e41B36);
    IBaseRewardPool constant BASE_REWARD_POOL_80BADGER_20WBTC =
        IBaseRewardPool(0xCea3aa5b2a50e39c7C7755EbFF1e9E1e1516D3f5);

    IERC20Upgradeable constant BPT_40WBTC_40DIGG_20GRAVIAURA =
        IERC20Upgradeable(0x8eB6c82C3081bBBd45DcAC5afA631aaC53478b7C);
    IBaseRewardPool constant BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA =
        IBaseRewardPool(0x10Ca519614b0F3463890387c24819001AFfC5152);

    address constant owner = address(1);

    function setUp() public {
        avatar = new AuraAvatarTwoToken(PID_80BADGER_20WBTC, PID_40WBTC_40DIGG_20GRAVIAURA);
        avatar.initialize(owner);

        deal(address(avatar.bpt1()), address(avatar), 10e18, true);
        deal(address(avatar.bpt2()), address(avatar), 20e18, true);
    }

    function testConstructor() public {
        assertEq(avatar.pid1(), PID_80BADGER_20WBTC);
        assertEq(avatar.pid2(), PID_40WBTC_40DIGG_20GRAVIAURA);

        assertEq(address(avatar.bpt1()), address(BPT_80BADGER_20WBTC));
        assertEq(address(avatar.bpt2()), address(BPT_40WBTC_40DIGG_20GRAVIAURA));

        assertEq(address(avatar.baseRewardPool1()), address(BASE_REWARD_POOL_80BADGER_20WBTC));
        assertEq(address(avatar.baseRewardPool2()), address(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA));
    }

    function testDepositAll() public {
        avatar.depositAll();

        assertEq(BPT_80BADGER_20WBTC.balanceOf(owner), 0);
        assertEq(BPT_40WBTC_40DIGG_20GRAVIAURA.balanceOf(address(avatar)), 0);

        assertEq(BASE_REWARD_POOL_80BADGER_20WBTC.balanceOf(address(avatar)), 10e18);
        assertEq(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.balanceOf(address(avatar)), 20e18);
    }

    function testWithdrawToOwner() public {
        vm.prank(owner);
        avatar.withdrawToOwner();

        assertEq(BASE_REWARD_POOL_80BADGER_20WBTC.balanceOf(address(avatar)), 0);
        assertEq(BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.balanceOf(address(avatar)), 0);

        assertEq(BPT_80BADGER_20WBTC.balanceOf(owner), 10e18);
        assertEq(BPT_40WBTC_40DIGG_20GRAVIAURA.balanceOf(owner), 20e18);
    }

    function testOnlyOwnerCanWithdrawToOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar.withdrawToOwner();
    }

    function testDepositFailsWithNothingToDeposit() public {
        deal(address(avatar.bpt1()), address(avatar), 0, true);
        deal(address(avatar.bpt2()), address(avatar), 0, true);

        vm.expectRevert(AuraAvatarTwoToken.NothingToDeposit.selector);
        avatar.depositAll();
    }
}
