// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {IERC20Upgradeable} from "openzeppelin-contracts-upgradeable/interfaces/IERC20Upgradeable.sol";

import {BaseAvatar} from "../lib/BaseAvatar.sol";

import {IAuraLocker} from "../interfaces/aura/IAuraLocker.sol";
import {IAuraToken} from "../interfaces/aura/IAuraToken.sol";
import {IBaseRewardPool} from "../interfaces/aura/IBaseRewardPool.sol";
import {IBooster} from "../interfaces/aura/IBooster.sol";
import {ICrvDepositorWrapper} from "../interfaces/aura/ICrvDepositorWrapper.sol";
import {IVault} from "../interfaces/badger/IVault.sol";
import {IAsset} from "../interfaces/balancer/IAsset.sol";
import {IBalancerVault} from "../interfaces/balancer/IBalancerVault.sol";
import {IPriceOracle} from "../interfaces/balancer/IPriceOracle.sol";
import {IAggregatorV3} from "../interfaces/chainlink/IAggregatorV3.sol";

contract AuraAvatar is BaseAvatar {
    ////////////////////////////////////////////////////////////////////////////
    // CONSTANTS
    ////////////////////////////////////////////////////////////////////////////

    uint256 public constant MAX_BPS = 10000;

    IBooster public constant BOOSTER = IBooster(0x7818A1DA7BD1E64c199029E86Ba244a9798eEE10);

    IBaseRewardPool public constant AURABAL_REWARDS = IBaseRewardPool(0x5e5ea2048475854a5702F5B8468A51Ba1296EFcC);

    uint256 public constant PID_80BADGER_20WBTC = 11;
    uint256 public constant PID_40WBTC_40DIGG_20GRAVIAURA = 18;

    IBaseRewardPool public constant BASE_REWARD_POOL_80BADGER_20WBTC =
        IBaseRewardPool(0x5e5ea2048475854a5702F5B8468A51Ba1296EFcC);
    IBaseRewardPool public constant BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA =
        IBaseRewardPool(0x5e5ea2048475854a5702F5B8468A51Ba1296EFcC);

    IBalancerVault public constant BALANCER_VAULT = IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    address public constant VOTER = address(0);

    // TODO: Do I need constants to be public?
    IAuraToken public constant AURA = IAuraToken(0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF);
    IERC20Upgradeable public constant BAL = IERC20Upgradeable(0xba100000625a3754423978a60c9317c58a424e3D);
    IERC20Upgradeable public constant WETH = IERC20Upgradeable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Upgradeable public constant USDC = IERC20Upgradeable(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20Upgradeable public constant AURABAL = IERC20Upgradeable(0x616e8BfA43F920657B3497DBf40D6b1A02D4608d);

    IVault public constant BAURABAL = IVault(0x37d9D2C6035b744849C15F1BFEE8F268a20fCBd8);
    IAuraLocker public constant AURA_LOCKER = IAuraLocker(0x3Fa73f1E5d8A792C80F426fc8F84FBF7Ce9bBCAC);

    ICrvDepositorWrapper public constant AURABAL_DEPOSIT_WRAPPER =
        ICrvDepositorWrapper(0x68655AD9852a99C87C0934c7290BB62CFa5D4123);

    bytes32 public constant BAL_WETH_POOL_ID = 0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014;
    // TODO: See if it makes sense to use other pool?
    bytes32 public constant AURA_WETH_POOL_ID = 0xc29562b045d80fd77c69bec09541f5c16fe20d9d000200000000000000000251; // 80AURA-20WETH
    bytes32 public constant USDC_WETH_POOL_ID = 0x96646936b91d6b9d7d0c47c496afbf3d6ec7b6f8000200000000000000000019;

    IAggregatorV3 constant BAL_USD_FEED = IAggregatorV3(0xdF2917806E30300537aEB49A7663062F4d1F2b5F);
    IAggregatorV3 constant ETH_USD_FEED = IAggregatorV3(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419);
    uint256 public constant USD_FEED_PRECISIONS = 1e8;

    IPriceOracle POOL_80AURA_20WETH = IPriceOracle(0xc29562b045D80fD77c69Bec09541F5c16fe20d9d);

    // TODO: No decimals
    uint256 public slippageToleranceBalToAuraBal;
    uint256 public slippageTol;

    ////////////////////////////////////////////////////////////////////////////
    // STORAGE
    ////////////////////////////////////////////////////////////////////////////

    uint256 public auraToUsdcBps;
    uint256 public balToUsdcBps;

    ////////////////////////////////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////////////////////////////////
    error StalePriceFeed();

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////
    // TODO: Events

    ////////////////////////////////////////////////////////////////////////////
    // INITIALIZATION
    ////////////////////////////////////////////////////////////////////////////

    function initialize(address globalAccessControl, address initialOwner) public initializer {
        __BaseAvatar_init(globalAccessControl, initialOwner);

        auraToUsdcBps = 3000; // 30%
        balToUsdcBps = 7000; // 70%

        slippageToleranceBalToAuraBal = 9950;
        slippageTol = 9825;

        // TODO: Approvals
        // Maybe dont't do unlimited approvals since contract can have arbitrary calls
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC VIEW
    ////////////////////////////////////////////////////////////////////////////

    /// @dev Returns the name of the strategy
    function getName() external pure returns (string memory name_) {
        name_ = "Aura_Avatar";
    }

    // TODO: Balance check and claimable reward check functions

    /// @dev Returns the name of the strategy
    function getBalance() external view returns (string memory) {
        return "Aura_Avatar";
    }

    /// @dev Returns the name of the strategy
    function getRewards() external view returns (string memory) {
        return "Aura_Avatar";
    }

    /// NOTE: Add custom avatar functions below

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Permissioned
    ////////////////////////////////////////////////////////////////////////////

    // TODO: Permissions
    function setBalToUsdcBps(uint256 _balToUsdcBps) external onlyOwner {
        balToUsdcBps = _balToUsdcBps;
    }

    // TODO: Permissions
    function setAuraToUsdcBps(uint256 _auraToUsdcBps) external onlyOwner {
        auraToUsdcBps = _auraToUsdcBps;
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Keeper
    ////////////////////////////////////////////////////////////////////////////

    // TODO: See if needs to be permissioned
    function depositAll() external {
        BOOSTER.depositAll(PID_80BADGER_20WBTC, true);
        BOOSTER.depositAll(PID_40WBTC_40DIGG_20GRAVIAURA, true);
    }

    function upKeep() external {
        // 1. Claim BAL and AURA rewards
        claimRewards();

        uint256 totalBal = BAL.balanceOf(address(this));
        uint256 totalAura = AURA.balanceOf(address(this));

        // 2. Swap some for USDC
        uint256 balForUsdc = totalBal * balToUsdcBps / MAX_BPS;
        uint256 auraForUsdc = totalAura * auraToUsdcBps / MAX_BPS;

        swapBalForUsdc(balForUsdc);
        swapAuraForUsdc(auraForUsdc);

        // 3. Swap remaining BAL for auraBAL
        uint256 balToDeposit = totalBal - balForUsdc;
        swapBalForAuraBal(balToDeposit);

        // 4. Lock remaining AURA on behalf of Badger voter msig
        uint256 auraToLock = totalAura - auraForUsdc;
        AURA_LOCKER.lock(VOTER, auraToLock);

        // 5. Dogfood auraBAL in Badger vault
        BAURABAL.depositAll();
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL
    ////////////////////////////////////////////////////////////////////////////

    function claimRewards() internal {
        // TODO: Should use AuraClaimZap?
        // NOTE: Anyone can claim rewards for contract
        BASE_REWARD_POOL_80BADGER_20WBTC.getReward();
        BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.getReward();
    }

    // TODO: See if can use pricer v3
    function swapBalForUsdc(uint256 _auraAmount) internal returns (uint256 usdcEarned) {
        IAsset[] memory assets = new IAsset[](3);
        assets[0] = IAsset(address(BAL));
        assets[1] = IAsset(address(WETH));
        assets[2] = IAsset(address(USDC));

        int256[] memory limits = new int256[](3);
        limits[0] = int256(_auraAmount);
        // TODO: From oracle
        limits[2] = int256(getBalAmountInUsdc(_auraAmount));

        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](2);
        // BAL --> WETH
        swaps[0] = IBalancerVault.BatchSwapStep({
            poolId: BAL_WETH_POOL_ID,
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: _auraAmount,
            userData: new bytes(0)
        });
        // WETH --> USDC
        swaps[1] = IBalancerVault.BatchSwapStep({
            poolId: USDC_WETH_POOL_ID,
            assetInIndex: 1,
            assetOutIndex: 2,
            amount: 0, // 0 means all from last step
            userData: new bytes(0)
        });

        IBalancerVault.FundManagement memory fundManagement = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        int256[] memory assetBalances = BALANCER_VAULT.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, swaps, assets, fundManagement, limits, type(uint256).max
        );

        usdcEarned = uint256(-assetBalances[assetBalances.length - 1]);
    }

    function swapAuraForUsdc(uint256 _auraAmount) internal returns (uint256 usdcEarned) {
        // TODO: See if it makes sense to use better of two pools
        IAsset[] memory assets = new IAsset[](3);
        assets[0] = IAsset(address(AURA));
        assets[1] = IAsset(address(WETH));
        assets[2] = IAsset(address(USDC));

        int256[] memory limits = new int256[](3);
        limits[0] = int256(_auraAmount);
        // TODO: From oracle
        limits[2] = int256(getAuraAmountInUsdc(_auraAmount));

        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](2);
        // AURA --> WETH
        swaps[0] = IBalancerVault.BatchSwapStep({
            poolId: AURA_WETH_POOL_ID,
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: _auraAmount,
            userData: new bytes(0)
        });
        // WETH --> USDC
        swaps[1] = IBalancerVault.BatchSwapStep({
            poolId: USDC_WETH_POOL_ID,
            assetInIndex: 1,
            assetOutIndex: 2,
            amount: 0, // 0 means all from last step
            userData: new bytes(0)
        });

        IBalancerVault.FundManagement memory fundManagement = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        int256[] memory assetBalances = BALANCER_VAULT.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN, swaps, assets, fundManagement, limits, type(uint256).max
        );

        usdcEarned = uint256(-assetBalances[assetBalances.length - 1]);
    }

    function swapBalForAuraBal(uint256 _auraAmount) internal {
        uint256 minAuraBalOut = AURABAL_DEPOSIT_WRAPPER.getMinOut(_auraAmount, slippageToleranceBalToAuraBal);
        AURABAL_DEPOSIT_WRAPPER.deposit(_auraAmount, minAuraBalOut, true, address(0));
        // TODO: See if can find optimal route on-chain
        /*
        # bpt out and swap estimation
        bpt_out = vault.balancer.get_amount_bpt_out(
            [bal, weth], [bal_to_deposit, 0], pool=b80bal_20weth
        ) * Decimal(SLIPPAGE)
        amt_pool_swapped_out = float(
            vault.balancer.get_amount_out(
                b80bal_20weth, auraBAL, bpt_out, pool=bauraBAL_stable
            )
            * Decimal(SLIPPAGE)
        )
        if amt_pool_swapped_out > wrapper_aurabal_out:
            vault.balancer.deposit_and_stake(
                [bal, weth], [bal_to_deposit, 0], pool=b80bal_20weth, stake=False
            )
            balance_bpt = b80bal_20weth.balanceOf(vault) * SLIPPAGE
            vault.balancer.swap(b80bal_20weth, auraBAL, balance_bpt, pool=bauraBAL_stable)
        */
    }

    function fetchPriceFromFeed(IAggregatorV3 _feed) internal view returns (uint256 answerUint256_) {
        (, int256 answer,, uint256 updateTime,) = _feed.latestRoundData();

        // TODO: Discard stale data
        if (block.timestamp - updateTime > type(uint256).max) {
            revert StalePriceFeed();
        }

        answerUint256_ = uint256(answer);
    }

    function fetchPriceFromBalancerTwap(IPriceOracle _pool) internal view returns (uint256 price_) {
        IPriceOracle.OracleAverageQuery[] memory queries = new IPriceOracle.OracleAverageQuery[](1);

        queries[0].variable = IPriceOracle.Variable.PAIR_PRICE;
        queries[0].secs = 3600; // last hour
        queries[0].ago = 0; // now

        // Gets the balancer time weighted average price denominated in BAL
        return _pool.getTimeWeightedAverage(queries)[0];
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL VIEW
    ////////////////////////////////////////////////////////////////////////////

    function getBalAmountInUsdc(uint256 _balAmount) internal view returns (uint256 usdcAmount_) {
        // NOTE: Assumes USDC is pegged to USD. If not, we should sell to a different stablecoin.
        // TODO: Check
        uint256 balInUsd = fetchPriceFromFeed(BAL_USD_FEED);
        usdcAmount_ = _balAmount * balInUsd / USD_FEED_PRECISIONS;
    }

    function getAuraAmountInUsdc(uint256 _auraAmount) internal view returns (uint256 usdcAmount_) {
        uint256 auraInEth = fetchPriceFromBalancerTwap(POOL_80AURA_20WETH);
        uint256 ethInUsd = fetchPriceFromFeed(ETH_USD_FEED);

        // TODO:
        usdcAmount_ = _auraAmount * auraInEth * ethInUsd / USD_FEED_PRECISIONS;
    }
}
