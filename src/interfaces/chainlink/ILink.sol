// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILink {
    function transferAndCall(
        address _to,
        uint256 _value,
        bytes memory _data
    ) external returns (bool success);

    function balanceOf(address account) external view returns (uint256);
}
