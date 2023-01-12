// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IStakingProxy {
    function curveLpToken() external view returns (address);

    function earned() external view returns (address[] memory tokenAddresses, uint256[] memory totalEarned);

    function getReward() external;

    function lockAdditional(bytes32 _kekId, uint256 _addLiq) external;

    function lockLonger(bytes32 _kekId, uint256 newEndingTs) external;

    function stakingAddress() external view returns (address);

    function stakingToken() external view returns (address);

    function stakeLocked(uint256 _liquidity, uint256 _secs) external returns (bytes32 kekId);

    function withdrawLocked(bytes32 _kekId) external;

    function withdrawLockedAndUnwrap(bytes32 _kekId) external;
}
