// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFraxRegistry {
    function poolInfo(uint256)
        external
        view
        returns (
            address implementation,
            address stakingAddress,
            address stakingToken,
            address rewardsAddress,
            uint8 active
        );
}
