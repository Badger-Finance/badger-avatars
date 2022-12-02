// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFraxUnifiedFarm {
    function lock_time_min() external view returns (uint256);

    function earned(address account) external view returns (uint256[] memory new_earned);

    function lockedLiquidityOf(address account) external view returns (uint256);
}
