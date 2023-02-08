// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ICurvePool {
    function coins(uint256 arg0) external view returns (address);

    function coins(int128 i) external view returns (address);

    // Exchange using WETH by default
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 min_dy) external returns (uint256);

    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 min_dy, address receiver)
        external
        returns (uint256);

    function remove_liquidity(uint256 _amount, uint256[2] calldata _minAmounts) external;

    function remove_liquidity(uint256 _amount, uint256[3] calldata _minAmounts) external;

    function remove_liquidity(uint256 _amount, uint256[4] calldata _minAmounts) external;
}
