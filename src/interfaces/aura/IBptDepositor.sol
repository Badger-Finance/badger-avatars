// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

interface IBptDepositor {
    function deposit(
        uint256,
        bool,
        address
    ) external;
}
