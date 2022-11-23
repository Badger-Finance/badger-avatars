// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MathUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/math/MathUpgradeable.sol";
import {PausableUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/security/PausableUpgradeable.sol";
import {SafeERC20Upgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {IERC20MetadataUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {EnumerableSetUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/structs/EnumerableSetUpgradeable.sol";

import {BaseAvatar} from "../lib/BaseAvatar.sol";
import {MAX_BPS, PRECISION} from "../BaseConstants.sol";
import {BpsConfig, TokenAmount} from "../BaseStructs.sol";
import {AuraAvatarUtils} from "./AuraAvatarUtils.sol";
import {IBaseRewardPool} from "../interfaces/aura/IBaseRewardPool.sol";
import {IAsset} from "../interfaces/balancer/IAsset.sol";
import {IBalancerVault, JoinKind} from "../interfaces/balancer/IBalancerVault.sol";
import {KeeperCompatibleInterface} from "../interfaces/chainlink/KeeperCompatibleInterface.sol";

/// @title AuraAvatarMultiToken
/// @notice This contract handles multiple Balancer Pool Token (BPT) positions on behalf of an owner. It stakes the BPTs on
///         Aura and has the resulting BAL and AURA rewards periodically harvested by a keeper. Only the owner can
///         deposit and withdraw funds through this contract.
///         The owner also has admin rights and can make arbitrary calls through this contract.
/// @dev The avatar is never supposed to hold funds and only acts as an intermediary to facilitate staking and ease
///      accounting.
contract AuraAvatarMultiToken is
    BaseAvatar,
    PausableUpgradeable,
    AuraAvatarUtils,
    KeeperCompatibleInterface
{
    ////////////////////////////////////////////////////////////////////////////
    // LIBRARIES
    ////////////////////////////////////////////////////////////////////////////

    using SafeERC20Upgradeable for IERC20MetadataUpgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    ////////////////////////////////////////////////////////////////////////////
    // IMMUTABLES
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Pool IDS (in AURA Booster) of strategy tokens.
    EnumerableSetUpgradeable.UintSet internal pids;

    /// @notice Address of the BPTS.
    EnumerableSetUpgradeable.AddressSet internal assets;

    /// @notice Address of the staking rewards contracts
    EnumerableSetUpgradeable.AddressSet internal baseRewardPools;

    ////////////////////////////////////////////////////////////////////////////
    // STORAGE
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Address of the manager of the avatar. Manager has limited permissions and can harvest rewards or
    ///         fine-tune operational settings.
    address public manager;
    /// @notice Address of the keeper of the avatar. Keeper can only harvest rewards at a predefined frequency.
    address public keeper;

    /// @notice The frequency (in seconds) at which the keeper should harvest rewards.
    uint256 public claimFrequency;
    /// @notice The duration for which AURA and BAL/ETH BPT TWAPs should be calculated. The TWAPs are used to set
    ///         slippage constraints during swaps.
    uint256 public twapPeriod;

    /// @notice The proportion of BAL that is sold for USDC.
    uint256 public sellBpsBalToUsdc;
    /// @notice The proportion of AURA that is sold for USDC.
    uint256 public sellBpsAuraToUsdc;

    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for a BAL to USDC swap.
    BpsConfig public minOutBpsBalToUsdc;
    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for an AURA to USDC swap.
    BpsConfig public minOutBpsAuraToUsdc;

    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for a BAL to BAL/ETH BPT swap.
    BpsConfig public minOutBpsBalToBpt;

    /// @notice The timestamp at which rewards were last claimed and harvested.
    uint256 public lastClaimTimestamp;

    ////////////////////////////////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////////////////////////////////

    error NotOwnerOrManager(address caller);
    error NotKeeper(address caller);

    error InvalidBps(uint256 bps);
    error LessThanBpsMin(uint256 bpsVal, uint256 bpsMin);
    error MoreThanBpsVal(uint256 bpsMin, uint256 bpsVal);
    error ZeroTwapPeriod();

    error NothingToDeposit();
    error NothingToWithdraw();
    error NoRewards();

    error TooSoon(uint256 currentTime, uint256 updateTime, uint256 minDuration);

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

    event ManagerUpdated(
        address indexed newManager,
        address indexed oldManager
    );
    event KeeperUpdated(address indexed newKeeper, address indexed oldKeeper);

    event TwapPeriodUpdated(uint256 newTwapPeriod, uint256 oldTwapPeriod);
    event ClaimFrequencyUpdated(
        uint256 newClaimFrequency,
        uint256 oldClaimFrequency
    );

    event MinOutBpsBalToUsdcMinUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsAuraToUsdcMinUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsBalToBptMinUpdated(uint256 newValue, uint256 oldValue);

    event MinOutBpsBalToUsdcValUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsAuraToUsdcValUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsBalToBptValUpdated(uint256 newValue, uint256 oldValue);

    event Deposit(address indexed token, uint256 amount, uint256 timestamp);
    event Withdraw(address indexed token, uint256 amount, uint256 timestamp);

    event RewardClaimed(
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );
    event RewardsToStable(
        address indexed token,
        uint256 amount,
        uint256 timestamp
    );

    ////////////////////////////////////////////////////////////////////////////
    // INITIALIZATION
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Derives the assets to be handled and corresponding reward pools based on the Aura Pool IDs supplied.
    /// @param _pids Pool ID of tokens involved in the avatar
    constructor(uint256[] memory _pids) {
        for (uint256 i = 0; i < _pids.length; i++) {
            pids.add(_pids[i]);
            (address lpToken, , , address crvRewards, , ) = AURA_BOOSTER
                .poolInfo(_pids[i]);
            assets.add(lpToken);
            baseRewardPools.add(crvRewards);
        }
    }

    /// @notice Initializes the avatar. Calls parent intializers, sets default variable values and does token approvals.
    ///         Can only be called once.
    /// @param _owner Address of the initial owner.
    /// @param _manager Address of the initial manager.
    /// @param _keeper Address of the initial keeper.
    function initialize(
        address _owner,
        address _manager,
        address _keeper
    ) public initializer {
        __BaseAvatar_init(_owner);
        __Pausable_init();

        manager = _manager;
        keeper = _keeper;

        claimFrequency = 1 weeks;
        twapPeriod = 1 hours;

        minOutBpsBalToUsdc = BpsConfig({
            val: 9750, // 97.5%
            min: 9000 // 90%
        });
        minOutBpsAuraToUsdc = BpsConfig({
            val: 9750, // 97.5%
            min: 9000 // 90%
        });
        minOutBpsBalToBpt = BpsConfig({
            val: 9950, // 99.5%
            min: 9000 // 90%
        });

        // Booster approval for bpts
        uint256 length = assets.length();
        for (uint256 i = 0; i < length; i++) {
            IERC20MetadataUpgradeable(assets.at(i)).safeApprove(
                address(AURA_BOOSTER),
                type(uint256).max
            );
        }

        // Balancer vault approvals
        BAL.safeApprove(address(BALANCER_VAULT), type(uint256).max);
        AURA.safeApprove(address(BALANCER_VAULT), type(uint256).max);
        BPT_80BAL_20WETH.safeApprove(
            address(BALANCER_VAULT),
            type(uint256).max
        );

        AURA.safeApprove(address(AURA_LOCKER), type(uint256).max);

        BPT_80BAL_20WETH.safeApprove(
            address(AURABAL_DEPOSITOR),
            type(uint256).max
        );
        AURABAL.safeApprove(address(BAURABAL), type(uint256).max);
    }

    ////////////////////////////////////////////////////////////////////////////
    // MODIFIERS
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Checks whether a call is from the owner or manager.
    modifier onlyOwnerOrManager() {
        if (msg.sender != owner() && msg.sender != manager) {
            revert NotOwnerOrManager(msg.sender);
        }
        _;
    }

    /// @notice Checks whether a call is from the keeper.
    modifier onlyKeeper() {
        if (msg.sender != keeper) {
            revert NotKeeper(msg.sender);
        }
        _;
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner - Pausing
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Pauses harvests. Can only be called by the owner or the manager.
    function pause() external onlyOwnerOrManager {
        _pause();
    }

    /// @notice Unpauses harvests. Can only be called by the owner.
    function unpause() external onlyOwner {
        _unpause();
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner - Config
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Updates the manager address. Can only be called by owner.
    /// @param _manager Address of the new manager.
    function setManager(address _manager) external onlyOwner {
        address oldManager = manager;

        manager = _manager;
        emit ManagerUpdated(_manager, oldManager);
    }

    /// @notice Updates the keeper address. Can only be called by owner.
    /// @param _keeper Address of the new keeper.
    function setKeeper(address _keeper) external onlyOwner {
        address oldKeeper = keeper;

        keeper = _keeper;
        emit KeeperUpdated(_keeper, oldKeeper);
    }

    /// @notice Updates the duration for which Balancer TWAPs are calculated. Can only be called by owner.
    /// @param _twapPeriod The new TWAP period in seconds.
    function setTwapPeriod(uint256 _twapPeriod) external onlyOwner {
        if (_twapPeriod == 0) {
            revert ZeroTwapPeriod();
        }

        uint256 oldTwapPeriod = twapPeriod;

        twapPeriod = _twapPeriod;
        emit TwapPeriodUpdated(_twapPeriod, oldTwapPeriod);
    }

    /// @notice Updates the frequency at which rewards are processed by the keeper. Can only be called by owner.
    /// @param _claimFrequency The new claim frequency in seconds.
    function setClaimFrequency(uint256 _claimFrequency) external onlyOwner {
        uint256 oldClaimFrequency = claimFrequency;

        claimFrequency = _claimFrequency;
        emit ClaimFrequencyUpdated(_claimFrequency, oldClaimFrequency);
    }

    /// @notice Updates the minimum possible value for the minimum executable price (in bps as proportion of an oracle
    ///         price) for a BAL to USDC swap. Can only be called by owner.
    /// @param _minOutBpsBalToUsdcMin The new minimum value in bps.
    function setMinOutBpsBalToUsdcMin(uint256 _minOutBpsBalToUsdcMin)
        external
        onlyOwner
    {
        if (_minOutBpsBalToUsdcMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToUsdcMin);
        }

        uint256 minOutBpsBalToUsdcVal = minOutBpsBalToUsdc.val;
        if (_minOutBpsBalToUsdcMin > minOutBpsBalToUsdcVal) {
            revert MoreThanBpsVal(
                _minOutBpsBalToUsdcMin,
                minOutBpsBalToUsdcVal
            );
        }

        uint256 oldMinOutBpsBalToUsdcMin = minOutBpsBalToUsdc.min;
        minOutBpsBalToUsdc.min = _minOutBpsBalToUsdcMin;

        emit MinOutBpsBalToUsdcMinUpdated(
            _minOutBpsBalToUsdcMin,
            oldMinOutBpsBalToUsdcMin
        );
    }

    /// @notice Updates the minimum possible value for the minimum executable price (in bps as proportion of an oracle
    ///         price) for an AURA to USDC swap. Can only be called by owner.
    /// @param _minOutBpsAuraToUsdcMin The new minimum value in bps.
    function setMinOutBpsAuraToUsdcMin(uint256 _minOutBpsAuraToUsdcMin)
        external
        onlyOwner
    {
        if (_minOutBpsAuraToUsdcMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsAuraToUsdcMin);
        }

        uint256 minOutBpsAuraToUsdcVal = minOutBpsAuraToUsdc.val;
        if (_minOutBpsAuraToUsdcMin > minOutBpsAuraToUsdcVal) {
            revert MoreThanBpsVal(
                _minOutBpsAuraToUsdcMin,
                minOutBpsAuraToUsdcVal
            );
        }

        uint256 oldMinOutBpsAuraToUsdcMin = minOutBpsAuraToUsdc.min;
        minOutBpsAuraToUsdc.min = _minOutBpsAuraToUsdcMin;

        emit MinOutBpsAuraToUsdcMinUpdated(
            _minOutBpsAuraToUsdcMin,
            oldMinOutBpsAuraToUsdcMin
        );
    }

    /// @notice Updates the minimum possible value for the minimum executable price (in bps as proportion of an oracle
    ///         price) for a BAL to 80BAL-20WETH BPT swap. Can only be called by owner.
    /// @param _minOutBpsBalToBptMin The new minimum value in bps.
    function setMinOutBpsBalToBptMin(uint256 _minOutBpsBalToBptMin)
        external
        onlyOwner
    {
        if (_minOutBpsBalToBptMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToBptMin);
        }

        uint256 minOutBpsBalToBptVal = minOutBpsBalToBpt.val;
        if (_minOutBpsBalToBptMin > minOutBpsBalToBptVal) {
            revert MoreThanBpsVal(_minOutBpsBalToBptMin, minOutBpsBalToBptVal);
        }

        uint256 oldMinOutBpsBalToBptMin = minOutBpsBalToBpt.min;
        minOutBpsBalToBpt.min = _minOutBpsBalToBptMin;

        emit MinOutBpsBalToBptMinUpdated(
            _minOutBpsBalToBptMin,
            oldMinOutBpsBalToBptMin
        );
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Manager - Config
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Updates the current value for the minimum executable price (in bps as proportion of an oracle price)
    ///         for a BAL to USDC swap. The value should be more than the minimum value. Can be called by the owner or
    ///         the manager.
    /// @param _minOutBpsBalToUsdcVal The new value in bps.
    function setMinOutBpsBalToUsdcVal(uint256 _minOutBpsBalToUsdcVal)
        external
        onlyOwnerOrManager
    {
        if (_minOutBpsBalToUsdcVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToUsdcVal);
        }

        uint256 minOutBpsBalToUsdcMin = minOutBpsBalToUsdc.min;
        if (_minOutBpsBalToUsdcVal < minOutBpsBalToUsdcMin) {
            revert LessThanBpsMin(
                _minOutBpsBalToUsdcVal,
                minOutBpsBalToUsdcMin
            );
        }

        uint256 oldMinOutBpsBalToUsdcVal = minOutBpsBalToUsdc.val;
        minOutBpsBalToUsdc.val = _minOutBpsBalToUsdcVal;

        emit MinOutBpsBalToUsdcValUpdated(
            _minOutBpsBalToUsdcVal,
            oldMinOutBpsBalToUsdcVal
        );
    }

    /// @notice Updates the current value for the minimum executable price (in bps as proportion of an oracle price)
    ///         for an AURA to USDC swap. The value should be more than the minimum value. Can be called by the owner or
    ///         the manager.
    /// @param _minOutBpsAuraToUsdcVal The new value in bps.
    function setMinOutBpsAuraToUsdcVal(uint256 _minOutBpsAuraToUsdcVal)
        external
        onlyOwnerOrManager
    {
        if (_minOutBpsAuraToUsdcVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsAuraToUsdcVal);
        }

        uint256 minOutBpsAuraToUsdcMin = minOutBpsAuraToUsdc.min;
        if (_minOutBpsAuraToUsdcVal < minOutBpsAuraToUsdcMin) {
            revert LessThanBpsMin(
                _minOutBpsAuraToUsdcVal,
                minOutBpsAuraToUsdcMin
            );
        }

        uint256 oldMinOutBpsAuraToUsdcVal = minOutBpsAuraToUsdc.val;
        minOutBpsAuraToUsdc.val = _minOutBpsAuraToUsdcVal;

        emit MinOutBpsAuraToUsdcValUpdated(
            _minOutBpsAuraToUsdcVal,
            oldMinOutBpsAuraToUsdcVal
        );
    }

    /// @notice Updates the current value for the minimum executable price (in bps as proportion of an oracle price)
    ///         for a BAL to 80BAL-20WETH BPT swap. The value should be more than the minimum value. Can be called by
    ///         the owner or the manager.
    /// @param _minOutBpsBalToBptVal The new value in bps.
    function setMinOutBpsBalToBptVal(uint256 _minOutBpsBalToBptVal)
        external
        onlyOwnerOrManager
    {
        if (_minOutBpsBalToBptVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToBptVal);
        }

        uint256 minOutBpsBalToBptMin = minOutBpsBalToBpt.min;
        if (_minOutBpsBalToBptVal < minOutBpsBalToBptMin) {
            revert LessThanBpsMin(_minOutBpsBalToBptVal, minOutBpsBalToBptMin);
        }

        uint256 oldMinOutBpsBalToBptVal = minOutBpsBalToBpt.val;
        minOutBpsBalToBpt.val = _minOutBpsBalToBptVal;

        emit MinOutBpsBalToBptValUpdated(
            _minOutBpsBalToBptVal,
            oldMinOutBpsBalToBptVal
        );
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Takes a given amount of assets from the owner and stakes them on the AURA Booster. Can only be called by owner.
    /// @dev This also initializes the lastClaimTimestamp variable if there are no other deposits.
    /// @param _pids Pids target to stake into
    /// @param _amountAssets Amount of assets to be staked.
    function deposit(
        uint256[] memory _pids,
        uint256[] memory _amountAssets,
        bool initialDeposit
    ) external onlyOwner {
        if (initialDeposit) {
            // Initialize at first deposit
            require(lastClaimTimestamp == 0, "Already initialised");
            lastClaimTimestamp = block.timestamp;
        }

        for (uint256 i = 0; i < _pids.length; i++) {
            if (_amountAssets[i] == 0) {
                revert NothingToDeposit();
            }
            (address lpToken, , , , , ) = AURA_BOOSTER.poolInfo(_pids[i]);
            IERC20MetadataUpgradeable(lpToken).safeTransferFrom(
                msg.sender,
                address(this),
                _amountAssets[i]
            );

            AURA_BOOSTER.deposit(_pids[i], _amountAssets[i], true);

            emit Deposit(lpToken, _amountAssets[i], block.timestamp);
        }
    }

    /// @notice Unstakes all staked assets and transfers them back to owner. Can only be called by owner.
    /// @dev This function doesn't claim any rewards.
    function withdrawAll() external onlyOwner {
        uint256 length = baseRewardPools.length();
        uint256[] memory bptsDeposited = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            bptsDeposited[i] = IBaseRewardPool(baseRewardPools.at(i)).balanceOf(
                address(this)
            );
        }

        _withdraw(pids.values(), bptsDeposited);
    }

    /// @notice Unstakes the given amount of assets and transfers them back to owner. Can only be called by owner.
    /// @dev This function doesn't claim any rewards.
    /// @param _pids Pids targetted to withdraw from
    /// @param _amountAssets Amount of assets to be unstaked.
    function withdraw(uint256[] memory _pids, uint256[] memory _amountAssets)
        external
        onlyOwner
    {
        _withdraw(_pids, _amountAssets);
    }

    /// @notice Claims any pending BAL and AURA rewards and sends them to owner. Can only be called by owner.
    /// @dev This is a failsafe to handle rewards manually in case anything goes wrong (eg. rewards need to be sold
    ///      through other pools)
    function claimRewardsAndSendToOwner() external onlyOwner {
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

    /// @notice Claim and process BAL and AURA rewards, selling some of it to USDC and depositing the rest to bauraBAL
    ///         and vlAURA. Can be called by the owner or manager.
    /// @dev This can be called by the owner or manager to opportunistically harvest in good market conditions.
    /// @return processed_ An array containing addresses and amounts of harvested tokens (i.e. tokens that have finally
    ///                    been swapped into).
    function processRewards()
        external
        onlyOwnerOrManager
        returns (TokenAmount[] memory processed_)
    {
        processed_ = _processRewards();
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Keeper
    ////////////////////////////////////////////////////////////////////////////

    /// @notice A function to process pending BAL and AURA rewards at regular intervals. Can only be called by the
    ///         keeper when the contract is not paused.
    /// @param _performData ABI-encoded reference price for AURA in USD (in 8 decimal precision) to compare with TWAP price.
    ///                     The first 4 bytes of the encoding are ignored and the rest is decoded into a uint256.
    function performUpkeep(bytes calldata _performData)
        external
        override
        onlyKeeper
        whenNotPaused
    {
        _processRewardsKeeper();
    }

    /// @notice A function to process pending BAL and AURA rewards at regular intervals. Can only be called by the
    ///         keeper when the contract is not paused.
    function processRewardsKeeper() external onlyKeeper whenNotPaused {
        _processRewardsKeeper();
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC VIEW
    ////////////////////////////////////////////////////////////////////////////

    /// @notice The total amounts of both BPT tokens that the avatar is handling.
    function totalAssets() external view returns (uint256[] memory) {
        uint256 length = baseRewardPools.length();
        uint256[] memory assetAmounts = new uint256[](length);

        for (uint256 i = 0; i < length; ) {
            assetAmounts[i] = IBaseRewardPool(baseRewardPools.at(i)).balanceOf(
                address(this)
            );
            unchecked {
                ++i;
            }
        }

        return assetAmounts;
    }

    /// @notice The pending BAL and AURA rewards that are yet to be processed.
    /// @dev Includes any BAL and AURA tokens in the contract.
    /// @return totalBal_ Pending BAL rewards.
    /// @return totalAura_ Pending AURA rewards.
    function pendingRewards()
        public
        view
        returns (uint256 totalBal_, uint256 totalAura_)
    {
        uint256 balEarned;
        uint256 length = baseRewardPools.length();

        for (uint256 i = 0; i < length; ) {
            balEarned += IBaseRewardPool(baseRewardPools.at(i)).earned(
                address(this)
            );
            unchecked {
                ++i;
            }
        }

        totalBal_ = balEarned + BAL.balanceOf(address(this));
        totalAura_ =
            getMintableAuraForBalAmount(balEarned) +
            AURA.balanceOf(address(this));
    }

    /// @notice Checks whether an upkeep is to be performed.
    /// @dev The calldata is encoded with the `processRewardsKeeper` selector. This selector is ignored when
    ///      performing upkeeps using the `performUpkeep` function.
    /// @return upkeepNeeded_ A boolean indicating whether an upkeep is to be performed.
    /// @return performData_ The calldata to be passed to the upkeep function.
    function checkUpkeep(bytes calldata)
        external
        override
        returns (bool upkeepNeeded_, bytes memory performData_)
    {
        uint256 balPending;
        uint256 length = baseRewardPools.length();

        for (uint256 i = 0; i < length; ) {
            balPending += IBaseRewardPool(baseRewardPools.at(i)).earned(
                address(this)
            );
            unchecked {
                ++i;
            }
        }

        uint256 balBalance = BAL.balanceOf(address(this));

        if ((block.timestamp - lastClaimTimestamp) >= claimFrequency) {
            if (balPending > 0 || balBalance > 0) {
                upkeepNeeded_ = true;
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Unstakes the given amount of assets and transfers them back to owner.
    /// @dev This function doesn't claim any rewards. Caller can only be owner.
    /// @param _pids Pids to be targetted to unstake from.
    /// @param _bptsDeposited Amount of assets to be unstaked.
    function _withdraw(uint256[] memory _pids, uint256[] memory _bptsDeposited)
        internal
    {
        for (uint256 i = 0; i < _pids.length; i++) {
            if (_bptsDeposited[i] == 0) {
                revert NothingToWithdraw();
            }
            (address lpToken, , , address crvRewards, , ) = AURA_BOOSTER
                .poolInfo(_pids[i]);

            IBaseRewardPool(crvRewards).withdrawAndUnwrap(
                _bptsDeposited[i],
                false
            );
            IERC20MetadataUpgradeable(lpToken).safeTransfer(
                msg.sender,
                _bptsDeposited[i]
            );

            emit Withdraw(lpToken, _bptsDeposited[i], block.timestamp);
        }
    }

    /// @notice A function to process pending BAL and AURA rewards at regular intervals.
    function _processRewardsKeeper() internal {
        uint256 lastClaimTimestampCached = lastClaimTimestamp;
        uint256 claimFrequencyCached = claimFrequency;
        if (
            (block.timestamp - lastClaimTimestampCached) < claimFrequencyCached
        ) {
            revert TooSoon(
                block.timestamp,
                lastClaimTimestampCached,
                claimFrequencyCached
            );
        }

        _processRewards();
    }

    /// @notice Claim and process BAL and AURA rewards, selling some of it to USDC and depositing the rest to bauraBAL
    ///         and vlAURA.
    /// @return processed_ An array containing addresses and amounts of harvested tokens (i.e. tokens that have finally
    ///                    been swapped into).
    function _processRewards()
        internal
        returns (TokenAmount[] memory processed_)
    {
        // 1. Claim BAL and AURA rewards
        (uint256 totalBal, uint256 totalAura) = claimAndRegisterRewards();

        uint256 totalUsdcEarned;
        if (totalBal > 0) {
            totalUsdcEarned = swapBalForUsdc(totalBal);
        }

        address ownerCached = owner();
        if (totalUsdcEarned > 0) {
            USDC.safeTransfer(ownerCached, totalUsdcEarned);
        }

        // 6. Lock remaining AURA on behalf of Badger voter msig
        if (totalAura > 0) {
            AURA_LOCKER.lock(BADGER_VOTER, totalAura);
        }

        // Return processed amounts
        processed_ = new TokenAmount[](2);
        processed_[0] = TokenAmount(address(USDC), totalUsdcEarned);
        processed_[1] = TokenAmount(address(AURA), totalAura);

        // Emit events for analysis
        emit RewardsToStable(address(USDC), totalUsdcEarned, block.timestamp);
    }

    /// @notice Claims pending BAL and AURA rewards from both staking contracts and sets the lastClaimTimestamp value.
    /// @return totalBal_ The total BAL in contract after claiming.
    /// @return totalAura_ The total AURA in contract after claiming.
    function claimAndRegisterRewards()
        internal
        returns (uint256 totalBal_, uint256 totalAura_)
    {
        // Update last claimed time
        lastClaimTimestamp = block.timestamp;

        uint256 length = baseRewardPools.length();
        for (uint256 i = 0; i < length; i++) {
            IBaseRewardPool baseRewardPool = IBaseRewardPool(
                baseRewardPools.at(i)
            );
            if (baseRewardPool.earned(address(this)) > 0) {
                baseRewardPool.getReward();
            }
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

    /// @notice Swaps the given amount of BAL for USDC.
    /// @dev The swap is only carried out if the execution price is within a predefined threshold (given by
    ///      minOutBpsBalToUsdc.val) of the oracle price.
    ///      A BAL-USD Chainlink price feed is used as the oracle.
    /// @param _balAmount The amount of BAL to sell.
    /// @return usdcEarned_ The amount of USDC earned.
    function swapBalForUsdc(uint256 _balAmount)
        internal
        returns (uint256 usdcEarned_)
    {
        IAsset[] memory assetArray = new IAsset[](3);
        assetArray[0] = IAsset(address(BAL));
        assetArray[1] = IAsset(address(WETH));
        assetArray[2] = IAsset(address(USDC));

        int256[] memory limits = new int256[](3);
        limits[0] = int256(_balAmount);
        limits[2] = -int256(
            (getBalAmountInUsdc(_balAmount) * minOutBpsBalToUsdc.val) / MAX_BPS
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
            assetArray,
            fundManagement,
            limits,
            type(uint256).max
        );

        usdcEarned_ = uint256(-assetBalances[assetBalances.length - 1]);
    }

    /// @notice Swaps the given amount of AURA for USDC.
    /// @dev The swap is only carried out if the execution price is within a predefined threshold (given by
    ///      minOutBpsAuraToUsdc.val) of the oracle price.
    ///      A combination of the Balancer TWAP for the 80AURA-20WETH pool and a ETH-USD Chainlink price feed is used
    ///      as the oracle.
    /// @param _auraAmount The amount of AURA to sell.
    /// @param _auraPriceInUsd A reference price for AURA in USD (in 8 decimal precision) to compare with TWAP price. Leave as 0 to use only TWAP.
    /// @return usdcEarned_ The amount of USDC earned.
    function swapAuraForUsdc(uint256 _auraAmount, uint256 _auraPriceInUsd)
        internal
        returns (uint256 usdcEarned_)
    {
        IAsset[] memory assetArray = new IAsset[](3);
        assetArray[0] = IAsset(address(AURA));
        assetArray[1] = IAsset(address(WETH));
        assetArray[2] = IAsset(address(USDC));

        int256[] memory limits = new int256[](3);
        limits[0] = int256(_auraAmount);
        // Use max(TWAP price, reference price) as oracle price for AURA.
        // If reference price is the spot price then swap will only process if:
        //  1. TWAP price is less than spot price.
        //  2. TWAP price is within the slippage threshold of spot price.
        uint256 expectedUsdcOut = MathUpgradeable.max(
            (_auraAmount * _auraPriceInUsd) / AURA_USD_SPOT_FACTOR,
            getAuraAmountInUsdc(_auraAmount, twapPeriod)
        );
        // Assumes USDC is pegged. We should sell for other stableecoins if not
        limits[2] = -int256(
            (expectedUsdcOut * minOutBpsAuraToUsdc.val) / MAX_BPS
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
            assetArray,
            fundManagement,
            limits,
            type(uint256).max
        );

        usdcEarned_ = uint256(-assetBalances[assetBalances.length - 1]);
    }

    /// @notice Deposits the given amount of BAL into the 80BAL-20WETH pool.
    /// @dev The deposit is only carried out if the exchange rate is within a predefined threshold (given by
    ///      minOutBpsBalToBpt.val) of the Balancer TWAP.
    /// @param _balAmount The amount of BAL to deposit.
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
                    (getBalAmountInBpt(_balAmount) * minOutBpsBalToBpt.val) /
                        MAX_BPS
                ),
                fromInternalBalance: false
            })
        );
    }

    /// @notice Either swaps or deposits the given amount of 80BAL-20WETH BPT for auraBAL.
    /// @dev A swap is carried out if the execution price is better than 1:1, otherwise falls back to a deposit.
    /// @param _bptAmount The amount of 80BAL-20WETH BPT to swap or deposit.
    function swapBptForAuraBal(uint256 _bptAmount) internal {
        IBalancerVault.SingleSwap memory swapParam = IBalancerVault.SingleSwap({
            poolId: AURABAL_BAL_WETH_POOL_ID,
            kind: IBalancerVault.SwapKind.GIVEN_IN,
            assetIn: IAsset(address(BPT_80BAL_20WETH)),
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

        // Take the trade if we get more than 1: 1 auraBal out
        try
            BALANCER_VAULT.swap(
                swapParam,
                fundManagement,
                _bptAmount, // minOut
                type(uint256).max
            )
        returns (uint256) {} catch {
            // Otherwise deposit
            AURABAL_DEPOSITOR.deposit(_bptAmount, true, address(0));
        }
    }
}
