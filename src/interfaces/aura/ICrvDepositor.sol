// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

interface ICrvDepositor {
    function deposit(uint256 _amount, bool _lock, address _stakeAddress) external;
}
