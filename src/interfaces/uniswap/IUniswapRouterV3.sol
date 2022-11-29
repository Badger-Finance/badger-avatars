// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IUniswapRouterV3 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    function refundETH() external payable;
}
