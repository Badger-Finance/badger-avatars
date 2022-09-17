// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2 as console} from "forge-std/console2.sol";

import {BaseFixture} from "./BaseFixture.sol";

import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";

contract AvatarTemplateTest is BaseFixture {
    function setUp() public override {
        BaseFixture.setUp();
    }

    function test_initialize() public {
        assertEq(address(avatar_template.owner()), owner);
    }

    function test_call() public {
        ERC20 token = new ERC20("mock", "MCK");
        vm.label(address(token), "MCK");

        // Mint something to avatar and see if it can transfer
        deal(address(token), address(avatar_template), 1e18, true);
        assertEq(token.balanceOf(address(avatar_template)), 1e18);

        vm.prank(owner);
        bool success = avatar_template.call(address(token), 0, abi.encodeCall(ERC20.transfer, (address(this), 1e18)));

        assertTrue(success);
        assertEq(token.balanceOf(address(avatar_template)), 0);
        assertEq(token.balanceOf(address(this)), 1e18);
    }

    function test_call_permissions() public {
        vm.expectRevert("Ownable: caller is not the owner");
        avatar_template.call(address(0), 0, new bytes(0));
    }

    // TODO: Test multiple actions in a single call
}
