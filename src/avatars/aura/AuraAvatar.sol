// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {IERC20Upgradeable} from "openzeppelin-contracts-upgradeable/interfaces/IERC20Upgradeable.sol";
import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/security/PausableUpgradeable.sol";

import {BaseAvatar} from "../../lib/BaseAvatar.sol";
import {AuraConstants} from "./AuraConstants.sol";
import {AuraAvatarOracleUtils} from "./AuraAvatarOracleUtils.sol";

import {IBaseRewardPool} from "../../interfaces/aura/IBaseRewardPool.sol";
import {IAsset} from "../../interfaces/balancer/IAsset.sol";
import {IBalancerVault, JoinKind} from "../../interfaces/balancer/IBalancerVault.sol";
import {KeeperCompatibleInterface} from "../../interfaces/chainlink/KeeperCompatibleInterface.sol";

uint256 constant MAX_BPS = 10000;

struct TokenAmount {
    address token;
    uint256 amount;
}

contract AuraAvatar is
    BaseAvatar,
    AuraConstants,
    AuraAvatarOracleUtils,
    KeeperCompatibleInterface,
    PausableUpgradeable
{
    ////////////////////////////////////////////////////////////////////////////
    // CONSTANTS
    ////////////////////////////////////////////////////////////////////////////

    uint256 public constant PID_80BADGER_20WBTC = 11;
    uint256 public constant PID_40WBTC_40DIGG_20GRAVIAURA = 18;

    IERC20Upgradeable public constant BPT_80BADGER_20WBTC =
        IERC20Upgradeable(0xb460DAa847c45f1C4a41cb05BFB3b51c92e41B36);
    IERC20Upgradeable public constant BPT_40WBTC_40DIGG_20GRAVIAURA =
        IERC20Upgradeable(0x8eB6c82C3081bBBd45DcAC5afA631aaC53478b7C);

    IBaseRewardPool public constant BASE_REWARD_POOL_80BADGER_20WBTC =
        IBaseRewardPool(0xCea3aa5b2a50e39c7C7755EbFF1e9E1e1516D3f5);
    IBaseRewardPool public constant BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA =
        IBaseRewardPool(0x10Ca519614b0F3463890387c24819001AFfC5152);

    ////////////////////////////////////////////////////////////////////////////
    // STORAGE
    ////////////////////////////////////////////////////////////////////////////

    address public keeperRegistry;

    uint256 public balToUsdcBps;
    uint256 public auraToUsdcBps;

    uint256 public slippageTolToUsdc;
    uint256 public slippageTolBalToAuraBal;

    uint256 public lastClaimTimestamp;

    ////////////////////////////////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////////////////////////////////
    error OnlyKeeperRegistry();

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////
    // TODO: Events
    event KeeperRegistryUpdated(address keeperRegistry);
    event BalToUsdBpsUpdated(uint256 balToUsdcBps);
    event AuraToUsdBpsUpdated(uint256 auraToUsdcBps);
    event RewardsToStable(address indexed token, uint256 amount);
    event RewardClaimed(address indexed token, uint256 amount); // Or harvested

    ////////////////////////////////////////////////////////////////////////////
    // INITIALIZATION
    ////////////////////////////////////////////////////////////////////////////

    function initialize(address _owner) public initializer {
        __BaseAvatar_init(_owner);

        auraToUsdcBps = 3000; // 30%
        balToUsdcBps = 7000; // 70%

        slippageTolToUsdc = 9825; // 98.25%
        slippageTolBalToAuraBal = 9950; // 99.5%

        // booster approval for each bpt
        BPT_80BADGER_20WBTC.approve(address(AURA_BOOSTER), type(uint256).max);
        BPT_40WBTC_40DIGG_20GRAVIAURA.approve(
            address(AURA_BOOSTER),
            type(uint256).max
        );
        // aura locker approval
        AURA.approve(address(AURA_LOCKER), type(uint256).max);
        // aura bpt depositor approval - auraBAL
        B_80_BAL_20_WETH.approve(address(bptDepositor), type(uint256).max);
        // badger sett approval
        AURABAL.approve(address(BAURABAL), type(uint256).max);
        // balancer vaults approvals
        B_80_BAL_20_WETH.approve(address(BALANCER_VAULT), type(uint256).max);
        AURA.approve(address(BALANCER_VAULT), type(uint256).max);
        BAL.approve(address(BALANCER_VAULT), type(uint256).max);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC VIEW
    ////////////////////////////////////////////////////////////////////////////

    /// @dev Returns the name of the strategy
    function getName() external pure returns (string memory name_) {
        name_ = "Aura_Avatar";
    }

    function totalAssets() external view returns (uint256[2] memory assets_) {
        assets_[0] = BASE_REWARD_POOL_80BADGER_20WBTC.balanceOf(address(this));
        assets_[1] = BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.balanceOf(
            address(this)
        );
    }

    /// @dev Returns the name of the strategy
    function pendingRewards()
        external
        view
        returns (TokenAmount[2] memory rewards_)
    {
        uint256 balEarned = BASE_REWARD_POOL_80BADGER_20WBTC.earned(
            address(this)
        );
        balEarned += BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.earned(
            address(this)
        );

        rewards_[0] = TokenAmount(address(BAL), balEarned);
        rewards_[1] = TokenAmount(
            address(AURA),
            getMintableAuraRewards(balEarned)
        );
    }

    /// NOTE: Add custom avatar functions below

    ////////////////////////////////////////////////////////////////////////////
    // MODIFIERS
    ////////////////////////////////////////////////////////////////////////////

    modifier onlyKeeperRegistry() {
        if (msg.sender != keeperRegistry) {
            revert OnlyKeeperRegistry();
        }
        _;
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Permissioned
    ////////////////////////////////////////////////////////////////////////////

    // TODO: See if events should emit old value
    function setBalToUsdcBps(uint256 _balToUsdcBps) external onlyOwner {
        balToUsdcBps = _balToUsdcBps;

        emit BalToUsdBpsUpdated(_balToUsdcBps);
    }

    function setAuraToUsdcBps(uint256 _auraToUsdcBps) external onlyOwner {
        auraToUsdcBps = _auraToUsdcBps;

        emit AuraToUsdBpsUpdated(_auraToUsdcBps);
    }

    function setKeeperRegistry(address _keeperRegistry) external onlyOwner {
        keeperRegistry = _keeperRegistry;

        emit KeeperRegistryUpdated(_keeperRegistry);
    }

    function withdrawToOwner() external onlyOwner {
        uint256 bpt80Badger20WbtcDeposited = BASE_REWARD_POOL_80BADGER_20WBTC
            .balanceOf(address(this));
        if (bpt80Badger20WbtcDeposited > 0) {
            BASE_REWARD_POOL_80BADGER_20WBTC.withdrawAndUnwrap(
                bpt80Badger20WbtcDeposited,
                true
            );
        }
        uint256 bpt40Wbtc40Digg20GraviAuraDeposited = BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA
                .balanceOf(address(this));
        if (bpt40Wbtc40Digg20GraviAuraDeposited > 0) {
            BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.withdrawAndUnwrap(
                bpt40Wbtc40Digg20GraviAuraDeposited,
                true
            );
        }

        address ownerCached = owner();
        BPT_80BADGER_20WBTC.transfer(
            ownerCached,
            BPT_80BADGER_20WBTC.balanceOf(address(this))
        );
        BPT_40WBTC_40DIGG_20GRAVIAURA.transfer(
            ownerCached,
            BPT_40WBTC_40DIGG_20GRAVIAURA.balanceOf(address(this))
        );
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC
    ////////////////////////////////////////////////////////////////////////////

    function depositAll() external whenNotPaused {
        if (
            BASE_REWARD_POOL_80BADGER_20WBTC.balanceOf(address(this)) == 0 &&
            BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.balanceOf(
                address(this)
            ) ==
            0
        ) {
            // init the timestamp based on the 1st deposit
            lastClaimTimestamp = block.timestamp;
        }
        AURA_BOOSTER.depositAll(PID_80BADGER_20WBTC, true);
        AURA_BOOSTER.depositAll(PID_40WBTC_40DIGG_20GRAVIAURA, true);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Keeper
    ////////////////////////////////////////////////////////////////////////////

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory checkData)
    {
        if ((block.timestamp - lastClaimTimestamp) > CLAIM_CADENCE) {
            return (true, new bytes(0));
        }
    }

    function performUpkeep(bytes calldata performData)
        external
        override
        onlyKeeperRegistry
        whenNotPaused
    {
        if ((block.timestamp - lastClaimTimestamp) > CLAIM_CADENCE) {
            processRewards();
            lastClaimTimestamp = block.timestamp;
        }
    }

    function processRewards() internal {
        // 1. Claim BAL and AURA rewards
        claimRewards();

        uint256 totalBal = BAL.balanceOf(address(this));
        uint256 totalAura = AURA.balanceOf(address(this));

        // 2. Swap some for USDC
        uint256 balForUsdc = (totalBal * balToUsdcBps) / MAX_BPS;
        uint256 auraForUsdc = (totalAura * auraToUsdcBps) / MAX_BPS;

        uint256 usdcEarnedFromBal = swapBalForUsdc(balForUsdc);
        uint256 usdcEarnedFromAura = swapAuraForUsdc(auraForUsdc);

        // 3. Swap remaining BAL for auraBAL
        uint256 balToDeposit = totalBal - balForUsdc;
        swapBalForAuraBal(balToDeposit);

        // 4. Lock remaining AURA on behalf of Badger voter msig
        uint256 auraToLock = totalAura - auraForUsdc;
        AURA_LOCKER.lock(BADGER_VOTER, auraToLock);

        // 5. Dogfood auraBAL in Badger vault in behalf of vault
        BAURABAL.depositFor(owner(), AURABAL.balanceOf(address(this)));

        // events for metric analysis
        emit RewardClaimed(address(BAL), totalBal);
        emit RewardClaimed(address(AURA), totalAura);
        emit RewardsToStable(
            address(USDC),
            usdcEarnedFromBal + usdcEarnedFromAura
        );
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL
    ////////////////////////////////////////////////////////////////////////////

    function claimRewards() internal {
        if (BASE_REWARD_POOL_80BADGER_20WBTC.earned(address(this)) > 0) {
            BASE_REWARD_POOL_80BADGER_20WBTC.getReward();
        }

        if (
            BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.earned(address(this)) > 0
        ) {
            BASE_REWARD_POOL_40WBTC_40DIGG_20GRAVIAURA.getReward();
        }
    }

    // TODO: See if can use pricer v3
    function swapBalForUsdc(uint256 _balAmount)
        internal
        returns (uint256 usdcEarned)
    {
        IAsset[] memory assets = new IAsset[](3);
        assets[0] = IAsset(address(BAL));
        assets[1] = IAsset(address(WETH));
        assets[2] = IAsset(address(USDC));

        int256[] memory limits = new int256[](3);
        limits[0] = int256(_balAmount);
        limits[2] = int256(
            (getBalAmountInUsdc(_balAmount) * slippageTolToUsdc) / MAX_BPS
        );

        IBalancerVault.BatchSwapStep[]
            memory swaps = new IBalancerVault.BatchSwapStep[](2);
        // BAL --> WETH
        swaps[0] = IBalancerVault.BatchSwapStep({
            poolId: BAL_WETH_POOL_ID,
            assetInIndex: 0,
            assetOutIndex: 1,
            amount: _balAmount,
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

        IBalancerVault.FundManagement memory fundManagement = IBalancerVault
            .FundManagement({
                sender: address(this),
                fromInternalBalance: false,
                recipient: payable(address(this)),
                toInternalBalance: false
            });

        int256[] memory assetBalances = BALANCER_VAULT.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN,
            swaps,
            assets,
            fundManagement,
            limits,
            type(uint256).max
        );

        usdcEarned = uint256(-assetBalances[assetBalances.length - 1]);
    }

    function swapAuraForUsdc(uint256 _auraAmount)
        internal
        returns (uint256 usdcEarned)
    {
        // TODO: See if it makes sense to use better of two pools
        IAsset[] memory assets = new IAsset[](3);
        assets[0] = IAsset(address(AURA));
        assets[1] = IAsset(address(WETH));
        assets[2] = IAsset(address(USDC));

        int256[] memory limits = new int256[](3);
        limits[0] = int256(_auraAmount);
        limits[2] = int256(
            (getAuraAmountInUsdc(_auraAmount) * slippageTolToUsdc) / MAX_BPS
        );

        IBalancerVault.BatchSwapStep[]
            memory swaps = new IBalancerVault.BatchSwapStep[](2);
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

        IBalancerVault.FundManagement memory fundManagement = IBalancerVault
            .FundManagement({
                sender: address(this),
                fromInternalBalance: false,
                recipient: payable(address(this)),
                toInternalBalance: false
            });

        int256[] memory assetBalances = BALANCER_VAULT.batchSwap(
            IBalancerVault.SwapKind.GIVEN_IN,
            swaps,
            assets,
            fundManagement,
            limits,
            type(uint256).max
        );

        usdcEarned = uint256(-assetBalances[assetBalances.length - 1]);
    }

    function swapBptForAuraBal(uint256 _bptAmount) internal {
        IBalancerVault.SingleSwap memory swapParam = IBalancerVault.SingleSwap({
            poolId: AURABAL_BAL_ETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: IAsset(address(B_80_BAL_20_WETH)),
            assetOut: IAsset(address(AURABAL)),
            amount: _bptAmount,
            userData: new bytes(0)
        });

        IBalancerVault.FundManagement memory fundManagement = IBalancerVault
            .FundManagement({
                sender: address(this),
                fromInternalBalance: false,
                recipient: payable(address(this)),
                toInternalBalance: false
            });
        try
            BALANCER_VAULT.swap(
                swapParam,
                fundManagement,
                _bptAmount, // by sims should output more auraBAL than by direct depositing. worst 1:1
                type(uint256).max
            )
        returns (uint256) {} catch {
            // fallback, assuming that not even 1:1 was offered and pool is skewed in opposit direction
            bptDepositor.deposit(_bptAmount, true, address(0));
        }
    }

    function depositBalToBpt(uint256 _balAmount) internal {
        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(BAL));
        assets[1] = IAsset(address(WETH));

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = _balAmount;
        amountsIn[1] = 0;

        IBalancerVault.JoinPoolRequest memory request = IBalancerVault
            .JoinPoolRequest(
                assets,
                amountsIn,
                abi.encode(
                    JoinKind.TOKEN_IN_FOR_EXACT_BPT_OUT,
                    _getMinBpt(_balAmount),
                    0 // BAL index
                ),
                false
            );

        BALANCER_VAULT.joinPool(
            BAL_WETH_POOL_ID,
            address(this),
            address(this),
            request
        );
    }

    function swapBalForAuraBal(uint256 _balAmount) internal {
        // 1. Get bpt
        depositBalToBpt(_balAmount);

        // 2. Swap bpt for auraBAL or lock
        swapBptForAuraBal(B_80_BAL_20_WETH.balanceOf(address(this)));
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL VIEW
    ////////////////////////////////////////////////////////////////////////////

    // NOTE: Assumes USDC is pegged to USD. If not, we should sell to a different stablecoin.
    function getBalAmountInUsdc(uint256 _balAmount)
        internal
        view
        returns (uint256 usdcAmount_)
    {
        // TODO: Check
        uint256 balInUsd = fetchPriceFromClFeed(BAL_USD_FEED);
        usdcAmount_ = (_balAmount * balInUsd) / USD_FEED_PRECISIONS;
    }

    // NOTE: Assumes USDC is pegged to USD. If not, we should sell to a different stablecoin.
    function getAuraAmountInUsdc(uint256 _auraAmount)
        internal
        view
        returns (uint256 usdcAmount_)
    {
        uint256 auraInEth = fetchPriceFromBalancerTwap(POOL_80AURA_20WETH);
        uint256 ethInUsd = fetchPriceFromClFeed(ETH_USD_FEED);

        usdcAmount_ =
            (_auraAmount * auraInEth * ethInUsd) /
            USD_FEED_PRECISIONS /
            AURA_WETH_TWAP_PRECISION;
    }

    function _getMinBpt(uint256 _balAmount)
        internal
        view
        returns (uint256 minOut)
    {
        uint256 bptOraclePrice = fetchBptPriceFromBalancerTwap(
            POOL_80BAL_20WETH
        );

        minOut =
            (((_balAmount * 1e18) / bptOraclePrice) * slippageTolBalToAuraBal) /
            MAX_BPS;
    }

    /// @notice Returns the expected amount of AURA to be minted given an amount of BAL rewards
    /// @dev ref: https://etherscan.io/address/0xc0c293ce456ff0ed870add98a0828dd4d2903dbf#code#F1#L86
    function getMintableAuraRewards(uint256 _balAmount)
        internal
        view
        returns (uint256 amount)
    {
        // NOTE: Only correct if AURA.minterMinted() == 0
        //       minterMinted is a private var in the contract, so we can't access it directly
        uint256 emissionsMinted = AURA.totalSupply() - AURA.INIT_MINT_AMOUNT();

        uint256 cliff = emissionsMinted / AURA.reductionPerCliff();
        uint256 totalCliffs = AURA.totalCliffs();

        if (cliff < totalCliffs) {
            uint256 reduction = (((totalCliffs - cliff) * 5) / 2) + 700;
            amount = (_balAmount * reduction) / totalCliffs;

            uint256 amtTillMax = AURA.EMISSIONS_MAX_SUPPLY() - emissionsMinted;
            if (amount > amtTillMax) {
                amount = amtTillMax;
            }
        }
    }
}
