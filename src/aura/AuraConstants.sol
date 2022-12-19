// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20MetadataUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {IAuraLocker} from "../interfaces/aura/IAuraLocker.sol";
import {IBaseRewardPool} from "../interfaces/aura/IBaseRewardPool.sol";
import {IBooster} from "../interfaces/aura/IBooster.sol";
import {ICrvDepositorWrapper} from "../interfaces/aura/ICrvDepositorWrapper.sol";
import {ICrvDepositor} from "../interfaces/aura/ICrvDepositor.sol";
import {IVault} from "../interfaces/badger/IVault.sol";
import {IBalancerVault} from "../interfaces/balancer/IBalancerVault.sol";
import {IPriceOracle} from "../interfaces/balancer/IPriceOracle.sol";
import {IAggregatorV3} from "../interfaces/chainlink/IAggregatorV3.sol";

abstract contract AuraConstants {
    IBalancerVault internal constant BALANCER_VAULT = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    IBooster internal constant AURA_BOOSTER = IBooster(0xA57b8d98dAE62B26Ec3bcC4a365338157060B234);
    IAuraLocker internal constant AURA_LOCKER = IAuraLocker(0x3Fa73f1E5d8A792C80F426fc8F84FBF7Ce9bBCAC);

    address internal constant BADGER_VOTER = 0xA9ed98B5Fb8428d68664f3C5027c62A10d45826b;

    IERC20MetadataUpgradeable internal constant AURA =
        IERC20MetadataUpgradeable(0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF);
    IERC20MetadataUpgradeable internal constant BAL =
        IERC20MetadataUpgradeable(0xba100000625a3754423978a60c9317c58a424e3D);
    IERC20MetadataUpgradeable internal constant WETH =
        IERC20MetadataUpgradeable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20MetadataUpgradeable internal constant USDC =
        IERC20MetadataUpgradeable(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    bytes32 internal constant BAL_WETH_POOL_ID = 0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014;
    bytes32 internal constant AURA_WETH_POOL_ID = 0xcfca23ca9ca720b6e98e3eb9b6aa0ffc4a5c08b9000200000000000000000274; // 50AURA-50WETH
    bytes32 internal constant USDC_WETH_POOL_ID = 0x96646936b91d6b9d7d0c47c496afbf3d6ec7b6f8000200000000000000000019;

    IAggregatorV3 internal constant BAL_USD_FEED = IAggregatorV3(0xdF2917806E30300537aEB49A7663062F4d1F2b5F);
    IAggregatorV3 internal constant BAL_ETH_FEED = IAggregatorV3(0xC1438AA3823A6Ba0C159CfA8D98dF5A994bA120b);
    IAggregatorV3 internal constant ETH_USD_FEED = IAggregatorV3(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);

    uint256 internal constant CL_FEED_HEARTBEAT_ETH_USD = 1 hours;
    uint256 internal constant CL_FEED_HEARTBEAT_BAL = 24 hours;

    IPriceOracle internal constant BPT_80AURA_20WETH = IPriceOracle(0xc29562b045D80fD77c69Bec09541F5c16fe20d9d); // POL from AURA

    uint256 internal constant BAL_USD_FEED_DIVISOR = 1e20;
    uint256 internal constant AURA_USD_TWAP_DIVISOR = 1e38;

    uint256 internal constant AURA_USD_SPOT_FACTOR = 1e20;
}
