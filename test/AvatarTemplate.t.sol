// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {BaseFixture} from "./BaseFixture.sol";

contract AvatarTemplateTest is BaseFixture {
    function setUp() public override {
        BaseFixture.setUp();
    }

    function testInitialize() public {
        assertEq(address(avatar_template.owner()), owner);
        assertEq(address(avatar_template.gac()), gac);
    }
}