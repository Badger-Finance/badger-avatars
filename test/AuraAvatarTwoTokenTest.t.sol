// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {Test} from "forge-std/Test.sol";

import {AuraAvatarTwoToken, TokenAmount} from "../src/avatars/aura/AuraAvatarTwoToken.sol";
import {AuraConstants} from "../src/avatars/aura/AuraConstants.sol";

uint256 constant PID_80BADGER_20WBTC = 11;
uint256 constant PID_40WBTC_40DIGG_20GRAVIAURA = 18;

contract AuraAvatarTwoTokenTest is Test, AuraConstants {
    AuraAvatarTwoToken avatar;

    address constant owner = address(1);

    function setUp() public {
        avatar = new AuraAvatarTwoToken(PID_80BADGER_20WBTC, PID_40WBTC_40DIGG_20GRAVIAURA);
        avatar.initialize(owner);

        deal(address(avatar.bpt1()), address(avatar), 10e18, true);
        deal(address(avatar.bpt2()), address(avatar), 10e18, true);
    }

    function testDepositAll() public {
        avatar.depositAll();

        TokenAmount[2] memory tokenAmounts = avatar.totalAssets();
        assertEq(tokenAmounts[0].amount, 10e18);
        assertEq(tokenAmounts[1].amount, 10e18);
    }
}
