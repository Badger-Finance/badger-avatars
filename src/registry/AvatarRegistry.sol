// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/security/Pausable.sol";

import {MAX_BPS} from "../BaseConstants.sol";
import {AvatarRegistryUtils} from "./AvatarRegistryUtils.sol";

import {IAvatar} from "../interfaces/badger/IAvatar.sol";
import {IAggregatorV3} from "../interfaces/chainlink/IAggregatorV3.sol";
import {KeeperCompatibleInterface} from "../interfaces/chainlink/KeeperCompatibleInterface.sol";
import {IKeeperRegistry} from "../interfaces/chainlink/IKeeperRegistry.sol";
import {IKeeperRegistrar} from "../interfaces/chainlink/IKeeperRegistrar.sol";
import {IUniswapRouterV3} from "../interfaces/uniswap/IUniswapRouterV3.sol";

/// @title   AvatarRegistry
/// @author  Petrovska @ BadgerDAO
/// @dev  Allows the registry to register new avatars and top-up under funded
/// upkeeps via CL
contract AvatarRegistry is AvatarRegistryUtils, Pausable, KeeperCompatibleInterface {
    ////////////////////////////////////////////////////////////////////////////
    // LIBRARIES
    ////////////////////////////////////////////////////////////////////////////

    using EnumerableSet for EnumerableSet.AddressSet;

    ////////////////////////////////////////////////////////////////////////////
    // STRUCT & ENUMS
    ////////////////////////////////////////////////////////////////////////////

    enum AvatarStatus {
        DEPRECATED,
        TESTING,
        SEEDED,
        FULLY_FUNDED
    }

    struct AvatarInfo {
        string name;
        uint256 gasLimit;
        AvatarStatus status;
        uint256 upKeepId;
    }

    ////////////////////////////////////////////////////////////////////////////
    // CONSTANTS
    ////////////////////////////////////////////////////////////////////////////

    string public constant AVATAR_REGISTRY_NAME = "BadgerDAO Avatar Registry";

    ////////////////////////////////////////////////////////////////////////////
    // IMMUTABLES
    ////////////////////////////////////////////////////////////////////////////

    address public immutable governance;

    ////////////////////////////////////////////////////////////////////////////
    // STORAGE
    ////////////////////////////////////////////////////////////////////////////

    uint256 public avatarMonitoringUpKeepId;

    /// @dev set helper for ease of iterating thru avatars
    EnumerableSet.AddressSet internal _avatars;
    mapping(address => AvatarInfo) public avatarsInfo;

    ////////////////////////////////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////////////////////////////////

    error NotGovernance(address caller);
    error NotKeeper(address caller);

    error NotAutoApproveKeeper();
    error NotUnderFundedUpkeep(uint256 upKeepId);
    error NotCLKeeperSet();
    error NotMinLinkFundedUpKeep();
    error UpKeepNotCancelled(uint256 upKeepId);

    error NotAvatarIncluded(address avatar);
    error AvatarAlreadyRegister(address avatar);
    error AvatarNotRegisteredYet(address avatar);
    error UpdateSameStatus();

    error ZeroAddress();
    error ZeroUintValue();
    error EmptyString();

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

    event NewAvatar(address indexed avatarAddress, string name, uint256 gasLimit, uint256 timestamp);
    event RemoveAvatar(address indexed avatarAddress, uint256 upKeepId, uint256 timestamp);

    event UpdateAvatarStatus(
        address indexed avatarAddress, AvatarStatus oldStatus, AvatarStatus newStatus, uint256 timestamp
    );

    event SweepLinkToTechops(uint256 amount, uint256 timestamp);
    event SweepEth(address recipient, uint256 amount);
    event EthSwappedForLink(uint256 amountEthOut, uint256 amountLinkIn, uint256 timestamp);

    event RegistryEthReceived(address indexed sender, uint256 value);

    constructor(address _governance) {
        if (_governance == address(0)) {
            revert ZeroAddress();
        }
        governance = _governance;
    }

    ////////////////////////////////////////////////////////////////////////////
    // MODIFIERS
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Checks whether a call is from the governance.
    modifier onlyGovernance() {
        if (msg.sender != governance) {
            revert NotGovernance(msg.sender);
        }
        _;
    }

    /// @notice Checks whether a call is from the keeper.
    modifier onlyKeeper() {
        if (msg.sender != address(CL_REGISTRY)) {
            revert NotKeeper(msg.sender);
        }
        _;
    }

    /// @dev Fallback function accepts Ether transactions.
    receive() external payable {
        emit RegistryEthReceived(msg.sender, msg.value);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Governance
    ////////////////////////////////////////////////////////////////////////////

    /// @dev It will initiate the upKeep job for monitoring avatars
    /// @notice only callable via governance
    /// @param gasLimit gas limit for the avatar monitoring upkeep task
    function initializeBaseUpkeep(uint256 gasLimit) external onlyGovernance {
        if (gasLimit == 0) {
            revert ZeroUintValue();
        }

        avatarMonitoringUpKeepId = _registerUpKeep(address(this), gasLimit, AVATAR_REGISTRY_NAME);

        if (avatarMonitoringUpKeepId > 0) {
            /// @dev give allowance of spending LINK funds
            LINK.approve(address(CL_REGISTRY), type(uint256).max);
        }
    }

    /// @dev Adds an avatar into the registry
    /// @notice only callable via governance
    /// @param avatarAddress contract address to be register as new avatar
    /// @param name avatar's name
    /// @param gasLimit amount of gas to provide the target contract when
    /// performing upkeep
    function addAvatar(address avatarAddress, string memory name, uint256 gasLimit) external onlyGovernance {
        /// @dev sanity checks before adding a new avatar in storage
        if (avatarAddress == address(0)) {
            revert ZeroAddress();
        }
        if (avatarsInfo[avatarAddress].gasLimit != 0) {
            revert AvatarAlreadyRegister(avatarAddress);
        }
        if (gasLimit == 0) {
            revert ZeroUintValue();
        }
        if (bytes(name).length == 0) {
            revert EmptyString();
        }
        if (IAvatar(avatarAddress).keeper() != address(CL_REGISTRY)) {
            revert NotCLKeeperSet();
        }

        _avatars.add(avatarAddress);
        avatarsInfo[avatarAddress] = AvatarInfo({
            name: name,
            gasLimit: gasLimit,
            status: AvatarStatus.TESTING,
            upKeepId: _registerUpKeep(avatarAddress, gasLimit, name)
        });

        emit NewAvatar(avatarAddress, name, gasLimit, block.timestamp);
    }

    /// @dev Cancels an avatar upkeep job
    /// @notice only callable via governance
    /// @param avatarAddress contract address to be cancel upkeep
    function cancelAvatarUpKeep(address avatarAddress) external onlyGovernance {
        if (!_avatars.contains(avatarAddress)) {
            revert NotAvatarIncluded(avatarAddress);
        }
        // NOTE: only avatar which upkeep is being cancelled can be removed
        uint256 upKeepId = avatarsInfo[avatarAddress].upKeepId;
        CL_REGISTRY.cancelUpkeep(upKeepId);
    }

    /// @dev Updates status of an avatar in the registry
    /// @notice only callable via governance
    /// @param avatarAddress contract address update status of
    /// @param newStatus latest status of the avatar
    function updateStatus(address avatarAddress, AvatarStatus newStatus) external onlyGovernance {
        if (!_avatars.contains(avatarAddress)) {
            revert NotAvatarIncluded(avatarAddress);
        }

        AvatarStatus oldStatus = avatarsInfo[avatarAddress].status;
        if (oldStatus == newStatus) {
            revert UpdateSameStatus();
        }

        avatarsInfo[avatarAddress].status = newStatus;

        emit UpdateAvatarStatus(avatarAddress, oldStatus, newStatus, block.timestamp);
    }

    /// @dev Withdraws LINK funds and remove avatar from registry
    /// @notice only callable via governance
    /// @param avatarAddress contract address to be remove from registry
    function withdrawLinkFundsAndRemoveAvatar(address avatarAddress) external onlyGovernance {
        if (!_avatars.contains(avatarAddress)) {
            revert NotAvatarIncluded(avatarAddress);
        }

        uint256 upKeepId = avatarsInfo[avatarAddress].upKeepId;
        // NOTE: only avatar which upkeep is being cancelled can be removed
        (,,,,,, uint64 maxValidBlocknumber,) = CL_REGISTRY.getUpkeep(upKeepId);
        // https://etherscan.io/address/0x02777053d6764996e594c3e88af1d58d5363a2e6#code#F1#L738
        if (maxValidBlocknumber == type(uint64).max) {
            revert UpKeepNotCancelled(upKeepId);
        }

        // NOTE: removal actions after on-chain checkups
        _avatars.remove(avatarAddress);
        delete avatarsInfo[avatarAddress];

        CL_REGISTRY.withdrawFunds(upKeepId, address(this));

        emit RemoveAvatar(avatarAddress, upKeepId, block.timestamp);
    }

    /// @dev  Sweep the full LINK balance to techops
    function sweepLinkFunds() external onlyGovernance {
        uint256 linkBal = LINK.balanceOf(address(this));
        LINK.transfer(TECHOPS, linkBal);
        emit SweepLinkToTechops(linkBal, block.timestamp);
    }

    /// @dev  Sweep the full ETH balance to recipient
    /// @param recipient Address receiving eth funds
    function sweepEthFunds(address payable recipient) external onlyGovernance {
        uint256 ethBal = address(this).balance;
        recipient.transfer(ethBal);
        emit SweepEth(recipient, ethBal);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Governance - Pausing
    ////////////////////////////////////////////////////////////////////////////

    /// @dev Pauses the contract, which prevents executing performUpkeep.
    function pause() external onlyGovernance {
        _pause();
    }

    /// @dev Unpauses the contract.
    function unpause() external onlyGovernance {
        _unpause();
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Keeper
    ////////////////////////////////////////////////////////////////////////////

    /// @dev Contains the logic that should be executed on-chain when
    /// `checkUpkeep` returns true.
    function performUpkeep(bytes calldata _performData) external override onlyKeeper whenNotPaused {
        address avatarTarget = abi.decode(_performData, (address));

        _topupUpkeep(avatarTarget);
    }

    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL
    ////////////////////////////////////////////////////////////////////////////

    /// @dev returns the fast gwei and price of link/eth from CL
    /// @return gasWei current fastest gas value in wei
    /// @return linkEth latest answer of feed of link/eth
    function _getFeedData() internal view returns (uint256 gasWei, uint256 linkEth) {
        /// @dev check as ref current fast wei gas
        gasWei = fetchPriceFromClFeed(FAST_GAS_FEED, CL_FEED_HEARTBEAT_GAS);

        /// @dev check latest oracle rate link/eth
        linkEth = fetchPriceFromClFeed(LINK_ETH_FEED, CL_FEED_HEARTBEAT_LINK);
    }

    /// @dev converts a gas limit value into link expressed amount
    /// @param gasLimit amount of gas to provide the target contract when
    /// performing upkeep
    /// @return linkAmount amount of LINK needed to cover the job
    function _getLinkAmount(uint256 gasLimit) internal view returns (uint256 linkAmount) {
        (, IKeeperRegistry.Config memory _c,) = CL_REGISTRY.getState();
        (uint256 fastGasWei, uint256 linkEth) = _getFeedData();

        uint256 adjustedGas = fastGasWei * _c.gasCeilingMultiplier;
        uint256 weiForGas = adjustedGas * (gasLimit + REGISTRY_GAS_OVERHEAD);
        uint256 premium = PPB_BASE + _c.paymentPremiumPPB;

        /// @dev amount of LINK to carry one `performUpKeep` operation
        // See: _calculatePaymentAmount
        // https://etherscan.io/address/0x02777053d6764996e594c3E88AF1D58D5363a2e6#code#F1#L776
        linkAmount =
        // From Wei to Eth * Premium / Ratio
         ((weiForGas * (1e9) * (premium)) / (linkEth)) + (uint256(_c.flatFeeMicroLink) * (1e12));
    }

    /// @dev checks if an avatar upKeepId is under-funded, helper in `checkUpKeep`
    /// and `performUpKeep` methods
    /// @param avatar contract address to verify if under-funded
    function _isAvatarUpKeepUnderFunded(address avatar)
        internal
        view
        returns (uint256 upKeepId, uint96 minUpKeepBal, bool underFunded)
    {
        if (avatar == address(this)) {
            upKeepId = avatarMonitoringUpKeepId;
        } else {
            upKeepId = avatarsInfo[avatar].upKeepId;
        }

        /// @dev check onchain the min and current amounts to consider top-up
        minUpKeepBal = CL_REGISTRY.getMinBalanceForUpkeep(upKeepId);
        (,,, uint96 currentUpKeepBal,,,,) = CL_REGISTRY.getUpkeep(upKeepId);

        if (currentUpKeepBal <= minUpKeepBal * MIN_ROUNDS_TOP_UP) {
            underFunded = true;
        }
    }

    /// @dev carries over the top-up action of an avatar upKeep
    /// @param avatar contract address to top-up its targetted upKeepId
    function _topupUpkeep(address avatar) internal {
        (uint256 upKeepId, uint96 minUpKeepBal, bool underFunded) = _isAvatarUpKeepUnderFunded(avatar);

        if (upKeepId == 0) {
            revert AvatarNotRegisteredYet(avatar);
        }
        if (!underFunded) {
            revert NotUnderFundedUpkeep(upKeepId);
        }

        uint96 topupAmount = minUpKeepBal * uint96(ROUNDS_TOP_UP);

        uint256 linkRegistryBal = LINK.balanceOf(address(this));
        if (linkRegistryBal < topupAmount) {
            _swapEthForLink(topupAmount - linkRegistryBal);
        }

        CL_REGISTRY.addFunds(upKeepId, topupAmount);
    }

    /// @dev executes the swap from ETH to LINK, for the amount of link required
    /// @param linkRequired amount of link required for handling the `performUpKeep` task
    function _swapEthForLink(uint256 linkRequired) internal {
        uint256 maxEth = (getLinkAmountInEth(linkRequired) * MAX_IN_BPS) / MAX_BPS;
        uint256 ethSpent = UNIV3_ROUTER.exactOutputSingle{value: maxEth}(
            IUniswapRouterV3.ExactOutputSingleParams({
                tokenIn: WETH,
                tokenOut: address(LINK),
                fee: uint24(3000),
                recipient: address(this),
                deadline: type(uint256).max,
                amountOut: linkRequired,
                amountInMaximum: maxEth,
                sqrtPriceLimitX96: 0 // Inactive param
            })
        );
        UNIV3_ROUTER.refundETH();
        emit EthSwappedForLink(ethSpent, linkRequired, block.timestamp);
    }

    /// @dev carries registration of target contract in CL
    /// @param targetAddress contract which will be register
    /// @param gasLimit amount of gas to provide the target contract when
    /// performing upkeep
    /// @param name detailed name for the upkeep job
    /// @return upkeepID id of cl job
    function _registerUpKeep(address targetAddress, uint256 gasLimit, string memory name)
        internal
        returns (uint256 upkeepID)
    {
        /// @dev we ensure we top-up enough LINK for couple of test-runs (20) and sanity checks
        uint256 linkAmount = _getLinkAmount(gasLimit) * ROUNDS_TOP_UP;
        if (linkAmount < MIN_FUNDING_UPKEEP) {
            revert NotMinLinkFundedUpKeep();
        }
        uint256 linkRegistryBal = LINK.balanceOf(address(this));
        if (linkRegistryBal < linkAmount) {
            _swapEthForLink(linkAmount - linkRegistryBal);
        }

        /// @dev check registry state before registering
        (IKeeperRegistry.State memory state,,) = CL_REGISTRY.getState();
        uint256 oldNonce = state.nonce;

        bytes memory data = abi.encodeCall(
            IKeeperRegistrar.register,
            (
                name,
                bytes(""),
                targetAddress,
                uint32(gasLimit),
                address(this),
                bytes(""),
                uint96(linkAmount),
                0,
                address(this)
            )
        );

        LINK.transferAndCall(KEEPER_REGISTRAR, linkAmount, data);

        (state,,) = CL_REGISTRY.getState();
        uint256 newNonce = state.nonce;

        if (newNonce == oldNonce + 1) {
            upkeepID = uint256(
                keccak256(abi.encodePacked(blockhash(block.number - 1), address(CL_REGISTRY), uint32(oldNonce)))
            );
        } else {
            revert NotAutoApproveKeeper();
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC VIEW
    ////////////////////////////////////////////////////////////////////////////

    /// @dev Runs off-chain at every block to determine if the `performUpkeep`
    /// function should be called on-chain.
    function checkUpkeep(bytes calldata)
        external
        view
        override
        whenNotPaused
        returns (bool upkeepNeeded_, bytes memory performData_)
    {
        address[] memory avatars = getAvatars();
        bool underFunded;

        uint256 avatarsLength = avatars.length;
        if (avatarsLength > 0) {
            /// @dev loop thru avatar in test status for register or topup if required
            for (uint256 i; i < avatarsLength; i++) {
                /// @dev requires that CL keeper is config properly
                if (IAvatar(avatars[i]).keeper() != address(CL_REGISTRY)) {
                    continue;
                }

                /// @dev check for under funded avatar upkeeps
                (,, underFunded) = _isAvatarUpKeepUnderFunded(avatars[i]);
                if (underFunded) {
                    upkeepNeeded_ = true;
                    performData_ = abi.encode(avatars[i]);
                    break;
                }
            }
        }

        // NOTE: to avoid overwritten an `upKeep` meant for registration, check boolean
        if (!upkeepNeeded_) {
            /// @dev check for the registry itself if its upkeep needs topup
            (,, underFunded) = _isAvatarUpKeepUnderFunded(address(this));
            if (underFunded) {
                upkeepNeeded_ = true;
                performData_ = abi.encode(address(this));
            }
        }
    }

    /// @dev Returns all avatar addresses
    function getAvatars() public view returns (address[] memory) {
        return _avatars.values();
    }

    /// @dev Returns all avatar addresses with matching status
    function getAvatarsByStatus(AvatarStatus status) public view returns (address[] memory) {
        uint256 length = _avatars.length();
        address[] memory avatarInTestStatusHelper = new address[](length);
        uint256 avatarStatusLength;

        for (uint256 i; i < length;) {
            address avatar = _avatars.at(i);
            if (avatarsInfo[avatar].status == status) {
                avatarInTestStatusHelper[avatarStatusLength] = avatar;
                unchecked {
                    ++avatarStatusLength;
                }
            }
            unchecked {
                ++i;
            }
        }

        if (avatarStatusLength != length) {
            // NOTE: truncate length
            assembly {
                mstore(avatarInTestStatusHelper, avatarStatusLength)
            }
        }

        return avatarInTestStatusHelper;
    }
}