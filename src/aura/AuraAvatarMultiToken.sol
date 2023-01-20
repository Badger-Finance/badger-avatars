// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MathUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/math/MathUpgradeable.sol";
import {PausableUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/security/PausableUpgradeable.sol";
import {SafeERC20Upgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {IERC20MetadataUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {EnumerableSetUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/structs/EnumerableSetUpgradeable.sol";

import {BaseAvatar} from "../lib/BaseAvatar.sol";
import {MAX_BPS, PRECISION, CHAINLINK_KEEPER_REGISTRY} from "../BaseConstants.sol";
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
contract AuraAvatarMultiToken is BaseAvatar, PausableUpgradeable, AuraAvatarUtils, KeeperCompatibleInterface {
    ////////////////////////////////////////////////////////////////////////////
    // LIBRARIES
    ////////////////////////////////////////////////////////////////////////////

    using SafeERC20Upgradeable for IERC20MetadataUpgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    ////////////////////////////////////////////////////////////////////////////
    // STORAGE
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Pool IDS (in AURA Booster) of strategy tokens.
    EnumerableSetUpgradeable.UintSet internal pids;

    /// @notice Address of the BPTS.
    EnumerableSetUpgradeable.AddressSet internal assets;

    /// @notice Address of the staking rewards contracts
    EnumerableSetUpgradeable.AddressSet internal baseRewardPools;

    /// @notice Address of the manager of the avatar. Manager has limited permissions and can harvest rewards or
    ///         fine-tune operational settings.
    address public manager;

    /// @notice The frequency (in seconds) at which the keeper should harvest rewards.
    uint256 public claimFrequency;
    /// @notice The duration for which AURA and BAL/ETH BPT TWAPs should be calculated. The TWAPs are used to set
    ///         slippage constraints during swaps.
    uint256 public twapPeriod;

    /// @notice The proportion of AURA that is sold for USDC.
    uint16 public sellBpsAuraToUsdc;

    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for a BAL to USDC swap.
    BpsConfig public minOutBpsBalToUsdc;
    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for an AURA to USDC swap.
    BpsConfig public minOutBpsAuraToUsdc;

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

    error BptStillStaked(address bpt, address basePool, uint256 stakingBalance);
    error PidNotIncluded(uint256 pid);
    error PidAlreadyExist(uint256 pid);

    error LengthMismatch();

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

    event ManagerUpdated(address indexed newManager, address indexed oldManager);

    event TwapPeriodUpdated(uint256 newTwapPeriod, uint256 oldTwapPeriod);
    event ClaimFrequencyUpdated(uint256 newClaimFrequency, uint256 oldClaimFrequency);

    event SellBpsAuraToUsdcUpdated(uint256 newValue, uint256 oldValue);

    event MinOutBpsBalToUsdcMinUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsAuraToUsdcMinUpdated(uint256 newValue, uint256 oldValue);

    event MinOutBpsBalToUsdcValUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsAuraToUsdcValUpdated(uint256 newValue, uint256 oldValue);

    event Deposit(address indexed token, uint256 amount, uint256 timestamp);
    event Withdraw(address indexed token, uint256 amount, uint256 timestamp);

    event RewardClaimed(address indexed token, uint256 amount, uint256 timestamp);
    event RewardsToStable(address indexed token, uint256 amount, uint256 timestamp);

    event ERC20Swept(address indexed token, uint256 amount);

    ////////////////////////////////////////////////////////////////////////////
    // INITIALIZATION
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the avatar. Calls parent intializers, sets default variable values and does token approvals.
    ///         Can only be called once.
    /// @param _owner Address of the initial owner.
    /// @param _manager Address of the initial manager.
    /// @param _pids Pool ID of tokens involved in the avatar
    function initialize(address _owner, address _manager, uint256[] calldata _pids) public initializer {
        __BaseAvatar_init(_owner);
        __Pausable_init();

        manager = _manager;

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

        for (uint256 i; i < _pids.length;) {
            _addBptPositionInfo(_pids[i]);
            unchecked {
                ++i;
            }
        }

        // Balancer vault approvals
        BAL.safeApprove(address(BALANCER_VAULT), type(uint256).max);
        AURA.safeApprove(address(BALANCER_VAULT), type(uint256).max);

        // Aura approval for locker
        AURA.safeApprove(address(AURA_LOCKER), type(uint256).max);
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
        if (msg.sender != CHAINLINK_KEEPER_REGISTRY) {
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

    /// @notice Updates the proportion of AURA that is sold for USDC. Can only be called by owner.
    /// @param _sellBpsAuraToUsdc The new proportion in bps.
    function setSellBpsAuraToUsdc(uint16 _sellBpsAuraToUsdc) external onlyOwner {
        if (_sellBpsAuraToUsdc > MAX_BPS) {
            revert InvalidBps(_sellBpsAuraToUsdc);
        }

        uint16 oldSellBpsAuraToUsdc = sellBpsAuraToUsdc;
        sellBpsAuraToUsdc = _sellBpsAuraToUsdc;

        emit SellBpsAuraToUsdcUpdated(_sellBpsAuraToUsdc, oldSellBpsAuraToUsdc);
    }

    /// @notice Updates the minimum possible value for the minimum executable price (in bps as proportion of an oracle
    ///         price) for a BAL to USDC swap. Can only be called by owner.
    /// @param _minOutBpsBalToUsdcMin The new minimum value in bps.
    function setMinOutBpsBalToUsdcMin(uint16 _minOutBpsBalToUsdcMin) external onlyOwner {
        if (_minOutBpsBalToUsdcMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToUsdcMin);
        }

        uint16 minOutBpsBalToUsdcVal = minOutBpsBalToUsdc.val;
        if (_minOutBpsBalToUsdcMin > minOutBpsBalToUsdcVal) {
            revert MoreThanBpsVal(_minOutBpsBalToUsdcMin, minOutBpsBalToUsdcVal);
        }

        uint16 oldMinOutBpsBalToUsdcMin = minOutBpsBalToUsdc.min;
        minOutBpsBalToUsdc.min = _minOutBpsBalToUsdcMin;

        emit MinOutBpsBalToUsdcMinUpdated(_minOutBpsBalToUsdcMin, oldMinOutBpsBalToUsdcMin);
    }

    /// @notice Updates the minimum possible value for the minimum executable price (in bps as proportion of an oracle
    ///         price) for an AURA to USDC swap. Can only be called by owner.
    /// @param _minOutBpsAuraToUsdcMin The new minimum value in bps.
    function setMinOutBpsAuraToUsdcMin(uint16 _minOutBpsAuraToUsdcMin) external onlyOwner {
        if (_minOutBpsAuraToUsdcMin > MAX_BPS) {
            revert InvalidBps(_minOutBpsAuraToUsdcMin);
        }

        uint16 minOutBpsAuraToUsdcVal = minOutBpsAuraToUsdc.val;
        if (_minOutBpsAuraToUsdcMin > minOutBpsAuraToUsdcVal) {
            revert MoreThanBpsVal(_minOutBpsAuraToUsdcMin, minOutBpsAuraToUsdcVal);
        }

        uint16 oldMinOutBpsAuraToUsdcMin = minOutBpsAuraToUsdc.min;
        minOutBpsAuraToUsdc.min = _minOutBpsAuraToUsdcMin;

        emit MinOutBpsAuraToUsdcMinUpdated(_minOutBpsAuraToUsdcMin, oldMinOutBpsAuraToUsdcMin);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Manager - Config
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Updates the current value for the minimum executable price (in bps as proportion of an oracle price)
    ///         for a BAL to USDC swap. The value should be more than the minimum value. Can be called by the owner or
    ///         the manager.
    /// @param _minOutBpsBalToUsdcVal The new value in bps.
    function setMinOutBpsBalToUsdcVal(uint16 _minOutBpsBalToUsdcVal) external onlyOwnerOrManager {
        if (_minOutBpsBalToUsdcVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsBalToUsdcVal);
        }

        uint16 minOutBpsBalToUsdcMin = minOutBpsBalToUsdc.min;
        if (_minOutBpsBalToUsdcVal < minOutBpsBalToUsdcMin) {
            revert LessThanBpsMin(_minOutBpsBalToUsdcVal, minOutBpsBalToUsdcMin);
        }

        uint16 oldMinOutBpsBalToUsdcVal = minOutBpsBalToUsdc.val;
        minOutBpsBalToUsdc.val = _minOutBpsBalToUsdcVal;

        emit MinOutBpsBalToUsdcValUpdated(_minOutBpsBalToUsdcVal, oldMinOutBpsBalToUsdcVal);
    }

    /// @notice Updates the current value for the minimum executable price (in bps as proportion of an oracle price)
    ///         for an AURA to USDC swap. The value should be more than the minimum value. Can be called by the owner or
    ///         the manager.
    /// @param _minOutBpsAuraToUsdcVal The new value in bps.
    function setMinOutBpsAuraToUsdcVal(uint16 _minOutBpsAuraToUsdcVal) external onlyOwnerOrManager {
        if (_minOutBpsAuraToUsdcVal > MAX_BPS) {
            revert InvalidBps(_minOutBpsAuraToUsdcVal);
        }

        uint16 minOutBpsAuraToUsdcMin = minOutBpsAuraToUsdc.min;
        if (_minOutBpsAuraToUsdcVal < minOutBpsAuraToUsdcMin) {
            revert LessThanBpsMin(_minOutBpsAuraToUsdcVal, minOutBpsAuraToUsdcMin);
        }

        uint16 oldMinOutBpsAuraToUsdcVal = minOutBpsAuraToUsdc.val;
        minOutBpsAuraToUsdc.val = _minOutBpsAuraToUsdcVal;

        emit MinOutBpsAuraToUsdcValUpdated(_minOutBpsAuraToUsdcVal, oldMinOutBpsAuraToUsdcVal);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Takes a given amount of assets from the owner and stakes them on the AURA Booster. Can only be called by owner.
    /// @dev This also initializes the lastClaimTimestamp variable if there are no other deposits.
    /// @param _pids PIDs target to stake into
    /// @param _amountAssets Amount of assets to be staked.
    function deposit(uint256[] calldata _pids, uint256[] calldata _amountAssets) external onlyOwner {
        uint256 pidLength = _pids.length;
        if (pidLength != _amountAssets.length) {
            revert LengthMismatch();
        }
        for (uint256 i; i < pidLength;) {
            // Verify if PID is in storage and amount is > 0
            if (!pids.contains(_pids[i])) {
                revert PidNotIncluded(_pids[i]);
            }
            if (_amountAssets[i] == 0) {
                revert NothingToDeposit();
            }

            // TODO: Cache this value somewhere and avoid call
            (address lpToken,,,,,) = AURA_BOOSTER.poolInfo(_pids[i]);
            // NOTE: Using msg.sender since this function is only callable by owner.
            //       Keep in mind if access control is changed.
            IERC20MetadataUpgradeable(lpToken).safeTransferFrom(msg.sender, address(this), _amountAssets[i]);

            AURA_BOOSTER.deposit(_pids[i], _amountAssets[i], true);

            emit Deposit(lpToken, _amountAssets[i], block.timestamp);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Unstakes all staked assets and transfers them back to owner. Can only be called by owner and manager.
    /// @dev This function doesn't claim any rewards.
    function withdrawAll() external onlyOwnerOrManager {
        uint256 length = baseRewardPools.length();
        uint256[] memory bptsDeposited = new uint256[](length);
        for (uint256 i; i < length;) {
            bptsDeposited[i] = IBaseRewardPool(baseRewardPools.at(i)).balanceOf(address(this));
            unchecked {
                ++i;
            }
        }

        _withdraw(pids.values(), bptsDeposited);
    }

    /// @notice Unstakes the given amount of assets and transfers them back to owner. Can only be called by owner and manager.
    /// @dev This function doesn't claim any rewards.
    /// @param _pids PIDs targetted to withdraw from
    /// @param _amountAssets Amount of assets to be unstaked.
    function withdraw(uint256[] calldata _pids, uint256[] calldata _amountAssets) external onlyOwnerOrManager {
        if (_pids.length != _amountAssets.length) {
            revert LengthMismatch();
        }
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

    /// @dev given a target PID, it will add the details in the `EnumerableSet`: pids, assets & baseRewardPools
    /// @param _newPid target pid numeric value to add in contract's storage
    function addBptPositionInfo(uint256 _newPid) external onlyOwner {
        _addBptPositionInfo(_newPid);
    }

    /// @dev given a target PID, it will remove the details from the `EnumerableSet`: pids, assets & baseRewardPools
    /// @param _removePid target pid numeric value to remove from contract's storage
    function removeBptPositionInfo(uint256 _removePid) external onlyOwner {
        if (!pids.contains(_removePid)) {
            revert PidNotIncluded(_removePid);
        }

        (address lpToken,,, address crvRewards,,) = AURA_BOOSTER.poolInfo(_removePid);
        // NOTE: remove from storage prior to external calls, CEI compliance
        pids.remove(_removePid);
        assets.remove(lpToken);
        baseRewardPools.remove(crvRewards);

        IBaseRewardPool baseRewardPool = IBaseRewardPool(crvRewards);

        uint256 stakedAmount = baseRewardPool.balanceOf(address(this));
        if (stakedAmount > 0) {
            revert BptStillStaked(lpToken, crvRewards, stakedAmount);
        }

        // NOTE: verify pending rewards and claim. Processing is done separately
        if (baseRewardPool.earned(address(this)) > 0) {
            baseRewardPool.getReward();
        }

        // NOTE: while removing the info from storage, we ensure that allowance is set back to zero
        IERC20MetadataUpgradeable(lpToken).safeApprove(address(AURA_BOOSTER), 0);
    }

    /// @notice Sweep the full contract's balance for a given ERC-20 token. Can only be called by owner.
    /// @param token The ERC-20 token which needs to be swept
    function sweep(address token) external onlyOwner {
        IERC20MetadataUpgradeable erc20Token = IERC20MetadataUpgradeable(token);
        uint256 balance = erc20Token.balanceOf(address(this));
        erc20Token.safeTransfer(msg.sender, balance);
        emit ERC20Swept(token, balance);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner/Manager
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Claim and process BAL and AURA rewards, selling some of it to USDC and depositing the rest to bauraBAL
    ///         and vlAURA. Can be called by the owner or manager.
    /// @dev This can be called by the owner or manager to opportunistically harvest in good market conditions.
    /// @param _auraPriceInUsd A reference price for AURA in USD (in 8 decimal precision) to compare with TWAP price. Leave as 0 to use only TWAP.
    /// @return processed_ An array containing addresses and amounts of harvested tokens (i.e. tokens that have finally
    ///                    been swapped into).
    function processRewards(uint256 _auraPriceInUsd)
        external
        onlyOwnerOrManager
        returns (TokenAmount[] memory processed_)
    {
        processed_ = _processRewards(_auraPriceInUsd);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Keeper
    ////////////////////////////////////////////////////////////////////////////

    /// @notice A function to process pending BAL and AURA rewards at regular intervals. Can only be called by the
    ///         keeper when the contract is not paused.
    /// @param _performData ABI-encoded reference price for AURA in USD (in 8 decimal precision) to compare with TWAP price.
    ///                     The first 4 bytes of the encoding are ignored and the rest is decoded into a uint256.
    function performUpkeep(bytes calldata _performData) external override onlyKeeper whenNotPaused {
        uint256 auraPriceInUsd = abi.decode(_performData[4:], (uint256));
        _processRewardsKeeper(auraPriceInUsd);
    }

    /// @notice A function to process pending BAL and AURA rewards at regular intervals. Can only be called by the
    ///         keeper when the contract is not paused.
    /// @param _auraPriceInUsd A reference price for AURA in USD (in 8 decimal precision) to compare with TWAP price.
    function processRewardsKeeper(uint256 _auraPriceInUsd) external onlyKeeper whenNotPaused {
        _processRewardsKeeper(_auraPriceInUsd);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC VIEW
    ////////////////////////////////////////////////////////////////////////////

    /// @notice All PID values
    function getPids() public view returns (uint256[] memory) {
        return pids.values();
    }

    /// @notice All assets addresses
    function getAssets() public view returns (address[] memory) {
        return assets.values();
    }

    /// @notice All rewards pool addresses.
    function getbaseRewardPools() public view returns (address[] memory) {
        return baseRewardPools.values();
    }

    /// @notice The total amounts of both BPT tokens that the avatar is handling.
    function totalAssets() external view returns (uint256[] memory) {
        uint256 length = baseRewardPools.length();
        uint256[] memory assetAmounts = new uint256[](length);

        for (uint256 i; i < length;) {
            assetAmounts[i] = IBaseRewardPool(baseRewardPools.at(i)).balanceOf(address(this));
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
    function pendingRewards() public view returns (uint256 totalBal_, uint256 totalAura_) {
        totalBal_ = BAL.balanceOf(address(this));
        totalAura_ = AURA.balanceOf(address(this));

        uint256 length = baseRewardPools.length();
        for (uint256 i; i < length;) {
            IBaseRewardPool baseRewardPool = IBaseRewardPool(baseRewardPools.at(i));

            uint256 balEarned = baseRewardPool.earned(address(this));
            uint256 balEarnedAdjusted = (balEarned * AURA_BOOSTER.getRewardMultipliers(address(baseRewardPool)))
                / AURA_REWARD_MULTIPLIER_DENOMINATOR;

            totalBal_ += balEarned;
            totalAura_ += getMintableAuraForBalAmount(balEarnedAdjusted);

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Checks whether an upkeep is to be performed.
    /// @dev The calldata is encoded with the `processRewardsKeeper` selector. This selector is ignored when
    ///      performing upkeeps using the `performUpkeep` function.
    /// @return upkeepNeeded_ A boolean indicating whether an upkeep is to be performed.
    /// @return performData_ The calldata to be passed to the upkeep function.
    function checkUpkeep(bytes calldata) external override returns (bool upkeepNeeded_, bytes memory performData_) {
        if ((block.timestamp - lastClaimTimestamp) >= claimFrequency) {
            uint256 balPending;
            uint256 length = baseRewardPools.length();

            for (uint256 i; i < length;) {
                balPending += IBaseRewardPool(baseRewardPools.at(i)).earned(address(this));
                unchecked {
                    ++i;
                }
            }

            uint256 balBalance = BAL.balanceOf(address(this));

            if (balPending > 0 || balBalance > 0) {
                upkeepNeeded_ = true;

                (, uint256 totalAura) = pendingRewards();
                performData_ = abi.encodeCall(this.processRewardsKeeper, getAuraPriceInUsdSpot(totalAura));
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL
    ////////////////////////////////////////////////////////////////////////////

    function _addBptPositionInfo(uint256 _newPid) internal {
        if (pids.contains(_newPid)) {
            revert PidAlreadyExist(_newPid);
        }
        pids.add(_newPid);
        (address lpToken,,, address crvRewards,,) = AURA_BOOSTER.poolInfo(_newPid);
        assets.add(lpToken);
        baseRewardPools.add(crvRewards);
        // Boster approval for bpts
        IERC20MetadataUpgradeable(lpToken).safeApprove(address(AURA_BOOSTER), type(uint256).max);
    }

    /// @notice Unstakes the given amount of assets and transfers them back to owner.
    /// @dev This function doesn't claim any rewards. Caller can only be owner.
    /// @param _pids PIDs to be targetted to unstake from.
    /// @param _amountAssets Amount of assets to be unstaked.
    function _withdraw(uint256[] memory _pids, uint256[] memory _amountAssets) internal {
        for (uint256 i; i < _pids.length;) {
            if (_amountAssets[i] == 0) {
                revert NothingToWithdraw();
            }
            // TODO: Cache
            (address lpToken,,, address crvRewards,,) = AURA_BOOSTER.poolInfo(_pids[i]);

            IBaseRewardPool(crvRewards).withdrawAndUnwrap(_amountAssets[i], false);
            IERC20MetadataUpgradeable(lpToken).safeTransfer(owner(), _amountAssets[i]);

            emit Withdraw(lpToken, _amountAssets[i], block.timestamp);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice A function to process pending BAL and AURA rewards at regular intervals.
    /// @param _auraPriceInUsd A reference price for AURA in USD (in 8 decimal precision) to compare with TWAP price. Leave as 0 to use only TWAP.
    function _processRewardsKeeper(uint256 _auraPriceInUsd) internal {
        uint256 lastClaimTimestampCached = lastClaimTimestamp;
        uint256 claimFrequencyCached = claimFrequency;
        if ((block.timestamp - lastClaimTimestampCached) < claimFrequencyCached) {
            revert TooSoon(block.timestamp, lastClaimTimestampCached, claimFrequencyCached);
        }

        _processRewards(_auraPriceInUsd);
    }

    /// @notice Claim and process BAL and AURA rewards, selling some of it to USDC and depositing the rest to bauraBAL
    ///         and vlAURA.
    /// @return processed_ An array containing addresses and amounts of harvested tokens (i.e. tokens that have finally
    ///                    been swapped into).
    function _processRewards(uint256 _auraPriceInUsd) internal returns (TokenAmount[] memory processed_) {
        // 1. Claim BAL and AURA rewards
        (uint256 totalBal, uint256 totalAura) = claimAndRegisterRewards();

        // 2. Swap some for USDC and send to owner
        uint256 auraForUsdc = (totalAura * sellBpsAuraToUsdc) / MAX_BPS;

        uint256 totalUsdcEarned;
        if (totalBal > 0) {
            totalUsdcEarned = swapBalForUsdc(totalBal);
        }
        if (auraForUsdc > 0) {
            totalUsdcEarned += swapAuraForUsdc(auraForUsdc, _auraPriceInUsd);
        }

        if (totalUsdcEarned > 0) {
            USDC.safeTransfer(owner(), totalUsdcEarned);
        }

        // 3. Lock AURA on behalf of Badger voter msig
        uint256 auraToLock = totalAura - auraForUsdc;
        if (auraToLock > 0) {
            AURA_LOCKER.lock(BADGER_VOTER, auraToLock);
        }

        // Return processed amounts
        processed_ = new TokenAmount[](2);
        processed_[0] = TokenAmount(address(USDC), totalUsdcEarned);
        processed_[1] = TokenAmount(address(AURA), auraToLock);

        // Emit events for analysis
        emit RewardsToStable(address(USDC), totalUsdcEarned, block.timestamp);
    }

    /// @notice Claims pending BAL and AURA rewards from both staking contracts and sets the lastClaimTimestamp value.
    /// @return totalBal_ The total BAL in contract after claiming.
    /// @return totalAura_ The total AURA in contract after claiming.
    function claimAndRegisterRewards() internal returns (uint256 totalBal_, uint256 totalAura_) {
        // Update last claimed time
        lastClaimTimestamp = block.timestamp;

        uint256 length = baseRewardPools.length();
        for (uint256 i; i < length;) {
            IBaseRewardPool baseRewardPool = IBaseRewardPool(baseRewardPools.at(i));
            if (baseRewardPool.earned(address(this)) > 0) {
                baseRewardPool.getReward();
            }
            unchecked {
                ++i;
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
    function swapBalForUsdc(uint256 _balAmount) internal returns (uint256 usdcEarned_) {
        IAsset[] memory assetArray = new IAsset[](3);
        assetArray[0] = IAsset(address(BAL));
        assetArray[1] = IAsset(address(WETH));
        assetArray[2] = IAsset(address(USDC));

        int256[] memory limits = new int256[](3);
        limits[0] = int256(_balAmount);
        limits[2] = -int256((getBalAmountInUsdc(_balAmount) * minOutBpsBalToUsdc.val) / MAX_BPS);
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
    function swapAuraForUsdc(uint256 _auraAmount, uint256 _auraPriceInUsd) internal returns (uint256 usdcEarned_) {
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
            (_auraAmount * _auraPriceInUsd) / AURA_USD_SPOT_FACTOR, getAuraAmountInUsdc(_auraAmount, twapPeriod)
        );
        // Assumes USDC is pegged. We should sell for other stableecoins if not
        limits[2] = -int256((expectedUsdcOut * minOutBpsAuraToUsdc.val) / MAX_BPS);

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

        usdcEarned_ = uint256(-assetBalances[assetBalances.length - 1]);
    }
}
