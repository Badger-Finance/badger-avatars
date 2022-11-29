// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ConvexConstants} from "./ConvexConstants.sol";

import {IAggregatorV3} from "../interfaces/chainlink/IAggregatorV3.sol";

contract ConvexAvatarUtils is ConvexConstants {
    ////////////////////////////////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////////////////////////////////

    error StalePriceFeed(uint256 currentTime, uint256 updateTime, uint256 maxPeriod);

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL VIEW
    ////////////////////////////////////////////////////////////////////////////
    function getFxsAmountInUsdc(uint256 _fxsAmount) internal view returns (uint256 usdcAmount_) {
        uint256 fxsInUsd = fetchPriceFromClFeed(FXS_USD_FEED);
        // Divisor is 10^20 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_fxsAmount * fxsInUsd) / FEED_DIVISOR_USD;
    }

    function getCrvAmountInUsdc(uint256 _crvAmount) internal view returns (uint256 usdcAmount_) {
        uint256 crvInUsd = fetchPriceFromClFeed(CRV_USD_FEED);
        // Divisor is 10^20 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_crvAmount * crvInUsd) / FEED_DIVISOR_USD;
    }

    function getCrvAmountInEth(uint256 _crvAmount) internal view returns (uint256 usdcAmount_) {
        uint256 crvInEth = fetchPriceFromClFeed(CRV_ETH_FEED);
        // Divisor is 10^18 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_crvAmount * crvInEth) / FEED_DIVISOR_ETH;
    }

    function getCvxAmountInUsdc(uint256 _cvxAmount) internal view returns (uint256 usdcAmount_) {
        uint256 cvxInUsd = fetchPriceFromClFeed(CVX_USD_FEED);
        // Divisor is 10^20 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_cvxAmount * cvxInUsd) / FEED_DIVISOR_USD;
    }

    function getCvxAmountInEth(uint256 _cvxAmount) internal view returns (uint256 usdcAmount_) {
        uint256 cvxInEth = fetchPriceFromClFeed(CVX_ETH_FEED);
        // Divisor is 10^18 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_cvxAmount * cvxInEth) / FEED_DIVISOR_ETH;
    }

    function fetchPriceFromClFeed(IAggregatorV3 _feed) internal view returns (uint256 answerUint256_) {
        (, int256 answer,, uint256 updateTime,) = _feed.latestRoundData();

        if (block.timestamp - updateTime > CL_FEED_HEARTBEAT) {
            revert StalePriceFeed(block.timestamp, updateTime, CL_FEED_HEARTBEAT);
        }

        answerUint256_ = uint256(answer);
    }
}
