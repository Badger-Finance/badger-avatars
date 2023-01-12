// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFraxUnifiedFarm {
    function lock_time_min() external view returns (uint256);

    function earned(address account) external view returns (uint256[] memory new_earned);

    function lockedLiquidityOf(address account) external view returns (uint256);

    function lockedStakes(address, uint256)
        external
        view
        returns (
            bytes32 kekId,
            uint256 startTimestamp,
            uint256 liquidity,
            uint256 endingTimestamp,
            uint256 lockMultiplier
        );
}
