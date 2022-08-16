// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.16;

import {Test} from "forge-std/Test.sol";

import {Avatar} from "src/avatars/template/Avatar.sol";

contract BaseFixture is Test {
    // ==================
    // ===== Actors =====
    // ==================

    address immutable owner = address(1);

    // ==================
    // === Contracts ====
    // ==================

    address immutable gac = 0x9c58B0D88578cd75154Bdb7C8B013f7157bae35a;

    // ==================
    // == Deployments ===
    // ==================

    Avatar avatar_template = new Avatar();

    function setUp() public virtual {
        // Labels
        vm.label(address(this), "this");

        // Initialize template
        avatar_template.initialize(gac, owner);
    }
}
