// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20MetadataUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {IAggregatorV3} from "../interfaces/chainlink/IAggregatorV3.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {IUniswapRouterV3} from "../interfaces/uniswap/IUniswapRouterV3.sol";
import {IFraxSwapRouter} from "../interfaces/frax/IFraxSwapRouter.sol";
import {IBooster} from "../interfaces/aura/IBooster.sol";
import {IFraxBooster} from "../interfaces/convex/IFraxBooster.sol";
import {IFraxRegistry} from "../interfaces/convex/IFraxRegistry.sol";
import {IMetaRegistry} from "../interfaces/curve/IMetaRegistry.sol";

abstract contract ConvexConstants {
    // convex contracts
    IBooster internal constant CONVEX_BOOSTER = IBooster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);
    IFraxBooster internal constant FRAX_BOOSTER = IFraxBooster(0x569f5B842B5006eC17Be02B8b94510BA8e79FbCa);
    IFraxRegistry internal constant CONVEX_FRAX_REGISTRY = IFraxRegistry(0x41a5881c17185383e19Df6FA4EC158a6F4851A69);

    // uniswap v3
    IUniswapRouterV3 internal constant UNIV3_ROUTER = IUniswapRouterV3(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    // curve meta registry. ref: https://github.com/curvefi/metaregistry#deployments
    IMetaRegistry internal constant META_REGISTRY = IMetaRegistry(0xF98B45FA17DE75FB1aD0e7aFD971b0ca00e379fC);
    uint256 internal constant TWO_COINS_POOL = 2;
    uint256 internal constant THREE_COINS_POOL = 3;
    uint256 internal constant FOUR_COINS_POOL = 4;
    address internal constant CURVE_ETH_ADDR = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // curve pools
    ICurvePool internal constant CRV_ETH_CURVE_POOL = ICurvePool(0x8301AE4fc9c624d1D396cbDAa1ed877821D7C511);
    ICurvePool internal constant CVX_ETH_CURVE_POOL = ICurvePool(0xB576491F1E6e5E62f1d8F26062Ee822B40B0E0d4);
    ICurvePool internal constant FRAX_3CRV_CURVE_POOL = ICurvePool(0xd632f22692FaC7611d2AA1C0D552930D43CAEd3B);

    // fraxswap
    IFraxSwapRouter internal constant FRAXSWAP_ROUTER = IFraxSwapRouter(0xC14d550632db8592D1243Edc8B95b0Ad06703867);

    // tokens involved
    IERC20MetadataUpgradeable internal constant FXS =
        IERC20MetadataUpgradeable(0x3432B6A60D23Ca0dFCa7761B7ab56459D9C964D0);
    IERC20MetadataUpgradeable internal constant CRV =
        IERC20MetadataUpgradeable(0xD533a949740bb3306d119CC777fa900bA034cd52);
    IERC20MetadataUpgradeable internal constant CVX =
        IERC20MetadataUpgradeable(0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B);
    IERC20MetadataUpgradeable internal constant DAI =
        IERC20MetadataUpgradeable(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20MetadataUpgradeable internal constant FRAX =
        IERC20MetadataUpgradeable(0x853d955aCEf822Db058eb8505911ED77F175b99e);
    IERC20MetadataUpgradeable internal constant WETH =
        IERC20MetadataUpgradeable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    // CL feed oracles
    IAggregatorV3 internal constant FXS_USD_FEED = IAggregatorV3(0x6Ebc52C8C1089be9eB3945C4350B68B8E4C2233f);
    IAggregatorV3 internal constant CRV_ETH_FEED = IAggregatorV3(0x8a12Be339B0cD1829b91Adc01977caa5E9ac121e);
    IAggregatorV3 internal constant CVX_ETH_FEED = IAggregatorV3(0xC9CbF687f43176B302F03f5e58470b77D07c61c6);
    IAggregatorV3 internal constant DAI_ETH_FEED = IAggregatorV3(0x773616E4d11A78F511299002da57A0a94577F1f4);
    IAggregatorV3 internal constant FRAX_USD_FEED = IAggregatorV3(0xB9E1E3A9feFf48998E45Fa90847ed4D467E8BcfD);
    IAggregatorV3 internal constant DAI_USD_FEED = IAggregatorV3(0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9);

    // NOTE: all CL feeds share same heartbeat except eth_usd
    uint256 internal constant CL_FEED_DAY_HEARTBEAT = 24 hours;
    uint256 internal constant CL_FEED_HOUR_HEARTBEAT = 1 hours;

    // NOTE: all CL usd feeds are expressed in 8 decimals
    uint256 internal constant FEED_DIVISOR_USD = 1e20;
    // NOTE: all CL eth feeds are expressed in 18 decimals
    uint256 internal constant FEED_DIVISOR_ETH = 1e18;
    uint256 internal constant FEED_DIVISOR_FXS_USD = 1e8;

    // locking constraints param
    uint256 internal constant MAX_LOCKING_TIME = 4 weeks;
}
