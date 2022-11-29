// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseAvatarUtils} from "../BaseAvatarUtils.sol";
import {ConvexConstants} from "./ConvexConstants.sol";

contract ConvexAvatarUtils is BaseAvatarUtils, ConvexConstants {
    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL VIEW
    ////////////////////////////////////////////////////////////////////////////
    function getFxsAmountInFrax(uint256 _fxsAmount) internal view returns (uint256 usdcAmount_) {
        uint256 fxsInUsd = fetchPriceFromClFeed(FXS_USD_FEED, CL_FEED_HEARTBEAT);
        // Divisor is 10^8 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_fxsAmount * fxsInUsd) / FEED_DIVISOR_FXS_USD;
    }

    function getCrvAmountInEth(uint256 _crvAmount) internal view returns (uint256 usdcAmount_) {
        uint256 crvInEth = fetchPriceFromClFeed(CRV_ETH_FEED, CL_FEED_HEARTBEAT);
        // Divisor is 10^18 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_crvAmount * crvInEth) / FEED_DIVISOR_ETH;
    }

    function getCvxAmountInEth(uint256 _cvxAmount) internal view returns (uint256 usdcAmount_) {
        uint256 cvxInEth = fetchPriceFromClFeed(CVX_ETH_FEED, CL_FEED_HEARTBEAT);
        // Divisor is 10^18 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_cvxAmount * cvxInEth) / FEED_DIVISOR_ETH;
    }

    function getWethAmountInUsdc(uint256 _wethAmount) internal view returns (uint256 usdcAmount_) {
        uint256 wethInUsd = fetchPriceFromClFeed(ETH_USD_FEED, CL_FEED_ETH_USD_HEARTBEAT);
        // Divisor is 10^20 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_wethAmount * wethInUsd) / FEED_DIVISOR_USD;
    }
}
