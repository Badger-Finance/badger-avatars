// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICurvePool {
    // Exchange using WETH by default
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);

    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy, address receiver)
        external
        returns (uint256);
}
