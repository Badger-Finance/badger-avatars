// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.12;

import "ds-test/test.sol";
import {Vm} from "forge-std/Vm.sol";
import {stdCheats} from "forge-std/stdlib.sol";
import {Utils} from "./utils/Utils.sol";
import {ERC20Utils} from "./utils/ERC20Utils.sol";
import {SnapshotComparator} from "./utils/SnapshotUtils.sol";

import {Avatar} from "src/avatars/template/Avatar.sol";

contract BaseFixture is DSTest, Utils, stdCheats {
    Vm constant vm = Vm(HEVM_ADDRESS);
    ERC20Utils immutable erc20utils = new ERC20Utils();
    SnapshotComparator comparator;

    // ==================
    // ===== Actors =====
    // ==================

    address immutable owner = getAddress("owner");

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
        avatar_template.initialize(
            gac,
            owner
        );
    }
}