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
import {IPriceOracle} from "../../interfaces/balancer/IPriceOracle.sol";
import {KeeperCompatibleInterface} from "../../interfaces/chainlink/KeeperCompatibleInterface.sol";

uint256 constant MAX_BPS = 10000;

struct TokenAmount {
    address token;
    uint256 amount;
}

contract AuraAvatarTwoToken is
    BaseAvatar,
    PausableUpgradeable, // TODO: See if move pausable to base
    AuraConstants,
    AuraAvatarOracleUtils,
    KeeperCompatibleInterface
{
    ////////////////////////////////////////////////////////////////////////////
    // CONSTANTS
    ////////////////////////////////////////////////////////////////////////////

    // TODO: Maybe move to storage settable by owner
    uint256 internal constant CLAIM_CADENCE = 1 weeks;

    ////////////////////////////////////////////////////////////////////////////
    // IMMUTABLES
    ////////////////////////////////////////////////////////////////////////////

    uint256 public immutable pid1;
    uint256 public immutable pid2;

    IERC20Upgradeable public immutable bpt1;
    IERC20Upgradeable public immutable bpt2;

    IBaseRewardPool public immutable baseRewardPool1;
    IBaseRewardPool public immutable baseRewardPool2;

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
    error NothingToDeposit();
    error NoRewardsToProcess();
    error OnlyKeeperRegistry();
    error InvalidBps(uint256 bps);

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////
    event KeeperRegistryUpdated(address indexed oldKeeperRegistry, address indexed newKeeperRegistry);
    event BalToUsdBpsUpdated(uint256 oldBalToUsdcBps, uint256 newBalToUsdcBps);
    event AuraToUsdBpsUpdated(uint256 oldAuraToUsdcBps, uint256 newAuraToUsdcBps);
    event RewardsToStable(
        address indexed source, address indexed token, uint256 amount, uint256 indexed blockNumber, uint256 timestamp
    );
    event RewardClaimed(
        address indexed source, address indexed token, uint256 amount, uint256 indexed blockNumber, uint256 timestamp
    );

    ////////////////////////////////////////////////////////////////////////////
    // INITIALIZATION
    ////////////////////////////////////////////////////////////////////////////

    constructor(uint256 _pid1, uint256 _pid2) {
        pid1 = _pid1;
        pid2 = _pid2;

        (address lpToken1,,, address crvRewards1,,) = AURA_BOOSTER.poolInfo(_pid1);
        (address lpToken2,,, address crvRewards2,,) = AURA_BOOSTER.poolInfo(_pid2);

        bpt1 = IERC20Upgradeable(lpToken1);
        bpt2 = IERC20Upgradeable(lpToken2);

        baseRewardPool1 = IBaseRewardPool(crvRewards1);
        baseRewardPool2 = IBaseRewardPool(crvRewards2);
    }

    function initialize(address _owner) public initializer {
        __BaseAvatar_init(_owner);
        __Pausable_init();

        auraToUsdcBps = 3000; // 30%
        balToUsdcBps = 7000; // 70%

        slippageTolToUsdc = 9825; // 98.25%
        slippageTolBalToAuraBal = 9950; // 99.5%

        // Booster approval for both bpt
        bpt1.approve(address(AURA_BOOSTER), type(uint256).max);
        bpt2.approve(address(AURA_BOOSTER), type(uint256).max);

        // Balancer vault approvals
        BAL.approve(address(BALANCER_VAULT), type(uint256).max);
        AURA.approve(address(BALANCER_VAULT), type(uint256).max);
        BPT_80BAL_20WETH.approve(address(BALANCER_VAULT), type(uint256).max);

        AURA.approve(address(AURA_LOCKER), type(uint256).max);

        BPT_80BAL_20WETH.approve(address(AURABAL_DEPOSITOR), type(uint256).max);
        AURABAL.approve(address(BAURABAL), type(uint256).max);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC VIEW
    ////////////////////////////////////////////////////////////////////////////

    // TODO: See if better name
    /// @dev Returns the name of the strategy
    function getName() external pure returns (string memory name_) {
        name_ = "Aura_Avatar";
    }

    function totalAssets() external view returns (TokenAmount[2] memory assets_) {
        assets_[0] = TokenAmount(address(bpt1), baseRewardPool1.balanceOf(address(this)));
        assets_[1] = TokenAmount(address(bpt2), baseRewardPool2.balanceOf(address(this)));
    }

    /// @dev Returns the name of the strategy
    function pendingRewards() external view returns (TokenAmount[2] memory rewards_) {
        uint256 balEarned = baseRewardPool1.earned(address(this));
        balEarned += baseRewardPool2.earned(address(this));

        rewards_[0] = TokenAmount(address(BAL), balEarned);
        rewards_[1] = TokenAmount(address(AURA), getMintableAuraRewards(balEarned));
    }

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
    // PUBLIC: Owner
    ////////////////////////////////////////////////////////////////////////////

    // TODO: See if move up hierarchy
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setBalToUsdcBps(uint256 _balToUsdcBps) external onlyOwner {
        if (_auraToUsdcBps > MAX_BPS) {
            revert InvalidBps(_balToUsdcBps);
        }

        uint256 oldBalToUsdcBps = balToUsdcBps;
        balToUsdcBps = _balToUsdcBps;

        emit BalToUsdBpsUpdated(oldBalToUsdcBps, _balToUsdcBps);
    }

    function setAuraToUsdcBps(uint256 _auraToUsdcBps) external onlyOwner {
        if (_auraToUsdcBps > MAX_BPS) {
            revert InvalidBps(_auraToUsdcBps);
        }

        uint256 oldAuraToUsdcBps = auraToUsdcBps;
        auraToUsdcBps = _auraToUsdcBps;

        emit AuraToUsdBpsUpdated(oldAuraToUsdcBps, _auraToUsdcBps);
    }

    function setKeeperRegistry(address _keeperRegistry) external onlyOwner {
        address oldKeeperRegistry = keeperRegistry;

        keeperRegistry = _keeperRegistry;
        emit KeeperRegistryUpdated(oldKeeperRegistry, _keeperRegistry);
    }

    function withdrawToOwner() external onlyOwner {
        uint256 bptDeposited1 = baseRewardPool1.balanceOf(address(this));
        if (bptDeposited1 > 0) {
            baseRewardPool1.withdrawAndUnwrap(bptDeposited1, true);
        }
        uint256 bptDeposited2 = baseRewardPool2.balanceOf(address(this));
        if (bptDeposited2 > 0) {
            baseRewardPool2.withdrawAndUnwrap(bptDeposited2, true);
        }

        address ownerCached = owner();
        bpt1.transfer(ownerCached, bpt1.balanceOf(address(this)));
        bpt2.transfer(ownerCached, bpt2.balanceOf(address(this)));
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC
    ////////////////////////////////////////////////////////////////////////////

    function depositAll() external whenNotPaused {
        uint256 bptBalance1 = bpt1.balanceOf(address(this));
        uint256 bptBalance2 = bpt2.balanceOf(address(this));

        if (bptBalance1 == 0 && bptBalance2 == 0) {
            revert NothingToDeposit();
        }

        uint256 bptDeposited1 = baseRewardPool1.balanceOf(address(this));
        uint256 bptDeposited2 = baseRewardPool2.balanceOf(address(this));
        if (bptDeposited1 == 0 && bptDeposited2 == 0) {
            // init the timestamp based on the 1st deposit
            lastClaimTimestamp = block.timestamp;
        }

        if (bptBalance1 > 0) {
            AURA_BOOSTER.deposit(pid1, bptBalance1, true);
        }
        if (bptBalance2 > 0) {
            AURA_BOOSTER.deposit(pid2, bptBalance2, true);
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Keeper
    ////////////////////////////////////////////////////////////////////////////

    // TODO: Maybe do based on roles + allow owner
    function performUpkeep(bytes calldata) external override onlyKeeperRegistry whenNotPaused {
        if ((block.timestamp - lastClaimTimestamp) > CLAIM_CADENCE) {
            // Would revert if there's nothing to claim
            processRewards();
            lastClaimTimestamp = block.timestamp;
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC VIEW
    ////////////////////////////////////////////////////////////////////////////

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded_, bytes memory) {
        uint256 balPending1 = baseRewardPool1.earned(address(this));
        uint256 balPending2 = baseRewardPool2.earned(address(this));

        uint256 balBalance = BAL.balanceOf(address(this));

        if ((block.timestamp - lastClaimTimestamp) > CLAIM_CADENCE) {
            if (balPending1 == 0 && balPending2 == 0 && balBalance == 0) {
                upkeepNeeded_ = false;
            } else {
                upkeepNeeded_ = true;
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL
    ////////////////////////////////////////////////////////////////////////////

    function processRewards() internal {
        // 1. Claim BAL and AURA rewards
        claimRewards();

        uint256 totalBal = BAL.balanceOf(address(this));
        uint256 totalAura = AURA.balanceOf(address(this));

        if (totalBal == 0) {
            revert NoRewardsToProcess();
        }

        // 2. Swap some for USDC
        uint256 balForUsdc = (totalBal * balToUsdcBps) / MAX_BPS;
        uint256 auraForUsdc = (totalAura * auraToUsdcBps) / MAX_BPS;

        uint256 usdcEarnedFromBal = swapBalForUsdc(balForUsdc);
        uint256 usdcEarnedFromAura = swapAuraForUsdc(auraForUsdc);

        // 3. Deposit remaining BAL to 80BAL-20ETH BPT
        uint256 balToDeposit = totalBal - balForUsdc;
        depositBalToBpt(balToDeposit);

        // 4. Swap BPT for auraBAL or lock
        uint256 balEthBptAmount = BPT_80BAL_20WETH.balanceOf(address(this));
        swapBptForAuraBal(balEthBptAmount);

        // 5. Lock remaining AURA on behalf of Badger voter msig
        uint256 auraToLock = totalAura - auraForUsdc;
        AURA_LOCKER.lock(BADGER_VOTER, auraToLock);

        // 6. Dogfood auraBAL in Badger vault in behalf of vault
        BAURABAL.depositFor(owner(), AURABAL.balanceOf(address(this)));

        // events for metric analysis
        emit RewardClaimed(address(this), address(BAL), totalBal, block.number, block.timestamp);
        emit RewardClaimed(address(this), address(AURA), totalAura, block.number, block.timestamp);
        emit RewardsToStable(
            address(this), address(USDC), usdcEarnedFromBal + usdcEarnedFromAura, block.number, block.timestamp
            );
    }

    // Shouldn't revert since others can claim for this contract
    function claimRewards() internal {
        if (baseRewardPool1.earned(address(this)) > 0) {
            baseRewardPool1.getReward();
        }

        if (baseRewardPool2.earned(address(this)) > 0) {
            baseRewardPool2.getReward();
        }
    }

    // TODO: See if can use pricer v3
    function swapBalForUsdc(uint256 _balAmount) internal returns (uint256 usdcEarned) {
        IAsset[] memory assets = new IAsset[](3);
        assets[0] = IAsset(address(BAL));
        assets[1] = IAsset(address(WETH));
        assets[2] = IAsset(address(USDC));

        int256[] memory limits = new int256[](3);
        limits[0] = int256(_balAmount);
        limits[2] = int256((getBalAmountInUsdc(_balAmount) * slippageTolToUsdc) / MAX_BPS);

        IBalancerVault.BatchSwapStep[] memory swaps = new IBalancerVault.BatchSwapStep[](2);
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
        limits[2] = int256((getAuraAmountInUsdc(_auraAmount) * slippageTolToUsdc) / MAX_BPS);

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

    // TODO: Check this
    function swapBptForAuraBal(uint256 _bptAmount) internal {
        IBalancerVault.SingleSwap memory swapParam = IBalancerVault.SingleSwap({
            poolId: AURABAL_BAL_ETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: IAsset(address(BPT_80BAL_20WETH)),
            assetOut: IAsset(address(AURABAL)),
            amount: _bptAmount,
            userData: new bytes(0)
        });

        IBalancerVault.FundManagement memory fundManagement = IBalancerVault.FundManagement({
            sender: address(this),
            fromInternalBalance: false,
            recipient: payable(address(this)),
            toInternalBalance: false
        });

        try BALANCER_VAULT.swap(
            swapParam,
            fundManagement,
            _bptAmount, // by sims should output more auraBAL than by direct depositing. worst 1:1
            type(uint256).max
        ) returns (uint256) {} catch {
            // fallback, assuming that not even 1:1 was offered and pool is skewed in opposit direction
            AURABAL_DEPOSITOR.deposit(_bptAmount, true, address(0));
        }
    }

    // TODO: Check minOut
    function depositBalToBpt(uint256 _balAmount) internal {
        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(BAL));
        assets[1] = IAsset(address(WETH));

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = _balAmount;
        maxAmountsIn[1] = 0;

        BALANCER_VAULT.joinPool(
            BAL_WETH_POOL_ID,
            address(this),
            address(this),
            IBalancerVault.JoinPoolRequest({
                assets: assets,
                maxAmountsIn: maxAmountsIn,
                userData: abi.encode(
                    JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
                    maxAmountsIn,
                    getMinBpt(_balAmount) // minOut
                ),
                fromInternalBalance: false
            })
        );
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL VIEW
    ////////////////////////////////////////////////////////////////////////////

    // NOTE: Assumes USDC is pegged to USD. If not, we should sell to a different stablecoin.
    function getBalAmountInUsdc(uint256 _balAmount) internal view returns (uint256 usdcAmount_) {
        // TODO: Check
        uint256 balInUsd = fetchPriceFromClFeed(BAL_USD_FEED);
        usdcAmount_ = (_balAmount * balInUsd) / USD_FEED_PRECISIONS;
    }

    // NOTE: Assumes USDC is pegged to USD. If not, we should sell to a different stablecoin.
    function getAuraAmountInUsdc(uint256 _auraAmount) internal view returns (uint256 usdcAmount_) {
        uint256 auraInEth = fetchPriceFromBalancerTwap(BPT_80AURA_20WETH);
        uint256 ethInUsd = fetchPriceFromClFeed(ETH_USD_FEED);

        usdcAmount_ = (_auraAmount * auraInEth * ethInUsd) / USD_FEED_PRECISIONS / AURA_WETH_TWAP_PRECISION;
    }

    function getMinBpt(uint256 _balAmount) internal view returns (uint256 minOut_) {
        uint256 bptOraclePrice = fetchBptPriceFromBalancerTwap(IPriceOracle(address(BPT_80BAL_20WETH)));

        minOut_ = (((_balAmount * 1e18) / bptOraclePrice) * slippageTolBalToAuraBal) / MAX_BPS;
    }

    /// @notice Returns the expected amount of AURA to be minted given an amount of BAL rewards
    /// @dev ref: https://etherscan.io/address/0xc0c293ce456ff0ed870add98a0828dd4d2903dbf#code#F1#L86
    function getMintableAuraRewards(uint256 _balAmount) internal view returns (uint256 amount) {
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
