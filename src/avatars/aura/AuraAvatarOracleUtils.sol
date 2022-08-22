// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {IAsset} from "../../interfaces/balancer/IAsset.sol";
import {IPriceOracle} from "../../interfaces/balancer/IPriceOracle.sol";
import {IAggregatorV3} from "../../interfaces/chainlink/IAggregatorV3.sol";

abstract contract AuraAvatarOracleUtils {
    ////////////////////////////////////////////////////////////////////////////
    // CONSTANTS
    ////////////////////////////////////////////////////////////////////////////

    uint256 private constant TWAP_DURATION = 1 hours;
    uint256 private constant MAX_LOOKBACK = 1 hours;

    ////////////////////////////////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////////////////////////////////

    error StalePriceFeed();

    function fetchPriceFromClFeed(IAggregatorV3 _feed) internal view returns (uint256 answerUint256_) {
        (, int256 answer,, uint256 updateTime,) = _feed.latestRoundData();

        if (block.timestamp - updateTime > MAX_LOOKBACK) {
            revert StalePriceFeed();
        }

        answerUint256_ = uint256(answer);
    }

    function fetchPriceFromBalancerTwap(IPriceOracle _pool) internal view returns (uint256 price_) {
        IPriceOracle.OracleAverageQuery[] memory queries = new IPriceOracle.OracleAverageQuery[](1);

        queries[0].variable = IPriceOracle.Variable.PAIR_PRICE;
        queries[0].secs = TWAP_DURATION;
        queries[0].ago = 0; // now

        // Gets the balancer time weighted average price denominated in BAL
        price_ = _pool.getTimeWeightedAverage(queries)[0];
    }

    function fetchBptPriceFromBalancerTwap(IPriceOracle _pool) internal view returns (uint256 price_) {
        IPriceOracle.OracleAverageQuery[] memory queries = new IPriceOracle.OracleAverageQuery[](1);

        queries[0].variable = IPriceOracle.Variable.BPT_PRICE;
        queries[0].secs = TWAP_DURATION;
        queries[0].ago = 0; // now

        // Gets the balancer time weighted average price denominated in BAL
        price_ = _pool.getTimeWeightedAverage(queries)[0];
    }
}
