// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EnumerableSet} from "../../lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Pausable} from "../../lib/openzeppelin-contracts/contracts/security/Pausable.sol";

import {MAX_BPS} from "../BaseConstants.sol";
import {UpKeepManagerUtils} from "./UpKeepManagerUtils.sol";

import {IAggregatorV3} from "../interfaces/chainlink/IAggregatorV3.sol";
import {KeeperCompatibleInterface} from "../interfaces/chainlink/KeeperCompatibleInterface.sol";
import {IKeeperRegistry} from "../interfaces/chainlink/IKeeperRegistry.sol";
import {IKeeperRegistrar} from "../interfaces/chainlink/IKeeperRegistrar.sol";
import {IUniswapRouterV3} from "../interfaces/uniswap/IUniswapRouterV3.sol";

/// @title   UpKeepManager
/// @author  Petrovska @ BadgerDAO
/// @dev  Allows the `UpKeepManager` to register new contracts via governance and top-up under funded
/// upkeeps via CL keepers
contract UpKeepManager is UpKeepManagerUtils, Pausable, KeeperCompatibleInterface {
    ////////////////////////////////////////////////////////////////////////////
    // LIBRARIES
    ////////////////////////////////////////////////////////////////////////////

    using EnumerableSet for EnumerableSet.AddressSet;

    ////////////////////////////////////////////////////////////////////////////
    // STRUCT
    ////////////////////////////////////////////////////////////////////////////

    struct MemberInfo {
        string name;
        uint256 gasLimit;
        uint256 upKeepId;
    }

    ////////////////////////////////////////////////////////////////////////////
    // CONSTANTS
    ////////////////////////////////////////////////////////////////////////////

    string public constant NAME = "BadgerDAO UpKeep Manager";

    ////////////////////////////////////////////////////////////////////////////
    // IMMUTABLES
    ////////////////////////////////////////////////////////////////////////////

    address public immutable governance;

    ////////////////////////////////////////////////////////////////////////////
    // STORAGE
    ////////////////////////////////////////////////////////////////////////////

    uint256 public monitoringUpKeepId;

    uint256 public roundsTopUp;
    uint256 public minRoundsTopUp;

    /// @dev set helper for ease of iterating thru members
    EnumerableSet.AddressSet internal _members;
    mapping(address => MemberInfo) public membersInfo;

    ////////////////////////////////////////////////////////////////////////////
    // ERRORS
    ////////////////////////////////////////////////////////////////////////////

    error NotGovernance(address caller);
    error NotKeeper(address caller);

    error NotAutoApproveKeeper();
    error NotUnderFundedUpkeep(uint256 upKeepId);
    error NotMinLinkFundedUpKeep();
    error UpKeepNotCancelled(uint256 upKeepId);

    error NotMemberIncluded(address member);
    error MemberAlreadyRegister(address member);
    error MemberNotRegisteredYet(address member);

    error ZeroAddress();
    error ZeroUintValue();
    error EmptyString();

    ////////////////////////////////////////////////////////////////////////////
    // EVENTS
    ////////////////////////////////////////////////////////////////////////////

    event NewMember(address indexed memberAddress, string name, uint256 gasLimit, uint256 timestamp);
    event RemoveMember(address indexed memberAddress, uint256 upKeepId, uint256 timestamp);

    event RoundsTopUpUpdated(uint256 oldValue, uint256 newValue);
    event MinRoundsTopUpUpdated(uint256 oldValue, uint256 newValue);

    event SweepLinkToTechops(uint256 amount, uint256 timestamp);
    event SweepEth(address recipient, uint256 amount, uint256 timestamp);
    event EthSwappedForLink(uint256 amountEthOut, uint256 amountLinkIn, uint256 timestamp);

    event RegistryEthReceived(address indexed sender, uint256 value);

    constructor(address _governance) {
        if (_governance == address(0)) {
            revert ZeroAddress();
        }
        governance = _governance;

        roundsTopUp = 20;
        minRoundsTopUp = 3;
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

    /// @dev It will initiate the upKeep job for monitoring members
    /// @notice only callable via governance
    /// @param gasLimit gas limit for the upKeepManager monitoring upkeep task
    function initializeBaseUpkeep(uint256 gasLimit) external onlyGovernance {
        if (gasLimit == 0) {
            revert ZeroUintValue();
        }

        monitoringUpKeepId = _registerUpKeep(address(this), gasLimit, NAME);

        if (monitoringUpKeepId > 0) {
            /// @dev give allowance of spending LINK funds
            LINK.approve(address(CL_REGISTRY), type(uint256).max);
        }
    }

    /// @dev Adds an member into the manager
    /// @notice only callable via governance
    /// @param memberAddress contract address to be register as new member
    /// @param name member's name
    /// @param gasLimit amount of gas to provide the target contract when
    /// performing upkeep
    function addMember(address memberAddress, string memory name, uint256 gasLimit) external onlyGovernance {
        /// @dev sanity checks before adding a new member in storage
        if (memberAddress == address(0)) {
            revert ZeroAddress();
        }
        if (membersInfo[memberAddress].gasLimit != 0) {
            revert MemberAlreadyRegister(memberAddress);
        }
        if (gasLimit == 0) {
            revert ZeroUintValue();
        }
        if (bytes(name).length == 0) {
            revert EmptyString();
        }

        _members.add(memberAddress);
        membersInfo[memberAddress] =
            MemberInfo({name: name, gasLimit: gasLimit, upKeepId: _registerUpKeep(memberAddress, gasLimit, name)});

        emit NewMember(memberAddress, name, gasLimit, block.timestamp);
    }

    /// @dev Cancels an member's upkeep job
    /// @notice only callable via governance
    /// @param memberAddress contract address to be cancel upkeep
    function cancelMemberUpKeep(address memberAddress) external onlyGovernance {
        if (!_members.contains(memberAddress)) {
            revert NotMemberIncluded(memberAddress);
        }
        // NOTE: only member which upkeep is being cancelled can be removed
        uint256 upKeepId = membersInfo[memberAddress].upKeepId;
        CL_REGISTRY.cancelUpkeep(upKeepId);
    }

    /// @dev Withdraws LINK funds and remove member from manager
    /// @notice only callable via governance
    /// @param memberAddress contract address to be remove from manager
    function withdrawLinkFundsAndRemoveMember(address memberAddress) external onlyGovernance {
        if (!_members.contains(memberAddress)) {
            revert NotMemberIncluded(memberAddress);
        }

        uint256 upKeepId = membersInfo[memberAddress].upKeepId;
        // NOTE: only member which upkeep is being cancelled can be removed
        (,,,,,, uint64 maxValidBlocknumber,) = CL_REGISTRY.getUpkeep(upKeepId);
        // https://etherscan.io/address/0x02777053d6764996e594c3e88af1d58d5363a2e6#code#F1#L738
        if (maxValidBlocknumber == type(uint64).max) {
            revert UpKeepNotCancelled(upKeepId);
        }

        // NOTE: removal actions after on-chain checkups
        _members.remove(memberAddress);
        delete membersInfo[memberAddress];

        CL_REGISTRY.withdrawFunds(upKeepId, address(this));

        emit RemoveMember(memberAddress, upKeepId, block.timestamp);
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
        emit SweepEth(recipient, ethBal, block.timestamp);
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
    // PUBLIC: Governance - Config
    ////////////////////////////////////////////////////////////////////////////

    /// @notice Updates the value of `roundsTopUp`, which is used for decided how much rounds will
    ///         will be covered at least while topping-up
    /// @param _roundsTopUp new value for `roundsTopUp`
    function setRoundsTopUp(uint256 _roundsTopUp) external onlyGovernance {
        uint256 oldRoundsTopUp = minRoundsTopUp;
        roundsTopUp = _roundsTopUp;
        emit RoundsTopUpUpdated(oldRoundsTopUp, _roundsTopUp);
    }

    /// @notice Updates the value of `minRoundsTopUp`, which is used to decide if `upKeepId` is underfunded
    /// @param _minRoundsTopUp new value for `minRoundsTopUp`
    function setMinRoundsTopUp(uint256 _minRoundsTopUp) external onlyGovernance {
        uint256 oldMinRoundsTopUp = minRoundsTopUp;
        minRoundsTopUp = _minRoundsTopUp;
        emit RoundsTopUpUpdated(oldMinRoundsTopUp, _minRoundsTopUp);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Keeper
    ////////////////////////////////////////////////////////////////////////////

    /// @dev Contains the logic that should be executed on-chain when
    /// `checkUpkeep` returns true.
    function performUpkeep(bytes calldata _performData) external override onlyKeeper whenNotPaused {
        uint256 upKeepId = _validatePerformData(_performData);

        _topupUpkeep(upKeepId);
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

    /// @dev decodes the `bytes` calldata given by keepers and checks its validate against storage
    /// @param _performData ABI-encoded member address to validate
    function _validatePerformData(bytes calldata _performData) internal view returns (uint256 upKeepId_) {
        address member = abi.decode(_performData, (address));

        if (member == address(this)) {
            upKeepId_ = monitoringUpKeepId;
        } else {
            upKeepId_ = membersInfo[member].upKeepId;
        }

        if (upKeepId_ == 0) {
            revert MemberNotRegisteredYet(member);
        }
    }

    /// @dev checks if upKeepId is under-funded, helper in `checkUpKeep`
    /// and `performUpKeep` methods
    /// @param _upKeepId task id to verify is underfunded
    function _isUpKeepIdUnderFunded(uint256 _upKeepId)
        internal
        view
        returns (uint96 minUpKeepBal_, bool underFunded_)
    {
        /// @dev check onchain the min and current amounts to consider top-up
        minUpKeepBal_ = CL_REGISTRY.getMinBalanceForUpkeep(_upKeepId);
        (,,, uint96 currentUpKeepBal,,,,) = CL_REGISTRY.getUpkeep(_upKeepId);

        if (currentUpKeepBal <= minUpKeepBal_ * minRoundsTopUp) {
            underFunded_ = true;
        }
    }

    /// @dev carries over the top-up action of an member upKeep
    /// @param _upKeepId id to verify if it is underfunded
    function _topupUpkeep(uint256 _upKeepId) internal {
        (uint96 minUpKeepBal, bool underFunded) = _isUpKeepIdUnderFunded(_upKeepId);

        if (!underFunded) {
            revert NotUnderFundedUpkeep(_upKeepId);
        }

        uint96 topupAmount = minUpKeepBal * uint96(roundsTopUp);

        uint256 linkRegistryBal = LINK.balanceOf(address(this));
        if (linkRegistryBal < topupAmount) {
            _swapEthForLink(topupAmount - linkRegistryBal);
        }

        CL_REGISTRY.addFunds(_upKeepId, topupAmount);
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
        uint256 linkAmount = _getLinkAmount(gasLimit) * roundsTopUp;
        if (linkAmount < MIN_FUNDING_UPKEEP) {
            revert NotMinLinkFundedUpKeep();
        }
        uint256 linkRegistryBal = LINK.balanceOf(address(this));
        if (linkRegistryBal < linkAmount) {
            _swapEthForLink(linkAmount - linkRegistryBal);
        }

        /// @dev checks CL registry state before registering
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
        address[] memory members = getMembers();
        bool underFunded;

        uint256 membersLength = members.length;
        if (membersLength > 0) {
            // NOTE: loop thru members to see which is underfunded
            for (uint256 i; i < membersLength; i++) {
                (, underFunded) = _isUpKeepIdUnderFunded(membersInfo[members[i]].upKeepId);
                if (underFunded) {
                    upkeepNeeded_ = true;
                    performData_ = abi.encode(members[i]);
                    break;
                }
            }
        }

        // NOTE: to avoid overwritten an `upKeep` meant for registration, check boolean
        if (!upkeepNeeded_) {
            /// @dev check for the UpKeepManager itself if its upkeep needs topup
            (, underFunded) = _isUpKeepIdUnderFunded(monitoringUpKeepId);
            if (underFunded) {
                upkeepNeeded_ = true;
                performData_ = abi.encode(address(this));
            }
        }
    }

    /// @dev Returns all member addresses
    function getMembers() public view returns (address[] memory) {
        return _members.values();
    }
}
