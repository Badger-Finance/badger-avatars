// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20MetadataUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {IAggregatorV3} from "../interfaces/chainlink/IAggregatorV3.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {IUniswapRouterV3} from "../interfaces/uniswap/IUniswapRouterV3.sol";
import {IFraxSwapRouter} from "../interfaces/frax/IFraxSwapRouter.sol";

abstract contract ConvexConstants {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IUniswapRouterV3 internal constant UNIV3_ROUTER = IUniswapRouterV3(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
    ICurvePool internal constant CRV_ETH_CURVE_POOL = ICurvePool(0x8301AE4fc9c624d1D396cbDAa1ed877821D7C511);
    ICurvePool internal constant CVX_ETH_CURVE_POOL = ICurvePool(0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4);
    IFraxSwapRouter internal constant FRAXSWAP_ROUTER = IFraxSwapRouter(0xC14d550632db8592D1243Edc8B95b0Ad06703867);

    IERC20MetadataUpgradeable internal constant FXS =
        IERC20MetadataUpgradeable(0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0);
    IERC20MetadataUpgradeable internal constant CRV =
        IERC20MetadataUpgradeable(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20MetadataUpgradeable internal constant CVX =
        IERC20MetadataUpgradeable(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20MetadataUpgradeable internal constant USDC =
        IERC20MetadataUpgradeable(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20MetadataUpgradeable internal constant FRAX =
        IERC20MetadataUpgradeable(0x853d955aCEf822Db058eb8505911ED77F175b99e);

    IAggregatorV3 internal constant FXS_USD_FEED = IAggregatorV3(0x6Ebc52C8C1089be9eB3945C4350B68B8E4C2233f);
    IAggregatorV3 internal constant CRV_USD_FEED = IAggregatorV3(0xCd627aA160A6fA45Eb793D19Ef54f5062F20f33f);
    IAggregatorV3 internal constant CVX_USD_FEED = IAggregatorV3(0xd962fC30A72A84cE50161031391756Bf2876Af5D);
    IAggregatorV3 internal constant CRV_ETH_FEED = IAggregatorV3(0x8a12Be339B0cD1829b91Adc01977caa5E9ac121e);
    IAggregatorV3 internal constant CVX_ETH_FEED = IAggregatorV3(0xC9CbF687f43176B302F03f5e58470b77D07c61c6);

    // NOTE: all CL feeds share same heartbeat
    uint256 internal constant CL_FEED_HEARTBEAT = 24 hours;

    // NOTE: all CL usd feeds are expressed in 8 decimals
    uint256 internal constant FEED_DIVISOR_USD = 1e20;
    // NOTE: all CL eth feeds are expressed in 18 decimals
    uint256 internal constant FEED_DIVISOR_ETH = 1e18;
}
