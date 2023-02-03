// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IMetaRegistry {
    function get_n_coins(address _pool) external returns (uint256);

    function get_pool_from_lp_token(address _token) external returns (address);
}
