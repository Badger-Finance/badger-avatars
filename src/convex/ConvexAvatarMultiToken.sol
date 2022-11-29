// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PausableUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/security/PausableUpgradeable.sol";
import {SafeERC20Upgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {IERC20MetadataUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import {EnumerableSetUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/structs/EnumerableSetUpgradeable.sol";

import {IUniswapRouterV3} from "../interfaces/uniswap/IUniswapRouterV3.sol";

import {BaseAvatar} from "../lib/BaseAvatar.sol";
import {MAX_BPS} from "../BaseConstants.sol";
import {BpsConfig, TokenAmount} from "../BaseStructs.sol";
import {ConvexAvatarUtils} from "./ConvexAvatarUtils.sol";
import {IBaseRewardPool} from "../interfaces/aura/IBaseRewardPool.sol";

/// @title ConvexAvatarMultiToken
contract ConvexAvatarMultiToken is
    BaseAvatar,
    ConvexAvatarUtils,
    PausableUpgradeable
{
    ////////////////////////////////////////////////////////////////////////////
    // LIBRARIES
    ////////////////////////////////////////////////////////////////////////////

    using SafeERC20Upgradeable for IERC20MetadataUpgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    /// @notice Address of the staking rewards contracts
    EnumerableSetUpgradeable.AddressSet internal baseRewardPools;

    /// @notice The frequency (in seconds) at which the keeper should harvest rewards.
    uint256 public claimFrequency;

    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for a CRV to USDC swap.
    BpsConfig public minOutBpsCrvToUsdc;
    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for an CVX to USDC swap.
    BpsConfig public minOutBpsCvxToUsdc;
    /// @notice The current and minimum value (in bps) controlling the minimum executable price (as proprtion of oracle
    ///         price) for an FXS to USDC swap.
    BpsConfig public minOutBpsFxsToUsdc;

    /// @notice The timestamp at which rewards were last claimed and harvested.
    uint256 public lastClaimTimestamp;

    ////////////////////////////////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////////////////////////////////

    error NoRewards();

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

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
    event AvatarEthReceived(address indexed sender, uint256 value);

    function initialize(address _owner) public initializer {
        __BaseAvatar_init(_owner);
        __Pausable_init();

        claimFrequency = 1 weeks;

        minOutBpsCrvToUsdc = BpsConfig({
            val: 9850, // 98.5%
            min: 9500 // 95%
        });
        minOutBpsCvxToUsdc = BpsConfig({
            val: 9850, // 98.5%
            min: 9500 // 95%
        });
        minOutBpsFxsToUsdc = BpsConfig({
            val: 9850, // 98.5%
            min: 9500 // 95%
        });

        // aproval for curve pools: crv & cvx
        CRV.safeApprove(address(CRV_ETH_CURVE_POOL), type(uint256).max);
        CVX.safeApprove(address(CVX_ETH_CURVE_POOL), type(uint256).max);

        // approvals for fraxswap route: fxs
        FXS.safeApprove(address(FRAXSWAP_ROUTER), type(uint256).max);
    }

    /// @dev Fallback function accepts Ether transactions.
    receive() external payable {
        emit AvatarEthReceived(msg.sender, msg.value);
    }

    function _processRewards()
        internal
        returns (TokenAmount[] memory processed_)
    {
        address ownerCached = owner();
        // 1. Claim CVX, CRV & FXS rewards
        (
            uint256 totalCrv,
            uint256 totalCvx,
            uint256 totalFxs
        ) = claimAndRegisterRewards();

        // 2. Swap all rewards for USDC
        // NOTE: assume that always will be crv & cvx to convert to stables, while fxs depends on private vaults
        uint256 totalUsdcEarned;
        uint256 totalFraxEarned;

        totalUsdcEarned += swapCrvForUsdc(totalCrv);
        totalUsdcEarned += swapCvxForUsdc(totalCvx);
        if (totalFxs > 0) {
            // NOTE: only one hop, avoiding another swap tx form FRAX to USDC
            totalFraxEarned = swapFxsForUsdc(totalFxs);
            FRAX.safeTransfer(ownerCached, totalFraxEarned);
        }

        // 3. Send USDC received to owner
        USDC.safeTransfer(ownerCached, totalUsdcEarned);

        // Return processed amount
        processed_ = new TokenAmount[](2);
        processed_[0] = TokenAmount(address(USDC), totalUsdcEarned);
        processed_[0] = TokenAmount(address(FRAX), totalFraxEarned);

        emit RewardsToStable(address(USDC), totalUsdcEarned, block.timestamp);
        emit RewardsToStable(address(FRAX), totalFraxEarned, block.timestamp);
    }

    function claimAndRegisterRewards()
        internal
        returns (
            uint256 totalCrv_,
            uint256 totalCvx_,
            uint256 totalFxs_
        )
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

    function swapCrvForUsdc(uint256 _crvAmount)
        internal
        returns (uint256 usdcEarned_)
    {
        uint256 minUsdcExpected = (getCrvAmountInUsdc(_crvAmount) *
            minOutBpsCrvToUsdc.val) / MAX_BPS;
        // 1. Swap crv -> eth
        CRV_ETH_CURVE_POOL.exchange_underlying(
            1,
            0,
            _crvAmount,
            (getCrvAmountInEth(_crvAmount) * minOutBpsCrvToUsdc.val) / MAX_BPS
        );

        // 2. Swap eth -> usdc
        uint256 ethBal = address(this).balance;
        IUniswapRouterV3.ExactInputParams memory params = IUniswapRouterV3
            .ExactInputParams({
                path: abi.encodePacked(WETH, uint24(500), address(USDC)),
                recipient: address(this),
                amountIn: ethBal,
                amountOutMinimum: minUsdcExpected
            });
        usdcEarned_ = UNIV3_ROUTER.exactInput{value: ethBal}(params);
        // NOTE: conservative approach given https://hackmd.io/@0x534154/Hy6_66gT5
        UNIV3_ROUTER.refundETH();
    }

    function swapCvxForUsdc(uint256 _cvxAmount)
        internal
        returns (uint256 usdcEarned_)
    {
        uint256 minUsdcExpected = (getCvxAmountInUsdc(_cvxAmount) *
            minOutBpsCvxToUsdc.val) / MAX_BPS;
        // 1. Swap cvx -> eth
        CVX_ETH_CURVE_POOL.exchange_underlying(
            1,
            0,
            _cvxAmount,
            (getCvxAmountInEth(_cvxAmount) * minOutBpsCrvToUsdc.val) / MAX_BPS
        );

        // 2. Swap cvx -> usdc
        uint256 ethBal = address(this).balance;
        IUniswapRouterV3.ExactInputParams memory params = IUniswapRouterV3
            .ExactInputParams({
                path: abi.encodePacked(WETH, uint24(500), address(USDC)),
                recipient: address(this),
                amountIn: ethBal,
                amountOutMinimum: minUsdcExpected
            });
        usdcEarned_ = UNIV3_ROUTER.exactInput{value: ethBal}(params);
        // NOTE: conservative approach given https://hackmd.io/@0x534154/Hy6_66gT5
        UNIV3_ROUTER.refundETH();
    }

    function swapFxsForUsdc(uint256 _fxsAmount)
        internal
        returns (uint256 fraxEarned_)
    {
        address[] memory path = new address[](2);
        path[1] = address(FXS);
        path[2] = address(FRAX);
        // 1. Swap fxs -> frax
        uint256[] memory amounts = FRAXSWAP_ROUTER.swapExactTokensForTokens(
            _fxsAmount,
            (getFxsAmountInUsdc(_fxsAmount) * minOutBpsFxsToUsdc.val) / MAX_BPS,
            path,
            address(this),
            block.timestamp
        );
        fraxEarned_ = amounts[amounts.length - 1];
    }
}
