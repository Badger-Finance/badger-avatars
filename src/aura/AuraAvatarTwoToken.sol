// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {PausableUpgradeable} from "openzeppelin-contracts-upgradeable/security/PausableUpgradeable.sol";
import {SafeERC20Upgradeable} from "openzeppelin-contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {IERC20MetadataUpgradeable} from
    "openzeppelin-contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";

import {BaseAvatar} from "../lib/BaseAvatar.sol";
import {AuraConstants} from "./AuraConstants.sol";
import {AuraAvatarOracleUtils} from "./AuraAvatarOracleUtils.sol";
import {MAX_BPS, PRECISION} from "../BaseConstants.sol";

import {IAuraToken} from "../interfaces/aura/IAuraToken.sol";
import {IBaseRewardPool} from "../interfaces/aura/IBaseRewardPool.sol";
import {IAsset} from "../interfaces/balancer/IAsset.sol";
import {IBalancerVault, JoinKind} from "../interfaces/balancer/IBalancerVault.sol";
import {IPriceOracle} from "../interfaces/balancer/IPriceOracle.sol";
import {KeeperCompatibleInterface} from "../interfaces/chainlink/KeeperCompatibleInterface.sol";

struct TokenAmount {
    address token;
    uint256 amount;
}

// TODO: Storage packing? Check if that works with proxy upgrades?
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
    // LIBRARIES
    ////////////////////////////////////////////////////////////////////////////

    using SafeERC20Upgradeable for IERC20MetadataUpgradeable;

    ////////////////////////////////////////////////////////////////////////////
    // CONSTANTS
    ////////////////////////////////////////////////////////////////////////////

    uint256 private constant CL_FEED_STALE_PERIOD = 24 hours;

    ////////////////////////////////////////////////////////////////////////////
    // IMMUTABLES
    ////////////////////////////////////////////////////////////////////////////

    // TODO: Check if this can cause issues
    uint256 public immutable pid1;
    uint256 public immutable pid2;

    IERC20MetadataUpgradeable public immutable asset1;
    IERC20MetadataUpgradeable public immutable asset2;

    IBaseRewardPool public immutable baseRewardPool1;
    IBaseRewardPool public immutable baseRewardPool2;

    ////////////////////////////////////////////////////////////////////////////
    // STORAGE
    ////////////////////////////////////////////////////////////////////////////

    address public manager;
    address public keeper;

    uint256 public claimFrequency;
    uint256 public twapPeriod;

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
    error LessThanBpsMin(uint256 bpsVal, uint256 bpsMin);
    error MoreThanBpsVal(uint256 bpsMin, uint256 bpsVal);

    error NothingToDeposit();
    error NothingToWithdraw();
    error NoRewards();

    error TooSoon(uint256 currentTime, uint256 updateTime, uint256 minDuration);

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

    event ManagerUpdated(address indexed newManager, address indexed oldManager);
    event KeeperUpdated(address indexed newKeeper, address indexed oldKeeper);

    event TwapPeriodUpdated(uint256 newTwapPeriod, uint256 oldTwapPeriod);
    event ClaimFrequencyUpdated(uint256 newClaimFrequency, uint256 oldClaimFrequency);

    event SellBpsBalToUsdcUpdated(uint256 newValue, uint256 oldValue);
    event SellBpsAuraToUsdcUpdated(uint256 newValue, uint256 oldValue);

    event MinOutBpsBalToUsdcMinUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsAuraToUsdcMinUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsBalToBptMinUpdated(uint256 newValue, uint256 oldValue);

    event MinOutBpsBalToUsdcValUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsAuraToUsdcValUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsBalToBptValUpdated(uint256 newValue, uint256 oldValue);

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

        asset1 = IERC20MetadataUpgradeable(lpToken1);
        asset2 = IERC20MetadataUpgradeable(lpToken2);

        baseRewardPool1 = IBaseRewardPool(crvRewards1);
        baseRewardPool2 = IBaseRewardPool(crvRewards2);
    }

    function initialize(address _owner, address _manager, address _keeper) public initializer {
        __BaseAvatar_init(_owner);
        __Pausable_init();

        manager = _manager;
        keeper = _keeper;

        twapPeriod = 1 hours;
        claimFrequency = 1 weeks;

        sellBpsBalToUsdc = 7000; // 70%
        sellBpsAuraToUsdc = 3000; // 30%

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

        // Booster approval for both bpt
        asset1.safeApprove(address(AURA_BOOSTER), type(uint256).max);
        asset2.safeApprove(address(AURA_BOOSTER), type(uint256).max);

        // Balancer vault approvals
        BAL.safeApprove(address(BALANCER_VAULT), type(uint256).max);
        AURA.safeApprove(address(BALANCER_VAULT), type(uint256).max);
        BPT_80BAL_20WETH.safeApprove(address(BALANCER_VAULT), type(uint256).max);

        AURA.safeApprove(address(AURA_LOCKER), type(uint256).max);

        BPT_80BAL_20WETH.safeApprove(address(AURABAL_DEPOSITOR), type(uint256).max);
        AURABAL.safeApprove(address(BAURABAL), type(uint256).max);
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
        emit ManagerUpdated(_manager, oldManager);
    }

    function setKeeper(address _keeper) external onlyOwner {
        address oldKeeper = keeper;

        keeper = _keeper;
        emit KeeperUpdated(_keeper, oldKeeper);
    }

    function setSellBpsBalToUsdc(uint256 _sellBpsBalToUsdc) external onlyOwner {
        if (_sellBpsBalToUsdc > MAX_BPS) {
            revert InvalidBps(_sellBpsBalToUsdc);
        }

        uint256 oldSellBpsBalToUsdc = sellBpsBalToUsdc;
        sellBpsBalToUsdc = _sellBpsBalToUsdc;

        emit SellBpsBalToUsdcUpdated(_sellBpsBalToUsdc, oldSellBpsBalToUsdc);
    }

    function setSellBpsAuraToUsdc(uint256 _sellBpsAuraToUsdc) external onlyOwner {
        if (_sellBpsAuraToUsdc > MAX_BPS) {
            revert InvalidBps(_sellBpsAuraToUsdc);
        }

        uint256 oldSellBpsAuraToUsdc = sellBpsAuraToUsdc;
        sellBpsAuraToUsdc = _sellBpsAuraToUsdc;

        emit SellBpsAuraToUsdcUpdated(_sellBpsAuraToUsdc, oldSellBpsAuraToUsdc);
    }

    function setMinOutBpsBalToUsdcMin(uint256 _minOutBpsBalToUsdcMin) external onlyOwner {
        if (_minOutBpsBalToUsdcMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToUsdcMin);
        }

        uint256 minOutBpsBalToUsdcVal = minOutBpsBalToUsdc.val;
        if (_minOutBpsBalToUsdcMin > minOutBpsBalToUsdcVal) {
            revert MoreThanBpsVal(_minOutBpsBalToUsdcMin, minOutBpsBalToUsdcVal);
        }

        uint256 oldMinOutBpsBalToUsdcMin = minOutBpsBalToUsdc.min;
        minOutBpsBalToUsdc.min = _minOutBpsBalToUsdcMin;

        emit MinOutBpsBalToUsdcMinUpdated(_minOutBpsBalToUsdcMin, oldMinOutBpsBalToUsdcMin);
    }

    function setMinOutBpsAuraToUsdcMin(uint256 _minOutBpsAuraToUsdcMin) external onlyOwner {
        if (_minOutBpsAuraToUsdcMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsAuraToUsdcMin);
        }

        uint256 minOutBpsAuraToUsdcVal = minOutBpsAuraToUsdc.val;
        if (_minOutBpsAuraToUsdcMin > minOutBpsAuraToUsdcVal) {
            revert MoreThanBpsVal(_minOutBpsAuraToUsdcMin, minOutBpsAuraToUsdcVal);
        }

        uint256 oldMinOutBpsAuraToUsdcMin = minOutBpsAuraToUsdc.min;
        minOutBpsAuraToUsdc.min = _minOutBpsAuraToUsdcMin;

        emit MinOutBpsAuraToUsdcMinUpdated(_minOutBpsAuraToUsdcMin, oldMinOutBpsAuraToUsdcMin);
    }

    function setMinOutBpsBalToBptMin(uint256 _minOutBpsBalToBptMin) external onlyOwner {
        if (_minOutBpsBalToBptMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToBptMin);
        }

        uint256 minOutBpsBalToBptVal = minOutBpsBalToBpt.val;
        if (_minOutBpsBalToBptMin > minOutBpsBalToBptVal) {
            revert MoreThanBpsVal(_minOutBpsBalToBptMin, minOutBpsBalToBptVal);
        }

        uint256 oldMinOutBpsBalToBptMin = minOutBpsBalToBpt.min;
        minOutBpsBalToBpt.min = _minOutBpsBalToBptMin;

        emit MinOutBpsBalToBptMinUpdated(_minOutBpsBalToBptMin, oldMinOutBpsBalToBptMin);
    }

    function setTwapPeriod(uint256 _twapPeriod) external onlyOwner {
        uint256 oldTwapPeriod = twapPeriod;

        twapPeriod = _twapPeriod;
        emit TwapPeriodUpdated(_twapPeriod, oldTwapPeriod);
    }

    function setClaimFrequency(uint256 _claimFrequency) external onlyOwner {
        uint256 oldClaimFrequency = claimFrequency;

        claimFrequency = _claimFrequency;
        emit ClaimFrequencyUpdated(_claimFrequency, oldClaimFrequency);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Manager - Config
    ////////////////////////////////////////////////////////////////////////////

    function setMinOutBpsBalToUsdcVal(uint256 _minOutBpsBalToUsdcVal) external onlyOwnerOrManager {
        if (_minOutBpsBalToUsdcVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToUsdcVal);
        }

        uint256 minOutBpsBalToUsdcMin = minOutBpsBalToUsdc.min;
        if (_minOutBpsBalToUsdcVal < minOutBpsBalToUsdcMin) {
            revert LessThanBpsMin(_minOutBpsBalToUsdcVal, minOutBpsBalToUsdcMin);
        }

        uint256 oldMinOutBpsBalToUsdcVal = minOutBpsBalToUsdc.val;
        minOutBpsBalToUsdc.val = _minOutBpsBalToUsdcVal;

        emit MinOutBpsBalToUsdcValUpdated(_minOutBpsBalToUsdcVal, oldMinOutBpsBalToUsdcVal);
    }

    function setMinOutBpsAuraToUsdcVal(uint256 _minOutBpsAuraToUsdcVal) external onlyOwnerOrManager {
        if (_minOutBpsAuraToUsdcVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsAuraToUsdcVal);
        }

        uint256 minOutBpsAuraToUsdcMin = minOutBpsAuraToUsdc.min;
        if (_minOutBpsAuraToUsdcVal < minOutBpsAuraToUsdcMin) {
            revert LessThanBpsMin(_minOutBpsAuraToUsdcVal, minOutBpsAuraToUsdcMin);
        }

        uint256 oldMinOutBpsAuraToUsdcVal = minOutBpsAuraToUsdc.val;
        minOutBpsAuraToUsdc.val = _minOutBpsAuraToUsdcVal;

        emit MinOutBpsAuraToUsdcValUpdated(_minOutBpsAuraToUsdcVal, oldMinOutBpsAuraToUsdcVal);
    }

    function setMinOutBpsBalToBptVal(uint256 _minOutBpsBalToBptVal) external onlyOwnerOrManager {
        if (_minOutBpsBalToBptVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToBptVal);
        }

        uint256 minOutBpsBalToBptMin = minOutBpsBalToBpt.min;
        if (_minOutBpsBalToBptVal < minOutBpsBalToBptMin) {
            revert LessThanBpsMin(_minOutBpsBalToBptVal, minOutBpsBalToBptMin);
        }

        uint256 oldMinOutBpsBalToBptVal = minOutBpsBalToBpt.val;
        minOutBpsBalToBpt.val = _minOutBpsBalToBptVal;

        emit MinOutBpsBalToBptValUpdated(_minOutBpsBalToBptVal, oldMinOutBpsBalToBptVal);
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
            asset1.safeTransferFrom(msg.sender, address(this), _amountBpt1);
            AURA_BOOSTER.deposit(pid1, _amountBpt1, true);

            emit Deposit(address(asset1), _amountBpt1, block.timestamp);
        }
        if (_amountBpt2 > 0) {
            asset2.safeTransferFrom(msg.sender, address(this), _amountBpt2);
            AURA_BOOSTER.deposit(pid2, _amountBpt2, true);

            emit Deposit(address(asset2), _amountBpt2, block.timestamp);
        }
    }

    // NOTE: Doesn't claim rewards
    function withdrawAll() external onlyOwner {
        uint256 bptDeposited1 = baseRewardPool1.balanceOf(address(this));
        uint256 bptDeposited2 = baseRewardPool2.balanceOf(address(this));

        withdraw(bptDeposited1, bptDeposited2);
    }

    function withdraw(uint256 _amountBpt1, uint256 _amountBpt2) public onlyOwner {
        if (_amountBpt1 == 0 && _amountBpt2 == 0) {
            revert NothingToWithdraw();
        }

        if (_amountBpt1 > 0) {
            withdrawAsset1(_amountBpt1);
        }
        if (_amountBpt2 > 0) {
            withdrawAsset2(_amountBpt2);
        }
    }

    // TODO: Maybe revert on 0?
    /// @dev Withdraws a certain amount of asset1
    function withdrawAsset1(uint256 _amountBpt1) public onlyOwner {
        baseRewardPool1.withdrawAndUnwrap(_amountBpt1, false);
        asset1.safeTransfer(owner(), _amountBpt1);

        emit Withdraw(address(asset1), _amountBpt1, block.timestamp);
    }

    /// @dev Withdraws a certain amount of asset2
    function withdrawAsset2(uint256 _amountBpt2) public onlyOwner {
        baseRewardPool2.withdrawAndUnwrap(_amountBpt2, false);
        asset2.safeTransfer(owner(), _amountBpt2);

        emit Withdraw(address(asset2), _amountBpt2, block.timestamp);
    }

    // NOTE: Failsafe in case things go wrong, want to sell through different pools
    function claimRewardsAndSendToOwner() public onlyOwner {
        // 1. Claim BAL and AURA rewards
        (uint256 totalBal, uint256 totalAura) = claimAndRegisterRewards();

        // 2. Send to owner
        address ownerCached = owner();
        BAL.safeTransfer(ownerCached, totalBal);
        AURA.safeTransfer(ownerCached, totalAura);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner/Manager
    ////////////////////////////////////////////////////////////////////////////

    // NOTE: Can be called by techops to opportunistically harvest
    function processRewards() external onlyOwnerOrManager returns (TokenAmount[] memory processed_) {
        processed_ = processRewardsInternal();
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

    /// @dev Returns the name of the strategy
    function name() external view returns (string memory name_) {
        name_ = string.concat("Avatar_AuraTwoToken", "_", asset1.symbol(), "_", asset2.symbol());
    }

    function version() external pure returns (string memory version_) {
        version_ = "0.0.1";
    }

    function assets() external view returns (IERC20MetadataUpgradeable[2] memory assets_) {
        assets_[0] = asset1;
        assets_[1] = asset2;
    }

    function totalAssets() external view returns (uint256[2] memory assetAmounts_) {
        assetAmounts_[0] = baseRewardPool1.balanceOf(address(this));
        assetAmounts_[1] = baseRewardPool2.balanceOf(address(this));
    }

    // NOTE: Includes BAL/AURA in the contract
    function pendingRewards() external view returns (TokenAmount[2] memory rewards_) {
        uint256 balEarned = baseRewardPool1.earned(address(this));
        balEarned += baseRewardPool2.earned(address(this));

        uint256 totalBal = balEarned + BAL.balanceOf(address(this));
        uint256 totalAura = getMintableAuraForBalAmount(balEarned) + AURA.balanceOf(address(this));

        rewards_[0] = TokenAmount(address(BAL), totalBal);
        rewards_[1] = TokenAmount(address(AURA), totalAura);
    }

    // TODO: Maybe move to internal?

    // NOTE: Assumes USDC is pegged. We should sell for other stableecoins if not
    function getBalAmountInUsdc(uint256 _balAmount) public view returns (uint256 usdcAmount_) {
        uint256 balInUsd = fetchPriceFromClFeed(BAL_USD_FEED, CL_FEED_STALE_PERIOD);
        // Divisor is 10^20 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_balAmount * balInUsd) / BAL_USD_FEED_DIVISOR;
    }

    // NOTE: Assumes USDC is pegged. We should sell for other stableecoins if not
    function getAuraAmountInUsdc(uint256 _auraAmount) public view returns (uint256 usdcAmount_) {
        uint256 auraInEth = fetchPriceFromBalancerTwap(BPT_80AURA_20WETH, twapPeriod);
        uint256 ethInUsd = fetchPriceFromClFeed(ETH_USD_FEED, CL_FEED_STALE_PERIOD);
        // Divisor is 10^38 and uint256 max ~ 10^77 so this shouldn't overflow for normal amounts
        usdcAmount_ = (_auraAmount * auraInEth * ethInUsd) / AURA_USD_FEED_DIVISOR;
    }

    // TODO: Maybe use invariant, totalSupply and BAL/ETH feed for this instead of twap?
    function getBalAmountInBpt(uint256 _balAmount) public view returns (uint256 bptAmount_) {
        uint256 bptPriceInBal = fetchBptPriceFromBalancerTwap(IPriceOracle(address(BPT_80BAL_20WETH)), twapPeriod);
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

    /// @notice Returns the expected amount of AURA to be minted given an amount of BAL rewards
    /// @dev ref: https://etherscan.io/address/0xc0c293ce456ff0ed870add98a0828dd4d2903dbf#code#F1#L86
    function getMintableAuraForBalAmount(uint256 _balAmount) public view returns (uint256 amount) {
        // NOTE: Only correct if AURA.minterMinted() == 0
        //       minterMinted is a private var in the contract, so we can't access it directly
        uint256 emissionsMinted = AURA.totalSupply() - IAuraToken(address(AURA)).INIT_MINT_AMOUNT();

        uint256 cliff = emissionsMinted / IAuraToken(address(AURA)).reductionPerCliff();
        uint256 totalCliffs = IAuraToken(address(AURA)).totalCliffs();

        if (cliff < totalCliffs) {
            uint256 reduction = (((totalCliffs - cliff) * 5) / 2) + 700;
            amount = (_balAmount * reduction) / totalCliffs;

            uint256 amtTillMax = IAuraToken(address(AURA)).EMISSIONS_MAX_SUPPLY() - emissionsMinted;
            if (amount > amtTillMax) {
                amount = amtTillMax;
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL
    ////////////////////////////////////////////////////////////////////////////

    function processRewardsInternal() internal returns (TokenAmount[] memory processed_) {
        // 1. Claim BAL and AURA rewards
        (uint256 totalBal, uint256 totalAura) = claimAndRegisterRewards();

        // 2. Swap some for USDC and send to owner
        uint256 balForUsdc = (totalBal * sellBpsBalToUsdc) / MAX_BPS;
        uint256 auraForUsdc = (totalAura * sellBpsAuraToUsdc) / MAX_BPS;

        uint256 usdcEarnedFromBal = swapBalForUsdc(balForUsdc);
        uint256 usdcEarnedFromAura = swapAuraForUsdc(auraForUsdc);

        uint256 totalUsdcEarned = usdcEarnedFromBal + usdcEarnedFromAura;

        address ownerCached = owner();
        USDC.safeTransfer(ownerCached, totalUsdcEarned);

        // 3. Deposit remaining BAL to 80BAL-20ETH BPT
        uint256 balToDeposit = totalBal - balForUsdc;
        depositBalToBpt(balToDeposit);

        // 4. Swap BPT for auraBAL or lock
        uint256 balEthBptAmount = BPT_80BAL_20WETH.balanceOf(address(this));
        swapBptForAuraBal(balEthBptAmount);

        // 5. Dogfood auraBAL in Badger vault on behalf of owner
        uint256 auraBalToDeposit = AURABAL.balanceOf(address(this));
        BAURABAL.depositFor(ownerCached, AURABAL.balanceOf(address(this)));

        // 6. Lock remaining AURA on behalf of Badger voter msig
        uint256 auraToLock = totalAura - auraForUsdc;
        AURA_LOCKER.lock(BADGER_VOTER, auraToLock);

        // Return processed amounts
        // TODO: Return vlAura and bauraBal?
        processed_ = new TokenAmount[](3);
        processed_[0] = TokenAmount(address(USDC), totalUsdcEarned);
        processed_[1] = TokenAmount(address(AURA), auraToLock);
        processed_[2] = TokenAmount(address(AURABAL), auraBalToDeposit);

        // Emit events for analysis
        emit RewardsToStable(address(USDC), totalUsdcEarned, block.timestamp);
    }

    function claimAndRegisterRewards() internal returns (uint256 totalBal_, uint256 totalAura_) {
        // Update last claimed time
        lastClaimTimestamp = block.timestamp;

        if (baseRewardPool1.earned(address(this)) > 0) {
            baseRewardPool1.getReward();
        }

        if (baseRewardPool2.earned(address(this)) > 0) {
            baseRewardPool2.getReward();
        }

        totalBal_ = BAL.balanceOf(address(this));
        totalAura_ = AURA.balanceOf(address(this));

        if (totalBal_ == 0) {
            revert NoRewards();
        }

        // Emit events for analysis
        emit RewardClaimed(address(BAL), totalBal_, block.timestamp);
        emit RewardClaimed(address(AURA), totalAura_, block.timestamp);
    }

    function swapBalForUsdc(uint256 _balAmount) internal returns (uint256 usdcEarned) {
        IAsset[] memory assetArray = new IAsset[](3);
        assetArray[0] = IAsset(address(BAL));
        assetArray[1] = IAsset(address(WETH));
        assetArray[2] = IAsset(address(USDC));

        int256[] memory limits = new int256[](3);
        limits[0] = int256(_balAmount);
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
        IAsset[] memory assetArray = new IAsset[](3);
        assetArray[0] = IAsset(address(AURA));
        assetArray[1] = IAsset(address(WETH));
        assetArray[2] = IAsset(address(USDC));

        int256[] memory limits = new int256[](3);
        limits[0] = int256(_auraAmount);
        // Assumes USDC is pegged. We should sell for other stableecoins if not
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
            poolId: AURABAL_BAL_WETH_POOL_ID,
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
}
