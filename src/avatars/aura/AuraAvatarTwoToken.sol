// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {IERC20Upgradeable} from "openzeppelin-contracts-upgradeable/interfaces/IERC20Upgradeable.sol";
import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/security/PausableUpgradeable.sol";

import {BaseAvatar} from "../../lib/BaseAvatar.sol";
import {AuraConstants} from "./AuraConstants.sol";
import {AuraAvatarOracleUtils} from "./AuraAvatarOracleUtils.sol";
import {MAX_BPS} from "../BaseConstants.sol";

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

// TODO: Contract should never hold funds?
//       Natspec
//       Add role to that can adjust minOutBps
//       Backup in case swaps are failing - sweep to owner callable by manager
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

    uint256 public sellBpsBalToUsd;
    uint256 public sellBpsAuraToUsd;

    BpsConfig public minOutBpsBalToUsd;
    BpsConfig public minOutBpsAuraToUsd;

    BpsConfig public minOutBpsBalToAuraBal; // TODO: Divide into two steps?

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

    event SellBpsBalToUsdUpdated(uint256 oldValue, uint256 newValue);
    event SellBpsAuraToUsdUpdated(uint256 oldValue, uint256 newValue);

    event MinOutBpsBalToUsdMinUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsAuraToUsdMinUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsBalToAuraBalMinUpdated(uint256 oldValue, uint256 newValue);

    event MinOutBpsBalToUsdValUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsAuraToUsdValUpdated(uint256 oldValue, uint256 newValue);
    event MinOutBpsBalToAuraBalValUpdated(uint256 oldValue, uint256 newValue);

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

        sellBpsAuraToUsd = 3000; // 30%
        sellBpsBalToUsd = 7000; // 70%

        minOutBpsBalToUsd = BpsConfig({
            val: 9825, // 98.25%
            min: 9000 // 90%
        });
        minOutBpsAuraToUsd = BpsConfig({
            val: 9825, // 98.25%
            min: 9000 // 90%
        });
        minOutBpsBalToAuraBal = BpsConfig({
            val: 9950, // 99.5%
            min: 9000 // 90%
        });

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
        uint256 oldClaimFrequency = _claimFrequency;

        claimFrequency = _claimFrequency;
        emit ClaimFrequencyUpdated(oldClaimFrequency, _claimFrequency);
    }

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

    function setMinOutBpsBalToUsdMin(uint256 _minOutBpsBalToUsdMin) external onlyOwner {
        if (_minOutBpsBalToUsdMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToUsdMin);
        }

        uint256 oldMinOutBpsBalToUsdMin = minOutBpsBalToUsd.min;
        minOutBpsBalToUsd.min = _minOutBpsBalToUsdMin;

        emit MinOutBpsBalToUsdMinUpdated(oldMinOutBpsBalToUsdMin, _minOutBpsBalToUsdMin);
    }

    function setMinOutBpsAuraToUsdMin(uint256 _minOutBpsAuraToUsdMin) external onlyOwner {
        if (_minOutBpsAuraToUsdMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsAuraToUsdMin);
        }

        uint256 oldMinOutBpsAuraToUsdMin = minOutBpsAuraToUsd.min;
        minOutBpsAuraToUsd.min = _minOutBpsAuraToUsdMin;

        emit MinOutBpsAuraToUsdMinUpdated(oldMinOutBpsAuraToUsdMin, _minOutBpsAuraToUsdMin);
    }

    function setMinOutBpsBalToAuraBalMin(uint256 _minOutBpsBalToAuraBalMin) external onlyOwner {
        if (_minOutBpsBalToAuraBalMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToAuraBalMin);
        }

        uint256 oldMinOutBpsBalToAuraBalMin = minOutBpsBalToAuraBal.min;
        minOutBpsBalToAuraBal.min = _minOutBpsBalToAuraBalMin;

        emit MinOutBpsBalToAuraBalMinUpdated(oldMinOutBpsBalToAuraBalMin, _minOutBpsBalToAuraBalMin);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Manager - Config
    ////////////////////////////////////////////////////////////////////////////

    function setMinOutBpsBalToUsdVal(uint256 _minOutBpsBalToUsdVal) external onlyOwnerOrManager {
        if (_minOutBpsBalToUsdVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToUsdVal);
        }

        BpsConfig storage minOutBpsBalToUsdPtr = minOutBpsBalToUsd;

        uint256 minOutBpsBalToUsdMin = minOutBpsBalToUsdPtr.min;
        if (_minOutBpsBalToUsdVal < minOutBpsBalToUsdMin) {
            revert LessThanMinBps(_minOutBpsBalToUsdVal, minOutBpsBalToUsdMin);
        }

        uint256 oldMinOutBpsBalToUsdVal = minOutBpsBalToUsdPtr.val;
        minOutBpsBalToUsdPtr.val = _minOutBpsBalToUsdVal;

        emit MinOutBpsBalToUsdValUpdated(oldMinOutBpsBalToUsdVal, _minOutBpsBalToUsdVal);
    }

    function setMinOutBpsAuraToUsdVal(uint256 _minOutBpsAuraToUsdVal) external onlyOwnerOrManager {
        if (_minOutBpsAuraToUsdVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsAuraToUsdVal);
        }

        BpsConfig storage minOutBpsAuraToUsdPtr = minOutBpsAuraToUsd;

        uint256 minOutBpsAuraToUsdMin = minOutBpsAuraToUsdPtr.min;
        if (_minOutBpsAuraToUsdVal < minOutBpsAuraToUsdMin) {
            revert LessThanMinBps(_minOutBpsAuraToUsdVal, minOutBpsAuraToUsdMin);
        }

        uint256 oldMinOutBpsAuraToUsdVal = minOutBpsAuraToUsdPtr.val;
        minOutBpsAuraToUsdPtr.val = _minOutBpsAuraToUsdVal;

        emit MinOutBpsAuraToUsdValUpdated(oldMinOutBpsAuraToUsdVal, _minOutBpsAuraToUsdVal);
    }

    function setMinOutBpsBalToAuraBalVal(uint256 _minOutBpsBalToAuraBalVal) external onlyOwnerOrManager {
        if (_minOutBpsBalToAuraBalVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToAuraBalVal);
        }

        BpsConfig storage minOutBpsBalToAuraBalPtr = minOutBpsBalToAuraBal;

        uint256 minOutBpsBalToAuraBalMin = minOutBpsBalToAuraBalPtr.min;
        if (_minOutBpsBalToAuraBalVal < minOutBpsBalToAuraBalMin) {
            revert LessThanMinBps(_minOutBpsBalToAuraBalVal, minOutBpsBalToAuraBalMin);
        }

        uint256 oldMinOutBpsBalToAuraBalVal = minOutBpsBalToAuraBalPtr.val;
        minOutBpsBalToAuraBalPtr.val = _minOutBpsBalToAuraBalVal;

        emit MinOutBpsBalToAuraBalValUpdated(oldMinOutBpsBalToAuraBalVal, _minOutBpsBalToAuraBalVal);
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
        asset1.transfer(ownerCached, bptDeposited1);
        asset2.transfer(ownerCached, bptDeposited2);

        emit Withdraw(address(asset1), bptDeposited1, block.timestamp);
        emit Withdraw(address(asset2), bptDeposited2, block.timestamp);
    }

    // NOTE: Failsafe in case things go wrong, want to sell through different pools
    function claimRewardsAndSendToOwner() public onlyOwner {
        // Update last claimed time
        lastClaimTimestamp = block.timestamp;

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
        // Update last claimed time
        lastClaimTimestamp = block.timestamp;

        // 1. Claim BAL and AURA rewards
        claimRewards();

        uint256 totalBal = BAL.balanceOf(address(this));
        uint256 totalAura = AURA.balanceOf(address(this));

        if (totalBal == 0) {
            revert NoRewards();
        }

        // 2. Swap some for USDC
        uint256 balForUsdc = (totalBal * sellBpsBalToUsd) / MAX_BPS;
        uint256 auraForUsdc = (totalAura * sellBpsAuraToUsd) / MAX_BPS;

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

        // 5. Dogfood auraBAL in Badger vault in behalf of owner
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
        // TODO: Maybe try-catch?
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
        limits[2] = int256((getBalAmountInUsd(_balAmount) * minOutBpsBalToUsd.val) / MAX_BPS); //
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
        limits[2] = int256((getAuraAmountInUsd(_auraAmount) * minOutBpsAuraToUsd.val) / MAX_BPS);

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
                    getMinBpt(_balAmount) // minOut // TODO: Need a separate bps?
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

        minOut_ = (((_balAmount * 1e18) / bptOraclePrice) * minOutBpsBalToAuraBal.val) / MAX_BPS;
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
