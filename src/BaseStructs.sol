// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

struct TokenAmount {
    address token;
    uint256 amount;
}

struct BpsConfig {
    uint16 val;
    uint16 min;
}
