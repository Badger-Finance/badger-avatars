// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {IPriceOracle} from "../interfaces/balancer/IPriceOracle.sol";
import {IAggregatorV3} from "../interfaces/chainlink/IAggregatorV3.sol";

abstract contract AuraAvatarOracleUtils {
    ////////////////////////////////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////////////////////////////////

    error StalePriceFeed(uint256 currentTime, uint256 updateTime, uint256 maxPeriod);

    // TODO: More checks?
    function fetchPriceFromClFeed(IAggregatorV3 _feed, uint256 maxStalePeriod)
        internal
        view
        returns (uint256 answerUint256_)
    {
        (, int256 answer,, uint256 updateTime,) = _feed.latestRoundData();

        if (block.timestamp - updateTime > maxStalePeriod) {
            revert StalePriceFeed(block.timestamp, updateTime, maxStalePeriod);
        }

        answerUint256_ = uint256(answer);
    }

    function fetchPriceFromBalancerTwap(IPriceOracle _pool, uint256 twapPeriod)
        internal
        view
        returns (uint256 price_)
    {
        IPriceOracle.OracleAverageQuery[] memory queries = new IPriceOracle.OracleAverageQuery[](1);

        queries[0].variable = IPriceOracle.Variable.PAIR_PRICE;
        queries[0].secs = twapPeriod;
        queries[0].ago = 0; // now

        // Gets the balancer time weighted average price denominated in BAL
        price_ = _pool.getTimeWeightedAverage(queries)[0];
    }

    function fetchBptPriceFromBalancerTwap(IPriceOracle _pool, uint256 twapPeriod)
        internal
        view
        returns (uint256 price_)
    {
        IPriceOracle.OracleAverageQuery[] memory queries = new IPriceOracle.OracleAverageQuery[](1);

        queries[0].variable = IPriceOracle.Variable.BPT_PRICE;
        queries[0].secs = twapPeriod;
        queries[0].ago = 0; // now

        // Gets the balancer time weighted average price denominated in BAL
        price_ = _pool.getTimeWeightedAverage(queries)[0];
    }
}
