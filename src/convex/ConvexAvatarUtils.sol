// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseAvatarUtils} from "../BaseAvatarUtils.sol";
import {ConvexConstants} from "./ConvexConstants.sol";

import {IConvexToken} from "../interfaces/convex/IConvexToken.sol";

contract ConvexAvatarUtils is BaseAvatarUtils, ConvexConstants {
    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL VIEW
    ////////////////////////////////////////////////////////////////////////////

    function getFxsAmountInFrax(uint256 _fxsAmount) internal view returns (uint256 usdcAmount_) {
        // NOTE: 8 decimals answer
        uint256 fxsInUsd = fetchPriceFromClFeed(FXS_USD_FEED, CL_FEED_DAY_HEARTBEAT);
        // NOTE: 8 decimals answer
        uint256 fraxInUsd = fetchPriceFromClFeed(FRAX_USD_FEED, CL_FEED_HOUR_HEARTBEAT);
        uint256 fxsFraxRatio = (fxsInUsd * 1e8) / fraxInUsd;
        // Divisor is 10^8 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_fxsAmount * fxsFraxRatio) / FEED_DIVISOR_FXS_USD;
    }

    function getCrvAmountInEth(uint256 _crvAmount) internal view returns (uint256 usdcAmount_) {
        uint256 crvInEth = fetchPriceFromClFeed(CRV_ETH_FEED, CL_FEED_DAY_HEARTBEAT);
        // Divisor is 10^18 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_crvAmount * crvInEth) / FEED_DIVISOR_ETH;
    }

    function getCvxAmountInEth(uint256 _cvxAmount) internal view returns (uint256 usdcAmount_) {
        uint256 cvxInEth = fetchPriceFromClFeed(CVX_ETH_FEED, CL_FEED_DAY_HEARTBEAT);
        // Divisor is 10^18 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_cvxAmount * cvxInEth) / FEED_DIVISOR_ETH;
    }

    function getWethAmountInDai(uint256 _wethAmount) internal view returns (uint256 daiAmount_) {
        uint256 daiInWeth = fetchPriceFromClFeed(DAI_ETH_FEED, CL_FEED_DAY_HEARTBEAT);
        // Divide by the rate from oracle since it is dai expressed in eth
        // FEED_DIVISOR_ETH has 1e18 precision
        daiAmount_ = (_wethAmount * FEED_DIVISOR_ETH) / daiInWeth;
    }

    function getFraxAmountInDai(uint256 _fraxAmount) internal view returns (uint256 daiAmount_) {
        // NOTE: 8 decimals answer
        uint256 fraxInUsd = fetchPriceFromClFeed(FRAX_USD_FEED, CL_FEED_HOUR_HEARTBEAT);
        // NOTE: 8 decimals answer
        uint256 daiInUsd = fetchPriceFromClFeed(DAI_USD_FEED, CL_FEED_HOUR_HEARTBEAT);
        uint256 fraxDaiRatio = (fraxInUsd * 1e8) / daiInUsd;
        daiAmount_ = (_fraxAmount * fraxDaiRatio) / 1e8;
    }

    /// @notice Calculates the expected amount of CVX minted given some CRV rewards.
    /// @dev ref: https://etherscan.io/token/0x4e3fbd56cd56c3e72c1403e103b45db9da5b9d2b#code#L1091
    /// @param _crvAmount The input CRV reward amount.
    /// @return cvxAmount_ The expected amount of CVX minted.
    function getMintableCvxForCrvAmount(uint256 _crvAmount) internal view returns (uint256 cvxAmount_) {
        uint256 supply = CVX.totalSupply();
        uint256 reductionPerCliff = IConvexToken(address(CVX)).reductionPerCliff();
        uint256 totalCliffs = IConvexToken(address(CVX)).totalCliffs();
        uint256 maxSupply = IConvexToken(address(CVX)).maxSupply();

        uint256 cliff = supply / reductionPerCliff;
        //mint if below total cliffs
        if (cliff < totalCliffs) {
            //for reduction% take inverse of current cliff
            uint256 reduction = totalCliffs - cliff;
            //reduce
            cvxAmount_ = _crvAmount * reduction / totalCliffs;

            //supply cap check
            uint256 amtTillMax = maxSupply - supply;
            if (cvxAmount_ > amtTillMax) {
                cvxAmount_ = amtTillMax;
            }
        }
    }
}
