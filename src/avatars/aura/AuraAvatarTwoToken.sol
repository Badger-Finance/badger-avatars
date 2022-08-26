// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {IERC20Upgradeable} from "openzeppelin-contracts-upgradeable/interfaces/IERC20Upgradeable.sol";
import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/security/PausableUpgradeable.sol";

import {BaseAvatar} from "../../lib/BaseAvatar.sol";
import {AuraConstants} from "./AuraConstants.sol";
import {AuraAvatarOracleUtils} from "./AuraAvatarOracleUtils.sol";
import {MAX_BPS, PRECISION} from "../BaseConstants.sol";

import {IBaseRewardPool} from "../../interfaces/aura/IBaseRewardPool.sol";
import {IAsset} from "../../interfaces/balancer/IAsset.sol";
import {IBalancerVault, JoinKind} from "../../interfaces/balancer/IBalancerVault.sol";
import {IPriceOracle} from "../../interfaces/balancer/IPriceOracle.sol";
import {KeeperCompatibleInterface} from "../../interfaces/chainlink/KeeperCompatibleInterface.sol";

struct TokenAmount {
    address token;
    uint256 amount;
}

// TODO: Storage packing?
struct BpsConfig {
    uint256 val;
    uint256 min;
}

// TODO: Natspec
// NOTE: Ideally, contract should never hold funds
contract AuraAvatarTwoToken is
    BaseAvatar,
    PausableUpgradeable, // TODO: See if move pausable to base
    AuraConstants,
    AuraAvatarOracleUtils,
    KeeperCompatibleInterface
{
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

    address public manager;
    address public keeper;

    uint256 public claimFrequency;

    uint256 public sellBpsBalToUsdc;
    uint256 public sellBpsAuraToUsdc;

    BpsConfig public minOutBpsBalToUsdc;
    BpsConfig public minOutBpsAuraToUsdc;

    BpsConfig public minOutBpsBalToBpt;

    uint256 public lastClaimTimestamp;

    ////////////////////////////////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////////////////////////////////

    error NotOwnerOrManager(address caller);
    error NotKeeper(address caller);

    error InvalidBps(uint256 bps);
    error LessThanMinBps(uint256 bps, uint256 minBps);

    error NothingToDeposit();
    error NoRewards();

    // TODO: Name?
    error TooSoon(uint256 currentTime, uint256 updateTime, uint256 minDuration);

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

    event ManagerUpdated(address indexed oldManager, address indexed newManager);
    event KeeperUpdated(address indexed oldKeeper, address indexed newKeeper);

    event ClaimFrequencyUpdated(uint256 oldClaimFrequency, uint256 newClaimFrequency);

    event SellBpsBalToUsdcUpdated(uint256 oldValue, uint256 newValue);
    event SellBpsAuraToUsdcUpdated(uint256 oldValue, uint256 newValue);

    event MinOutBpsBalToUsdcMinUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsAuraToUsdcMinUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsBalToBptMinUpdated(uint256 oldValue, uint256 newValue);

    event MinOutBpsBalToUsdcValUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsAuraToUsdcValUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsBalToBptValUpdated(uint256 oldValue, uint256 newValue);

    event Deposit(address indexed token, uint256 amount, uint256 timestamp);
    event Withdraw(address indexed token, uint256 amount, uint256 timestamp);

    event RewardClaimed(address indexed token, uint256 amount, uint256 timestamp);
    event RewardsToStable(address indexed token, uint256 amount, uint256 timestamp);

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

    function initialize(address _owner, address _manager, address _keeper) public initializer {
        __BaseAvatar_init(_owner);
        __Pausable_init();

        manager = _manager;
        keeper = _keeper;

        claimFrequency = 1 weeks;

        sellBpsAuraToUsdc = 3000; // 30%
        sellBpsBalToUsdc = 7000; // 70%

        minOutBpsBalToUsdc = BpsConfig({
            val: 9825, // 98.25%
            min: 9000 // 90%
        });
        minOutBpsAuraToUsdc = BpsConfig({
            val: 9825, // 98.25%
            min: 9000 // 90%
        });
        minOutBpsBalToBpt = BpsConfig({
            val: 9950, // 99.5%
            min: 9000 // 90%
        });

        // TODO: safeApprove
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
    // MODIFIERS
    ////////////////////////////////////////////////////////////////////////////

    modifier onlyOwnerOrManager() {
        if (msg.sender != owner() && msg.sender != manager) {
            revert NotOwnerOrManager(msg.sender);
        }
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) {
            revert NotKeeper(msg.sender);
        }
        _;
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner - Pausing
    ////////////////////////////////////////////////////////////////////////////

    // TODO: Guardian
    function pause() external onlyOwnerOrManager {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner - Config
    ////////////////////////////////////////////////////////////////////////////

    function setManager(address _manager) external onlyOwner {
        address oldManager = manager;

        manager = _manager;
        emit ManagerUpdated(oldManager, _manager);
    }

    function setKeeper(address _keeper) external onlyOwner {
        address oldKeeper = keeper;

        keeper = _keeper;
        emit KeeperUpdated(oldKeeper, _keeper);
    }

    function setClaimFrequency(uint256 _claimFrequency) external onlyOwner {
        uint256 oldClaimFrequency = claimFrequency;

        claimFrequency = _claimFrequency;
        emit ClaimFrequencyUpdated(oldClaimFrequency, _claimFrequency);
    }

    function setSellBpsBalToUsdc(uint256 _sellBpsBalToUsdc) external onlyOwner {
        if (_sellBpsBalToUsdc > MAX_BPS) {
            revert InvalidBps(_sellBpsBalToUsdc);
        }

        uint256 oldSellBpsBalToUsdc = sellBpsBalToUsdc;
        sellBpsBalToUsdc = _sellBpsBalToUsdc;

        emit SellBpsBalToUsdcUpdated(oldSellBpsBalToUsdc, _sellBpsBalToUsdc);
    }

    function setSellBpsAuraToUsdc(uint256 _sellBpsAuraToUsdc) external onlyOwner {
        if (_sellBpsAuraToUsdc > MAX_BPS) {
            revert InvalidBps(_sellBpsAuraToUsdc);
        }

        uint256 oldSellBpsAuraToUsdc = sellBpsAuraToUsdc;
        sellBpsAuraToUsdc = _sellBpsAuraToUsdc;

        emit SellBpsAuraToUsdcUpdated(oldSellBpsAuraToUsdc, _sellBpsAuraToUsdc);
    }

    function setMinOutBpsBalToUsdcMin(uint256 _minOutBpsBalToUsdcMin) external onlyOwner {
        if (_minOutBpsBalToUsdcMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToUsdcMin);
        }

        uint256 oldMinOutBpsBalToUsdcMin = minOutBpsBalToUsdc.min;
        minOutBpsBalToUsdc.min = _minOutBpsBalToUsdcMin;

        emit MinOutBpsBalToUsdcMinUpdated(oldMinOutBpsBalToUsdcMin, _minOutBpsBalToUsdcMin);
    }

    function setMinOutBpsAuraToUsdcMin(uint256 _minOutBpsAuraToUsdcMin) external onlyOwner {
        if (_minOutBpsAuraToUsdcMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsAuraToUsdcMin);
        }

        uint256 oldMinOutBpsAuraToUsdcMin = minOutBpsAuraToUsdc.min;
        minOutBpsAuraToUsdc.min = _minOutBpsAuraToUsdcMin;

        emit MinOutBpsAuraToUsdcMinUpdated(oldMinOutBpsAuraToUsdcMin, _minOutBpsAuraToUsdcMin);
    }

    function setMinOutBpsBalToBptMin(uint256 _minOutBpsBalToBptMin) external onlyOwner {
        if (_minOutBpsBalToBptMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToBptMin);
        }

        uint256 oldMinOutBpsBalToBptMin = minOutBpsBalToBpt.min;
        minOutBpsBalToBpt.min = _minOutBpsBalToBptMin;

        emit MinOutBpsBalToBptMinUpdated(oldMinOutBpsBalToBptMin, _minOutBpsBalToBptMin);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Manager - Config
    ////////////////////////////////////////////////////////////////////////////

    // TODO: val can't be less than min
    function setMinOutBpsBalToUsdcVal(uint256 _minOutBpsBalToUsdcVal) external onlyOwnerOrManager {
        if (_minOutBpsBalToUsdcVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToUsdcVal);
        }

        BpsConfig storage minOutBpsBalToUsdcPtr = minOutBpsBalToUsdc;

        uint256 minOutBpsBalToUsdcMin = minOutBpsBalToUsdcPtr.min;
        if (_minOutBpsBalToUsdcVal < minOutBpsBalToUsdcMin) {
            revert LessThanMinBps(_minOutBpsBalToUsdcVal, minOutBpsBalToUsdcMin);
        }

        uint256 oldMinOutBpsBalToUsdcVal = minOutBpsBalToUsdcPtr.val;
        minOutBpsBalToUsdcPtr.val = _minOutBpsBalToUsdcVal;

        emit MinOutBpsBalToUsdcValUpdated(oldMinOutBpsBalToUsdcVal, _minOutBpsBalToUsdcVal);
    }

    function setMinOutBpsAuraToUsdcVal(uint256 _minOutBpsAuraToUsdcVal) external onlyOwnerOrManager {
        if (_minOutBpsAuraToUsdcVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsAuraToUsdcVal);
        }

        BpsConfig storage minOutBpsAuraToUsdcPtr = minOutBpsAuraToUsdc;

        uint256 minOutBpsAuraToUsdcMin = minOutBpsAuraToUsdcPtr.min;
        if (_minOutBpsAuraToUsdcVal < minOutBpsAuraToUsdcMin) {
            revert LessThanMinBps(_minOutBpsAuraToUsdcVal, minOutBpsAuraToUsdcMin);
        }

        uint256 oldMinOutBpsAuraToUsdcVal = minOutBpsAuraToUsdcPtr.val;
        minOutBpsAuraToUsdcPtr.val = _minOutBpsAuraToUsdcVal;

        emit MinOutBpsAuraToUsdcValUpdated(oldMinOutBpsAuraToUsdcVal, _minOutBpsAuraToUsdcVal);
    }

    function setMinOutBpsBalToBptVal(uint256 _minOutBpsBalToBptVal) external onlyOwnerOrManager {
        if (_minOutBpsBalToBptVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToBptVal);
        }

        BpsConfig storage minOutBpsBalToBptPtr = minOutBpsBalToBpt;

        uint256 minOutBpsBalToBptMin = minOutBpsBalToBptPtr.min;
        if (_minOutBpsBalToBptVal < minOutBpsBalToBptMin) {
            revert LessThanMinBps(_minOutBpsBalToBptVal, minOutBpsBalToBptMin);
        }

        uint256 oldMinOutBpsBalToBptVal = minOutBpsBalToBptPtr.val;
        minOutBpsBalToBptPtr.val = _minOutBpsBalToBptVal;

        emit MinOutBpsBalToBptValUpdated(oldMinOutBpsBalToBptVal, _minOutBpsBalToBptVal);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner
    ////////////////////////////////////////////////////////////////////////////

    function deposit(uint256 _amountBpt1, uint256 _amountBpt2) external onlyOwner {
        if (_amountBpt1 == 0 && _amountBpt2 == 0) {
            revert NothingToDeposit();
        }

        // TODO: See if can be moved elsewhere
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

        emit Deposit(address(asset1), _amountBpt1, block.timestamp);
        emit Deposit(address(asset2), _amountBpt2, block.timestamp);
    }

    // NOTE: Doesn't claim rewards
    function withdrawAll() external onlyOwner {
        uint256 bptDeposited1 = baseRewardPool1.balanceOf(address(this));
        if (bptDeposited1 > 0) {
            baseRewardPool1.withdrawAndUnwrap(bptDeposited1, false);
        }
        uint256 bptDeposited2 = baseRewardPool2.balanceOf(address(this));
        if (bptDeposited2 > 0) {
            baseRewardPool2.withdrawAndUnwrap(bptDeposited2, false);
        }

        address ownerCached = owner();
        asset1.transfer(ownerCached, bptDeposited1);
        asset2.transfer(ownerCached, bptDeposited2);

        emit Withdraw(address(asset1), bptDeposited1, block.timestamp);
        emit Withdraw(address(asset2), bptDeposited2, block.timestamp);
    }

    // NOTE: Failsafe in case things go wrong, want to sell through different pools
    function claimRewardsAndSendToOwner() public onlyOwner {
        // 1. Claim BAL and AURA rewards
        claimRewards();

        uint256 totalBal = BAL.balanceOf(address(this));
        uint256 totalAura = AURA.balanceOf(address(this));

        if (totalBal == 0) {
            revert NoRewards();
        }

        // 2. Send to owner
        address ownerCached = owner();
        BAL.transfer(ownerCached, totalBal);
        AURA.transfer(ownerCached, totalAura);

        emit RewardClaimed(address(BAL), totalBal, block.timestamp);
        emit RewardClaimed(address(AURA), totalAura, block.timestamp);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner/Manager
    ////////////////////////////////////////////////////////////////////////////

    // NOTE: Can be called by techops to opportunistically harvest
    function processRewards() external onlyOwnerOrManager {
        processRewardsInternal();
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Keeper
    ////////////////////////////////////////////////////////////////////////////

    function performUpkeep(bytes calldata) external override onlyKeeper whenNotPaused {
        uint256 lastClaimTimestampCached = lastClaimTimestamp;
        uint256 claimFrequencyCached = claimFrequency;
        if ((block.timestamp - lastClaimTimestampCached) < claimFrequencyCached) {
            revert TooSoon(block.timestamp, lastClaimTimestampCached, claimFrequencyCached);
        }

        processRewardsInternal();
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC VIEW
    ////////////////////////////////////////////////////////////////////////////

    // TODO: See if better name
    /// @dev Returns the name of the strategy
    function name() external pure returns (string memory name_) {
        name_ = "Avatar_Aura";
    }

    function version() external pure returns (string memory version_) {
        version_ = "0.0.1";
    }

    function assets() external view returns (IERC20Upgradeable[2] memory assets_) {
        assets_[0] = asset1;
        assets_[1] = asset2;
    }

    function totalAssets() external view returns (uint256[2] memory assetAmounts_) {
        assetAmounts_[0] = baseRewardPool1.balanceOf(address(this));
        assetAmounts_[1] = baseRewardPool2.balanceOf(address(this));
    }

    function pendingRewards() external view returns (TokenAmount[2] memory rewards_) {
        uint256 balEarned = baseRewardPool1.earned(address(this));
        balEarned += baseRewardPool2.earned(address(this));

        rewards_[0] = TokenAmount(address(BAL), balEarned);
        rewards_[1] = TokenAmount(address(AURA), getMintableAuraRewards(balEarned));
    }

    // NOTE: Assumes USDC is pegged. We should sell for other stableecoins if not
    function getBalAmountInUsdc(uint256 _balAmount) public view returns (uint256 usdcAmount_) {
        uint256 balInUsd = fetchPriceFromClFeed(BAL_USD_FEED);
        // TODO: See if can overflow
        usdcAmount_ = (_balAmount * balInUsd) / BAL_USD_FEED_DIVISOR;
    }

    // TODO: Move to CL feed once that's up
    // NOTE: Assumes USDC is pegged. We should sell for other stableecoins if not
    function getAuraAmountInUsdc(uint256 _auraAmount) public view returns (uint256 usdcAmount_) {
        uint256 auraInEth = fetchPriceFromBalancerTwap(BPT_80AURA_20WETH);
        uint256 ethInUsd = fetchPriceFromClFeed(ETH_USD_FEED);
        // TODO: See if can overflow
        usdcAmount_ = (_auraAmount * auraInEth * ethInUsd) / AURA_USD_FEED_DIVISOR;
    }

    // TODO: Maybe use invariant, totalSupply and BAL/ETH feed for this instead of twap?
    function getBalAmountInBpt(uint256 _balAmount) public view returns (uint256 bptAmount_) {
        uint256 bptPriceInBal = fetchBptPriceFromBalancerTwap(IPriceOracle(address(BPT_80BAL_20WETH)));
        bptAmount_ = (_balAmount * PRECISION) / bptPriceInBal;
    }

    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded_, bytes memory) {
        uint256 balPending1 = baseRewardPool1.earned(address(this));
        uint256 balPending2 = baseRewardPool2.earned(address(this));

        uint256 balBalance = BAL.balanceOf(address(this));

        if ((block.timestamp - lastClaimTimestamp) >= claimFrequency) {
            if (balPending1 > 0 || balPending2 > 0 || balBalance > 0) {
                upkeepNeeded_ = true;
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL
    ////////////////////////////////////////////////////////////////////////////

    function processRewardsInternal() internal {
        // 1. Claim BAL and AURA rewards
        claimRewards();

        uint256 totalBal = BAL.balanceOf(address(this));
        uint256 totalAura = AURA.balanceOf(address(this));

        if (totalBal == 0) {
            revert NoRewards();
        }

        // 2. Swap some for USDC and send to owner
        uint256 balForUsdc = (totalBal * sellBpsBalToUsdc) / MAX_BPS;
        uint256 auraForUsdc = (totalAura * sellBpsAuraToUsdc) / MAX_BPS;

        uint256 usdcEarnedFromBal = swapBalForUsdc(balForUsdc);
        uint256 usdcEarnedFromAura = swapAuraForUsdc(auraForUsdc);

        address ownerCached = owner();
        USDC.transfer(ownerCached, USDC.balanceOf(address(this)));

        // 3. Deposit remaining BAL to 80BAL-20ETH BPT
        uint256 balToDeposit = totalBal - balForUsdc;
        depositBalToBpt(balToDeposit);

        // 4. Swap BPT for auraBAL or lock
        uint256 balEthBptAmount = BPT_80BAL_20WETH.balanceOf(address(this));
        swapBptForAuraBal(balEthBptAmount);

        // 5. Dogfood auraBAL in Badger vault on behalf of owner
        BAURABAL.depositFor(ownerCached, AURABAL.balanceOf(address(this)));

        // 6. Lock remaining AURA on behalf of Badger voter msig
        uint256 auraToLock = totalAura - auraForUsdc;
        AURA_LOCKER.lock(BADGER_VOTER, auraToLock);

        // Emit events for analysis
        // TODO: Names?
        emit RewardClaimed(address(BAL), totalBal, block.timestamp);
        emit RewardClaimed(address(AURA), totalAura, block.timestamp);
        emit RewardsToStable(address(USDC), usdcEarnedFromBal + usdcEarnedFromAura, block.timestamp);
    }

    // NOTE: Shouldn't revert since others can claim for this contract
    function claimRewards() internal {
        // Update last claimed time
        lastClaimTimestamp = block.timestamp;

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
        // TODO: Don't cast CL feed
        limits[2] = -int256((getBalAmountInUsdc(_balAmount) * minOutBpsBalToUsdc.val) / MAX_BPS); //
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
        // TODO: Don't cast CL feed
        limits[2] = -int256((getAuraAmountInUsdc(_auraAmount) * minOutBpsAuraToUsdc.val) / MAX_BPS);

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

        // TODO: Test this
        // Take the trade if we get more than 1: 1 auraBal out
        try BALANCER_VAULT.swap(
            swapParam,
            fundManagement,
            _bptAmount, // minOut
            type(uint256).max
        ) returns (uint256) {} catch {
            // Otherwise deposit
            AURABAL_DEPOSITOR.deposit(_bptAmount, true, address(0));
        }
    }

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
                    (getBalAmountInBpt(_balAmount) * minOutBpsBalToBpt.val) / MAX_BPS
                    ),
                fromInternalBalance: false
            })
        );
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL VIEW
    ////////////////////////////////////////////////////////////////////////////

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
