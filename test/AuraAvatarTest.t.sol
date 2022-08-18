// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {Test} from "forge-std/Test.sol";

import {AuraAvatar} from "../src/avatars/aura/AuraAvatar.sol";

contract AuraAvatarTest is Test {
    AuraAvatar avatar;
    address owner = address(1);

    function setUp() public {
        avatar = new AuraAvatar();
        avatar.initialize(owner);
    }

    function testDepositAll() public {
        avatar.depositAll();
    }
}
