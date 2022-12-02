// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PausableUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/security/PausableUpgradeable.sol";
import {SafeERC20Upgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {IERC20MetadataUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {EnumerableSetUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/structs/EnumerableSetUpgradeable.sol";

import {IUniswapRouterV3} from "../interfaces/uniswap/IUniswapRouterV3.sol";

import {BaseAvatar} from "../lib/BaseAvatar.sol";
import {MAX_BPS} from "../BaseConstants.sol";
import {BpsConfig, TokenAmount} from "../BaseStructs.sol";
import {ConvexAvatarUtils} from "./ConvexAvatarUtils.sol";
import {IBaseRewardPool} from "../interfaces/aura/IBaseRewardPool.sol";
import {IStakingProxy} from "../interfaces/convex/IStakingProxy.sol";
import {IFraxUnifiedFarm} from "../interfaces/convex/IFraxUnifiedFarm.sol";
import {KeeperCompatibleInterface} from "../interfaces/chainlink/KeeperCompatibleInterface.sol";

/// @title ConvexAvatarMultiToken
/// @notice This contract handles multiple Curve Pool Token positions on behalf of an owner. It stakes the curve LPs on
///         Convex and has the resulting CRV, CVX & FXS rewards periodically harvested by a keeper. Only the owner can
///         deposit and withdraw funds through this contract.
///         The owner also has admin rights and can make arbitrary calls through this contract.
/// @dev The avatar is never supposed to hold funds and only acts as an intermediary to facilitate staking and ease
///      accounting.
contract ConvexAvatarMultiToken is BaseAvatar, ConvexAvatarUtils, PausableUpgradeable, KeeperCompatibleInterface {
    ////////////////////////////////////////////////////////////////////////////
    // LIBRARIES
    ////////////////////////////////////////////////////////////////////////////

    using SafeERC20Upgradeable for IERC20MetadataUpgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.UintSet;

    ////////////////////////////////////////////////////////////////////////////
    // STORAGE
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Address of the manager of the avatar. Manager has limited permissions and can harvest rewards or
    ///         fine-tune operational settings.
    address public manager;
    /// @notice Address of the keeper of the avatar. Keeper can only harvest rewards at a predefined frequency.
    address public keeper;

    /// @notice Pool IDS (in CONVEX Booster) of strategy tokens.
    EnumerableSetUpgradeable.UintSet internal pids;

    /// @notice Address of the Curve Lps.
    EnumerableSetUpgradeable.AddressSet internal assets;

    /// @notice Address of the staking rewards contracts
    EnumerableSetUpgradeable.AddressSet internal baseRewardPools;

    /// @notice The frequency (in seconds) at which the keeper should harvest rewards.
    uint256 public claimFrequency;

    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for a CRV to WETH swap.
    BpsConfig public minOutBpsCrvToWeth;
    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for an CVX to WETH swap.
    BpsConfig public minOutBpsCvxToWeth;
    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for an FXS to FRAX swap.
    BpsConfig public minOutBpsFxsToFrax;
    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for an WETH to USDC swap.
    BpsConfig public minOutBpsWethToUsdc;
    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for an FRAX to DAI swap.
    BpsConfig public minOutBpsFraxToDai;

    /// @notice The timestamp at which rewards were last claimed and harvested.
    uint256 public lastClaimTimestamp;

    /// @notice Pool IDS (in CONVEX-FRAX Booster) of strategy tokens.
    EnumerableSetUpgradeable.UintSet internal pidsPrivateVaults;

    /// @dev holds the relation between pid in convex-frax system and private vaults avatar created
    mapping(uint256 => address) public privateVaults;
    mapping(address => bytes32[]) public kekIds;

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

    error CurveLpStillStaked(address curveLp, address basePool, uint256 stakingBalance);

    error PoolDeactivated(uint256 pid);
    error PidNotIncluded(uint256 pid);
    error NoPrivateVaultForPid(uint256 pid);

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

    event ManagerUpdated(address indexed newManager, address indexed oldManager);
    event KeeperUpdated(address indexed newKeeper, address indexed oldKeeper);

    event ClaimFrequencyUpdated(uint256 newClaimFrequency, uint256 oldClaimFrequency);

    event MinOutBpsCrvToWethValUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsCvxToWethValUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsFxsToFraxValUpdated(uint256 newValue, uint256 oldValue);
    event MinOutBpsWethToUsdcValUpdated(uint256 newValue, uint256 oldValue);

    event Deposit(address indexed token, uint256 amount, uint256 timestamp);
    event Withdraw(address indexed token, uint256 amount, uint256 timestamp);

    event RewardClaimed(address indexed token, uint256 amount, uint256 timestamp);
    event RewardsToStable(address indexed token, uint256 amount, uint256 timestamp);

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

    function initialize(
        address _owner,
        address _manager,
        address _keeper,
        uint256[] memory _pids,
        uint256[] memory _fraxPids
    ) public initializer {
        __BaseAvatar_init(_owner);
        __Pausable_init();

        manager = _manager;
        keeper = _keeper;

        claimFrequency = 1 weeks;

        // store vanilla convex pids and approve their lpToken
        for (uint256 i; i < _pids.length;) {
            pids.add(_pids[i]);
            (address lpToken,,, address crvRewards,,) = CONVEX_BOOSTER.poolInfo(_pids[i]);
            assets.add(lpToken);
            baseRewardPools.add(crvRewards);
            // NOTE: during loop approve those assets to convex booster
            IERC20MetadataUpgradeable(lpToken).safeApprove(address(CONVEX_BOOSTER), type(uint256).max);
            unchecked {
                ++i;
            }
        }

        // create private vaults for convex-frax pids
        for (uint256 i; i < _fraxPids.length;) {
            _createPrivateVault(_fraxPids[i]);
            unchecked {
                ++i;
            }
        }

        minOutBpsCrvToWeth = BpsConfig({
            val: 9850, // 98.5%
            min: 9500 // 95%
        });
        minOutBpsCvxToWeth = BpsConfig({
            val: 9850, // 98.5%
            min: 9500 // 95%
        });
        minOutBpsFxsToFrax = BpsConfig({
            val: 9850, // 98.5%
            min: 9500 // 95%
        });
        minOutBpsWethToUsdc = BpsConfig({
            val: 9850, // 98.5%
            min: 9500 // 95%
        });
        minOutBpsFraxToDai = BpsConfig({
            val: 9850, // 98.5%
            min: 9500 // 95%
        });

        // aproval for curve pools: crv, cvx & frax
        CRV.safeApprove(address(CRV_ETH_CURVE_POOL), type(uint256).max);
        CVX.safeApprove(address(CVX_ETH_CURVE_POOL), type(uint256).max);
        FRAX.safeApprove(address(FRAX_3CRV_CURVE_POOL), type(uint256).max);

        // approvals for fraxswap route: fxs
        FXS.safeApprove(address(FRAXSWAP_ROUTER), type(uint256).max);

        // approval for univ3 router: weth
        WETH.safeApprove(address(UNIV3_ROUTER), type(uint256).max);
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

    /// @notice Updates the frequency at which rewards are processed by the keeper. Can only be called by owner.
    /// @param _claimFrequency The new claim frequency in seconds.
    function setClaimFrequency(uint256 _claimFrequency) external onlyOwner {
        uint256 oldClaimFrequency = claimFrequency;

        claimFrequency = _claimFrequency;
        emit ClaimFrequencyUpdated(_claimFrequency, oldClaimFrequency);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Manager - Config
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Updates the current value for the minimum executable price (in bps as proportion of an oracle price)
    ///         for a CRV to WETH swap. The value should be more than the minimum value. Can be called by the owner or
    ///         the manager.
    /// @param _minOutBpsCrvToWeth The new value in bps.
    function setMinOutBpsCrvToWethVal(uint256 _minOutBpsCrvToWeth) external onlyOwnerOrManager {
        if (_minOutBpsCrvToWeth > MAX_BPS) {
            revert InvalidBps(_minOutBpsCrvToWeth);
        }

        uint256 minOutBpsCrvToWethMin = minOutBpsCrvToWeth.min;
        if (_minOutBpsCrvToWeth < minOutBpsCrvToWethMin) {
            revert LessThanBpsMin(_minOutBpsCrvToWeth, minOutBpsCrvToWethMin);
        }

        uint256 oldMinOutBpsCrvToWethVal = minOutBpsCrvToWeth.val;
        minOutBpsCrvToWeth.val = _minOutBpsCrvToWeth;

        emit MinOutBpsCrvToWethValUpdated(_minOutBpsCrvToWeth, oldMinOutBpsCrvToWethVal);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner
    ////////////////////////////////////////////////////////////////////////////

    function createPrivateVault(uint256 _pid) external onlyOwner {
        _createPrivateVault(_pid);
    }

    /// @notice Takes a given amount of asset from the owner and stakes them on private vault. Can only be called by owner.
    /// @param _pid Pid target to stake into its appropiate vault
    /// @param _amountAsset Amount of asset to be lock.
    function depositInPrivateVault(uint256 _pid, uint256 _amountAsset) external onlyOwner returns (bytes32 kekId) {
        if (_amountAsset == 0) {
            revert NothingToDeposit();
        }

        address vaultAddr = privateVaults[_pid];
        if (vaultAddr == address(0)) {
            revert NoPrivateVaultForPid(_pid);
        }

        IStakingProxy proxy = IStakingProxy(vaultAddr);
        address stakingToken = proxy.stakingToken();
        IFraxUnifiedFarm farm = IFraxUnifiedFarm(proxy.stakingAddress());

        IERC20MetadataUpgradeable(stakingToken).safeTransferFrom(msg.sender, address(this), _amountAsset);
        /// NOTE: we always try to lock for the min duration allowed
        kekId = proxy.stakeLocked(_amountAsset, farm.lock_time_min());
        /// @dev detailed required to enable withdrawls later
        kekIds[vaultAddr].push(kekId);

        emit Deposit(stakingToken, _amountAsset, block.timestamp);
    }

    /// @notice Unstakes all staked assets and transfers them back to owner. Can only be called by owner.
    /// It will loop thru all existent keks and withdraw fully from each of them.
    /// @dev This function doesn't claim any rewards.
    /// @param _pid Pid target to withdraw from avatar private vault
    function withdrawFromPrivateVault(uint256 _pid) external onlyOwner {
        address vaultAddr = privateVaults[_pid];

        if (vaultAddr == address(0)) {
            revert NoPrivateVaultForPid(_pid);
        }

        IStakingProxy proxy = IStakingProxy(vaultAddr);
        uint256 lockedBal = IFraxUnifiedFarm(proxy.stakingAddress()).lockedLiquidityOf(vaultAddr);
        if (lockedBal == 0) {
            revert NothingToWithdraw();
        }

        bytes32[] memory keks = kekIds[vaultAddr];

        for (uint256 i = 0; i < keks.length;) {
            proxy.withdrawLockedAndUnwrap(keks[i]);
            unchecked {
                ++i;
            }
        }

        IERC20MetadataUpgradeable curveLp = IERC20MetadataUpgradeable(proxy.curveLpToken());
        uint256 curveLpBalance = curveLp.balanceOf(address(this));
        curveLp.safeTransfer(msg.sender, curveLpBalance);

        delete kekIds[vaultAddr];

        emit Withdraw(address(curveLp), curveLpBalance, block.timestamp);
    }

    /// @notice Takes a given amount of assets from the owner and stakes them on the CONVEX Booster. Can only be called by owner.
    /// @param _pids Pids target to stake into
    /// @param _amountAssets Amount of assets to be staked.
    function deposit(uint256[] memory _pids, uint256[] memory _amountAssets) external onlyOwner {
        for (uint256 i = 0; i < _pids.length; i++) {
            /// @dev verify if pid is in storage and amount is > 0
            if (!pids.contains(_pids[i])) {
                revert PidNotIncluded(_pids[i]);
            }
            if (_amountAssets[i] == 0) {
                revert NothingToDeposit();
            }

            (address lpToken,,,,,) = CONVEX_BOOSTER.poolInfo(_pids[i]);
            IERC20MetadataUpgradeable(lpToken).safeTransferFrom(msg.sender, address(this), _amountAssets[i]);

            CONVEX_BOOSTER.deposit(_pids[i], _amountAssets[i], true);

            emit Deposit(lpToken, _amountAssets[i], block.timestamp);
        }
    }

    /// @notice Unstakes all staked assets and transfers them back to owner. Can only be called by owner.
    /// @dev This function doesn't claim any rewards.
    function withdrawAll() external onlyOwner {
        uint256 length = baseRewardPools.length();
        uint256[] memory bptsDeposited = new uint256[](length);
        for (uint256 i = 0; i < length; i++) {
            bptsDeposited[i] = IBaseRewardPool(baseRewardPools.at(i)).balanceOf(address(this));
        }

        _withdraw(pids.values(), bptsDeposited);
    }

    /// @notice Unstakes the given amount of assets and transfers them back to owner. Can only be called by owner.
    /// @dev This function doesn't claim any rewards.
    /// @param _pids Pids targetted to withdraw from
    /// @param _amountAssets Amount of assets to be unstaked.
    function withdraw(uint256[] memory _pids, uint256[] memory _amountAssets) external onlyOwner {
        _withdraw(_pids, _amountAssets);
    }

    /// @notice Claims any pending CRV, CVX & FXS rewards and sends them to owner. Can only be called by owner.
    /// @dev This is a failsafe to handle rewards manually in case anything goes wrong (eg. rewards need to be sold
    ///      through other pools)
    function claimRewardsAndSendToOwner() external onlyOwner {
        address ownerCached = owner();
        // 1. Claim CVX, CRV & FXS rewards
        (uint256 totalCrv, uint256 totalCvx, uint256 totalFxs) = claimAndRegisterRewards();

        // 2. Send to owner
        CRV.safeTransfer(ownerCached, totalCrv);
        CVX.safeTransfer(ownerCached, totalCvx);
        if (totalFxs > 0) {
            FXS.safeTransfer(ownerCached, totalFxs);
        }
    }

    /// @dev given a target PID, it will add the details in the `EnumerableSet`: pids, assets & baseRewardPools
    /// @param _newPid target pid numeric value to add in contract's storage
    function addCurveLpPositionInfo(uint256 _newPid) external onlyOwner {
        pids.add(_newPid);
        (address lpToken,,, address crvRewards,,) = CONVEX_BOOSTER.poolInfo(_newPid);
        assets.add(lpToken);
        baseRewardPools.add(crvRewards);
    }

    /// @dev given a target PID, it will remove the details from the `EnumerableSet`: pids, assets & baseRewardPools
    /// @param _removePid target pid numeric value to remove from contract's storage
    function removeCurveLpPositionInfo(uint256 _removePid) external onlyOwner {
        if (!pids.contains(_removePid)) {
            revert PidNotIncluded(_removePid);
        }

        (address lpToken,,, address crvRewards,,) = CONVEX_BOOSTER.poolInfo(_removePid);
        uint256 stakedBal = IBaseRewardPool(crvRewards).balanceOf(address(this));
        if (stakedBal > 0) {
            revert CurveLpStillStaked(lpToken, crvRewards, stakedBal);
        }

        // NOTE: indeed if nothing is staked, then remove from storage
        pids.remove(_removePid);
        assets.remove(lpToken);
        baseRewardPools.remove(crvRewards);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner/Manager
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Claim and process CRV, CVX & FXS rewards, selling them for stables: USDC & FRAX
    /// @dev This can be called by the owner or manager to opportunistically harvest in good market conditions.
    /// @return processed_ An array containing addresses and amounts of harvested tokens (i.e. tokens that have finally
    ///                    been swapped into).
    function processRewards() external onlyOwnerOrManager returns (TokenAmount[] memory processed_) {
        processed_ = _processRewards();
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Keeper
    ////////////////////////////////////////////////////////////////////////////

    /// @notice A function to process pending CRV, CVX & FXS rewards at regular intervals. Can only be called by the
    ///         keeper when the contract is not paused.
    /// @param _performData The calldata to be passed to the upkeep function. Not used!
    function performUpkeep(bytes calldata _performData) external override onlyKeeper whenNotPaused {
        _processRewardsKeeper();
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL
    ////////////////////////////////////////////////////////////////////////////

    function _createPrivateVault(uint256 _pid) internal {
        (,, address stakingTokenAddr,, uint8 active) = CONVEX_FRAX_REGISTRY.poolInfo(_pid);
        if (active == 0) {
            revert PoolDeactivated(_pid);
        }

        address vaultAddr = FRAX_BOOSTER.createVault(_pid);
        IERC20MetadataUpgradeable(stakingTokenAddr).safeApprove(vaultAddr, type(uint256).max);

        // NOTE: we should store the `vaultAddr` on storage for ease of deposits/wds/reward claims
        privateVaults[_pid] = vaultAddr;
        pidsPrivateVaults.add(_pid);
    }

    /// @notice Unstakes the given amount of assets and transfers them back to owner.
    /// @dev This function doesn't claim any rewards. Caller can only be owner.
    /// @param _pids Pids to be targetted to unstake from.
    /// @param _bptsDeposited Amount of assets to be unstaked.
    function _withdraw(uint256[] memory _pids, uint256[] memory _bptsDeposited) internal {
        for (uint256 i = 0; i < _pids.length; i++) {
            if (_bptsDeposited[i] == 0) {
                revert NothingToWithdraw();
            }
            (address lpToken,,, address crvRewards,,) = CONVEX_BOOSTER.poolInfo(_pids[i]);

            IBaseRewardPool(crvRewards).withdrawAndUnwrap(_bptsDeposited[i], false);
            IERC20MetadataUpgradeable(lpToken).safeTransfer(msg.sender, _bptsDeposited[i]);

            emit Withdraw(lpToken, _bptsDeposited[i], block.timestamp);
        }
    }

    /// @notice A function to process pending CRV, CVX & FXS rewards at regular intervals.
    function _processRewardsKeeper() internal {
        uint256 lastClaimTimestampCached = lastClaimTimestamp;
        uint256 claimFrequencyCached = claimFrequency;
        if ((block.timestamp - lastClaimTimestampCached) < claimFrequencyCached) {
            revert TooSoon(block.timestamp, lastClaimTimestampCached, claimFrequencyCached);
        }

        _processRewards();
    }

    function _processRewards() internal returns (TokenAmount[] memory processed_) {
        // 1. Claim CVX, CRV & FXS rewards
        (uint256 totalCrv, uint256 totalCvx, uint256 totalFxs) = claimAndRegisterRewards();

        // 2. Swap all rewards for DAI
        // NOTE: assume that always will be crv & cvx to convert to stables, while fxs depends on private vaults
        uint256 totalDaiEarned;

        swapCrvForWeth(totalCrv);
        swapCvxForWeth(totalCvx);
        totalDaiEarned = swapWethForDai();

        if (totalFxs > 0) {
            // NOTE: swapping to DAI given treasury decision
            totalDaiEarned += swapFxsForDai(totalFxs);
        }

        // Return processed amount
        processed_ = new TokenAmount[](1);
        processed_[0] = TokenAmount(address(DAI), totalDaiEarned);

        emit RewardsToStable(address(DAI), totalDaiEarned, block.timestamp);
    }

    function claimAndRegisterRewards() internal returns (uint256 totalCrv_, uint256 totalCvx_, uint256 totalFxs_) {
        // Update last claimed time
        lastClaimTimestamp = block.timestamp;

        uint256 length = baseRewardPools.length();
        for (uint256 i = 0; i < length;) {
            IBaseRewardPool baseRewardPool = IBaseRewardPool(baseRewardPools.at(i));
            if (baseRewardPool.earned(address(this)) > 0) {
                baseRewardPool.getReward();
            }
            unchecked {
                ++i;
            }
        }

        length = pidsPrivateVaults.length();
        for (uint256 i = 0; i < length;) {
            address vaultAddr = privateVaults[pidsPrivateVaults.at(i)];
            IStakingProxy proxy = IStakingProxy(vaultAddr);
            (, uint256[] memory totalEarned) = proxy.earned();
            /// NOTE: assume as long at zero index rewards > 0, any other index could be as well
            if (totalEarned[0] > 0) {
                proxy.getReward();
            }
            unchecked {
                ++i;
            }
        }

        totalCrv_ = CRV.balanceOf(address(this));
        totalCvx_ = CVX.balanceOf(address(this));
        totalFxs_ = FXS.balanceOf(address(this));

        if (totalCrv_ == 0) {
            revert NoRewards();
        }

        // Emit events for analysis
        emit RewardClaimed(address(CRV), totalCrv_, block.timestamp);
        emit RewardClaimed(address(CVX), totalCvx_, block.timestamp);
        emit RewardClaimed(address(FXS), totalFxs_, block.timestamp);
    }

    function swapCrvForWeth(uint256 _crvAmount) internal {
        // Swap CRV -> WETH
        CRV_ETH_CURVE_POOL.exchange(
            1, 0, _crvAmount, (getCrvAmountInEth(_crvAmount) * minOutBpsCrvToWeth.val) / MAX_BPS
        );
    }

    function swapCvxForWeth(uint256 _cvxAmount) internal {
        // Swap CVX -> WETH
        CVX_ETH_CURVE_POOL.exchange(
            1, 0, _cvxAmount, (getCvxAmountInEth(_cvxAmount) * minOutBpsCrvToWeth.val) / MAX_BPS
        );
    }

    function swapWethForDai() internal returns (uint256 daiEarned_) {
        // Swap WETH -> DAI
        uint256 wethBalance = WETH.balanceOf(address(this));
        daiEarned_ = UNIV3_ROUTER.exactInputSingle(
            IUniswapRouterV3.ExactInputSingleParams({
                tokenIn: address(WETH),
                tokenOut: address(DAI),
                fee: uint24(500),
                recipient: owner(),
                deadline: type(uint256).max,
                amountIn: wethBalance,
                amountOutMinimum: (getWethAmountInDai(wethBalance) * minOutBpsWethToUsdc.val) / MAX_BPS,
                sqrtPriceLimitX96: 0 // Inactive param
            })
        );
    }

    function swapFxsForDai(uint256 _fxsAmount) internal returns (uint256 daiEarned_) {
        address[] memory path = new address[](2);
        path[0] = address(FXS);
        path[1] = address(FRAX);
        // 1. Swap FXS -> FRAX
        uint256[] memory amounts = FRAXSWAP_ROUTER.swapExactTokensForTokens(
            _fxsAmount,
            (getFxsAmountInFrax(_fxsAmount) * minOutBpsFxsToFrax.val) / MAX_BPS,
            path,
            address(this),
            block.timestamp
        );
        uint256 fraxBal = amounts[amounts.length - 1];
        // 2. Swap FRAX -> DAI
        daiEarned_ = FRAX_3CRV_CURVE_POOL.exchange_underlying(
            0, 1, fraxBal, (getFraxAmountInDai(fraxBal) * minOutBpsFraxToDai.val) / MAX_BPS, owner()
        );
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC VIEW
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Checks whether an upkeep is to be performed.
    /// @dev The calldata is encoded with the `processRewardsKeeper` selector. This selector is ignored when
    ///      performing upkeeps using the `performUpkeep` function.
    /// @return upkeepNeeded_ A boolean indicating whether an upkeep is to be performed.
    /// @return performData_ The calldata to be passed to the upkeep function.
    function checkUpkeep(bytes calldata) external override returns (bool upkeepNeeded_, bytes memory performData_) {
        uint256 crvPending;
        uint256 fxsPending;
        uint256 length = baseRewardPools.length();

        for (uint256 i = 0; i < length;) {
            crvPending += IBaseRewardPool(baseRewardPools.at(i)).earned(address(this));
            unchecked {
                ++i;
            }
        }

        length = pidsPrivateVaults.length();
        for (uint256 i; i < length;) {
            address vaultAddr = privateVaults[pidsPrivateVaults.at(i)];
            IStakingProxy proxy = IStakingProxy(vaultAddr);
            (address[] memory tokenAddresses, uint256[] memory totalEarned) = proxy.earned();
            for (uint256 j; j < tokenAddresses.length;) {
                if (tokenAddresses[j] == address(CRV)) {
                    crvPending += totalEarned[j];
                }
                if (tokenAddresses[j] == address(FXS)) {
                    fxsPending += totalEarned[j];
                }
                unchecked {
                    ++j;
                }
            }
            unchecked {
                ++i;
            }
        }

        uint256 crvBalance = CRV.balanceOf(address(this));
        uint256 fxsBalance = FXS.balanceOf(address(this));

        if ((block.timestamp - lastClaimTimestamp) >= claimFrequency) {
            if (crvPending > 0 || crvBalance > 0 || fxsPending > 0 || fxsBalance > 0) {
                upkeepNeeded_ = true;
            }
        }
    }

    /// @dev Returns all pids values
    function getPids() public view returns (uint256[] memory) {
        return pids.values();
    }

    /// @dev Returns all assets addresses
    function getAssets() public view returns (address[] memory) {
        return assets.values();
    }

    /// @dev Returns all rewards pool addresses
    function getbaseRewardPools() public view returns (address[] memory) {
        return baseRewardPools.values();
    }
}
