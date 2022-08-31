// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

struct TokenAmount {
    address token;
    uint256 amount;
}

// TODO: Storage packing? Check if that works with proxy upgrades?
struct BpsConfig {
    uint256 val;
    uint256 min;
}
