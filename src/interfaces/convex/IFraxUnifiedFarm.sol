// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFraxUnifiedFarm {
    function lock_time_min() external view returns (uint256);
}
