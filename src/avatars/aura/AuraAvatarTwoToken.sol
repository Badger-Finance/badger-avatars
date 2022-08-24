// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {IERC20Upgradeable} from "openzeppelin-contracts-upgradeable/interfaces/IERC20Upgradeable.sol";
import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/security/PausableUpgradeable.sol";

import {BaseAvatar} from "../../lib/BaseAvatar.sol";
import {AuraConstants} from "./AuraConstants.sol";
import {AuraAvatarOracleUtils} from "./AuraAvatarOracleUtils.sol";
import {MAX_BPS, KEEPER_REGISTRY} from "../BaseConstants.sol";

import {IBaseRewardPool} from "../../interfaces/aura/IBaseRewardPool.sol";
import {IAsset} from "../../interfaces/balancer/IAsset.sol";
import {IBalancerVault, JoinKind} from "../../interfaces/balancer/IBalancerVault.sol";
import {IPriceOracle} from "../../interfaces/balancer/IPriceOracle.sol";
import {KeeperCompatibleInterface} from "../../interfaces/chainlink/KeeperCompatibleInterface.sol";

struct TokenAmount {
    address token;
    uint256 amount;
}

// TODO: Contract should never hold funds?
//       Natspec
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

    IERC20Upgradeable public immutable asset1;
    IERC20Upgradeable public immutable asset2;

    IBaseRewardPool public immutable baseRewardPool1;
    IBaseRewardPool public immutable baseRewardPool2;

    ////////////////////////////////////////////////////////////////////////////
    // STORAGE
    ////////////////////////////////////////////////////////////////////////////

    address public keeperRegistry;

    uint256 public sellBpsBalToUsd;
    uint256 public sellBpsAuraToUsd;

    uint256 public minOutBpsBalToUsd;
    uint256 public minOutBpsAuraToUsd;
    uint256 public minOutBpsBalToAuraBal;

    uint256 public lastClaimTimestamp;

    ////////////////////////////////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////////////////////////////////

    error NothingToDeposit();
    error NoRewardsToProcess();
    error NotKeeperRegistry(address caller);
    error InvalidBps(uint256 bps);

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

    event KeeperRegistryUpdated(address indexed oldKeeperRegistry, address indexed newKeeperRegistry);

    event SellBpsBalToUsdUpdated(uint256 oldValue, uint256 newValue);
    event SellBpsAuraToUsdUpdated(uint256 oldValue, uint256 newValue);

    event MinOutBpsBalToUsdUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsAuraToUsdUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsBalToAuraBalUpdated(uint256 oldValue, uint256 newValue);

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

        asset1 = IERC20Upgradeable(lpToken1);
        asset2 = IERC20Upgradeable(lpToken2);

        baseRewardPool1 = IBaseRewardPool(crvRewards1);
        baseRewardPool2 = IBaseRewardPool(crvRewards2);
    }

    function initialize(address _owner) public initializer {
        __BaseAvatar_init(_owner);
        __Pausable_init();

        keeperRegistry = KEEPER_REGISTRY;

        sellBpsAuraToUsd = 3000; // 30%
        sellBpsBalToUsd = 7000; // 70%

        minOutBpsBalToUsd = 9825; // 98.25%
        minOutBpsAuraToUsd = 9825; // 98.25%
        minOutBpsBalToAuraBal = 9950; // 99.5%

        // Booster approval for both bpt
        asset1.approve(address(AURA_BOOSTER), type(uint256).max);
        asset2.approve(address(AURA_BOOSTER), type(uint256).max);

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

    function assets() external view returns (IERC20Upgradeable[2] memory assets_) {
        assets_[0] = asset1;
        assets_[1] = asset2;
    }

    function totalAssets() external view returns (uint256[2] memory assetAmounts_) {
        assetAmounts_[0] = baseRewardPool1.balanceOf(address(this));
        assetAmounts_[1] = baseRewardPool2.balanceOf(address(this));
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
            revert NotKeeperRegistry(msg.sender);
        }
        _;
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner - Pausing
    ////////////////////////////////////////////////////////////////////////////

    // TODO: See if move up hierarchy
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner - Config
    ////////////////////////////////////////////////////////////////////////////

    function setSellBpsBalToUsd(uint256 _sellBpsBalToUsd) external onlyOwner {
        if (_sellBpsBalToUsd > MAX_BPS) {
            revert InvalidBps(_sellBpsBalToUsd);
        }

        uint256 oldSellBpsBalToUsd = sellBpsBalToUsd;
        sellBpsBalToUsd = _sellBpsBalToUsd;

        emit SellBpsBalToUsdUpdated(oldSellBpsBalToUsd, _sellBpsBalToUsd);
    }

    function setSellBpsAuraToUsd(uint256 _sellBpsAuraToUsd) external onlyOwner {
        if (_sellBpsAuraToUsd > MAX_BPS) {
            revert InvalidBps(_sellBpsAuraToUsd);
        }

        uint256 oldSellBpsAuraToUsd = sellBpsAuraToUsd;
        sellBpsAuraToUsd = _sellBpsAuraToUsd;

        emit SellBpsAuraToUsdUpdated(oldSellBpsAuraToUsd, _sellBpsAuraToUsd);
    }

    function setMinOutBpsBalToUsd(uint256 _minOutBpsBalToUsd) external onlyOwner {
        if (_minOutBpsBalToUsd > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToUsd);
        }

        uint256 oldMinOutBpsBalToUsd = minOutBpsBalToUsd;
        minOutBpsBalToUsd = _minOutBpsBalToUsd;

        emit MinOutBpsBalToUsdUpdated(oldMinOutBpsBalToUsd, _minOutBpsBalToUsd);
    }

    function setMinOutBpsAuraToUsd(uint256 _minOutBpsAuraToUsd) external onlyOwner {
        if (_minOutBpsAuraToUsd > MAX_BPS) {
            revert InvalidBps(_minOutBpsAuraToUsd);
        }

        uint256 oldMinOutBpsAuraToUsd = minOutBpsAuraToUsd;
        minOutBpsAuraToUsd = _minOutBpsAuraToUsd;

        emit MinOutBpsAuraToUsdUpdated(oldMinOutBpsAuraToUsd, _minOutBpsAuraToUsd);
    }

    function setMinOutBpsBalToAuraBal(uint256 _minOutBpsBalToAuraBal) external onlyOwner {
        if (_minOutBpsBalToAuraBal > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToAuraBal);
        }

        uint256 oldMinOutBpsBalToAuraBal = minOutBpsBalToAuraBal;
        minOutBpsBalToAuraBal = _minOutBpsBalToAuraBal;

        emit MinOutBpsBalToAuraBalUpdated(oldMinOutBpsBalToAuraBal, _minOutBpsBalToAuraBal);
    }

    function setKeeperRegistry(address _keeperRegistry) external onlyOwner {
        address oldKeeperRegistry = keeperRegistry;

        keeperRegistry = _keeperRegistry;
        emit KeeperRegistryUpdated(oldKeeperRegistry, _keeperRegistry);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner
    ////////////////////////////////////////////////////////////////////////////

    // TODO: Events
    function deposit(uint256 _amountBpt1, uint256 _amountBpt2) external onlyOwner {
        if (_amountBpt1 == 0 && _amountBpt2 == 0) {
            revert NothingToDeposit();
        }

        uint256 bptDeposited1 = baseRewardPool1.balanceOf(address(this));
        uint256 bptDeposited2 = baseRewardPool2.balanceOf(address(this));
        if (bptDeposited1 == 0 && bptDeposited2 == 0) {
            // Initialize at first deposit
            lastClaimTimestamp = block.timestamp;
        }

        if (_amountBpt1 > 0) {
            asset1.transferFrom(msg.sender, address(this), _amountBpt1);
            AURA_BOOSTER.deposit(pid1, _amountBpt1, true);
        }
        if (_amountBpt2 > 0) {
            asset2.transferFrom(msg.sender, address(this), _amountBpt2);
            AURA_BOOSTER.deposit(pid2, _amountBpt2, true);
        }
    }

    // TODO: Events
    function withdrawAll() external onlyOwner {
        uint256 bptDeposited1 = baseRewardPool1.balanceOf(address(this));
        if (bptDeposited1 > 0) {
            baseRewardPool1.withdrawAndUnwrap(bptDeposited1, true);
        }
        uint256 bptDeposited2 = baseRewardPool2.balanceOf(address(this));
        if (bptDeposited2 > 0) {
            baseRewardPool2.withdrawAndUnwrap(bptDeposited2, true);
        }

        address ownerCached = owner();
        asset1.transfer(ownerCached, asset1.balanceOf(address(this)));
        asset2.transfer(ownerCached, asset2.balanceOf(address(this)));
    }

    function processRewards() external onlyOwner {
        processRewardsInternal();
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Keeper
    ////////////////////////////////////////////////////////////////////////////

    // TODO: Maybe do based on roles + allow owner
    function performUpkeep(bytes calldata) external override onlyKeeperRegistry whenNotPaused {
        if ((block.timestamp - lastClaimTimestamp) > CLAIM_CADENCE) {
            // Would revert if there's nothing to claim
            processRewardsInternal();
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

    function processRewardsInternal() internal {
        // Update last claimed time
        lastClaimTimestamp = block.timestamp;

        address ownerCached = owner();

        // 1. Claim BAL and AURA rewards
        claimRewards();

        uint256 totalBal = BAL.balanceOf(address(this));
        uint256 totalAura = AURA.balanceOf(address(this));

        if (totalBal == 0) {
            revert NoRewardsToProcess();
        }

        // 2. Swap some for USDC
        uint256 balForUsdc = (totalBal * sellBpsBalToUsd) / MAX_BPS;
        uint256 auraForUsdc = (totalAura * sellBpsAuraToUsd) / MAX_BPS;

        uint256 usdcEarnedFromBal = swapBalForUsdc(balForUsdc);
        uint256 usdcEarnedFromAura = swapAuraForUsdc(auraForUsdc);

        USDC.transfer(ownerCached, USDC.balanceOf(address(this)));

        // 3. Deposit remaining BAL to 80BAL-20ETH BPT
        uint256 balToDeposit = totalBal - balForUsdc;
        depositBalToBpt(balToDeposit);

        // 4. Swap BPT for auraBAL or lock
        uint256 balEthBptAmount = BPT_80BAL_20WETH.balanceOf(address(this));
        swapBptForAuraBal(balEthBptAmount);

        // 5. Dogfood auraBAL in Badger vault in behalf of owner
        BAURABAL.depositFor(ownerCached, AURABAL.balanceOf(address(this)));

        // 6. Lock remaining AURA on behalf of Badger voter msig
        uint256 auraToLock = totalAura - auraForUsdc;
        AURA_LOCKER.lock(BADGER_VOTER, auraToLock);

        // Emit events for analysis
        // TODO: Do I need address(this)? Is block.number redundant?
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
        IAsset[] memory assetArray = new IAsset[](3);
        assetArray[0] = IAsset(address(BAL));
        assetArray[1] = IAsset(address(WETH));
        assetArray[2] = IAsset(address(USDC));

        int256[] memory limits = new int256[](3);
        limits[0] = int256(_balAmount);
        // Assumes USDC is pegged. We should sell for other stableecoins if not
        limits[2] = int256((getBalAmountInUsd(_balAmount) * minOutBpsBalToUsd) / MAX_BPS); //
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
            IBalancerVault.SwapKind.GIVEN_IN, swaps, assetArray, fundManagement, limits, type(uint256).max
        );

        usdcEarned = uint256(-assetBalances[assetBalances.length - 1]);
    }

    function swapAuraForUsdc(uint256 _auraAmount) internal returns (uint256 usdcEarned) {
        // TODO: See if it makes sense to use better of two pools
        IAsset[] memory assetArray = new IAsset[](3);
        assetArray[0] = IAsset(address(AURA));
        assetArray[1] = IAsset(address(WETH));
        assetArray[2] = IAsset(address(USDC));

        int256[] memory limits = new int256[](3);
        limits[0] = int256(_auraAmount);
        // Assumes USDC is pegged. We should sell for other stableecoins if not
        limits[2] = int256((getAuraAmountInUsd(_auraAmount) * minOutBpsAuraToUsd) / MAX_BPS);

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
            IBalancerVault.SwapKind.GIVEN_IN, swaps, assetArray, fundManagement, limits, type(uint256).max
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
        IAsset[] memory assetArray = new IAsset[](2);
        assetArray[0] = IAsset(address(BAL));
        assetArray[1] = IAsset(address(WETH));

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = _balAmount;
        maxAmountsIn[1] = 0;

        BALANCER_VAULT.joinPool(
            BAL_WETH_POOL_ID,
            address(this),
            address(this),
            IBalancerVault.JoinPoolRequest({
                assets: assetArray,
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

    function getBalAmountInUsd(uint256 _balAmount) internal view returns (uint256 usdcAmount_) {
        // TODO: Check
        uint256 balInUsd = fetchPriceFromClFeed(BAL_USD_FEED);
        usdcAmount_ = (_balAmount * balInUsd) / USD_FEED_PRECISIONS;
    }

    function getAuraAmountInUsd(uint256 _auraAmount) internal view returns (uint256 usdcAmount_) {
        uint256 auraInEth = fetchPriceFromBalancerTwap(BPT_80AURA_20WETH);
        uint256 ethInUsd = fetchPriceFromClFeed(ETH_USD_FEED);

        usdcAmount_ = (_auraAmount * auraInEth * ethInUsd) / USD_FEED_PRECISIONS / AURA_WETH_TWAP_PRECISION;
    }

    function getMinBpt(uint256 _balAmount) internal view returns (uint256 minOut_) {
        uint256 bptOraclePrice = fetchBptPriceFromBalancerTwap(IPriceOracle(address(BPT_80BAL_20WETH)));

        minOut_ = (((_balAmount * 1e18) / bptOraclePrice) * minOutBpsBalToAuraBal) / MAX_BPS;
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
