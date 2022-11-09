// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EnumerableSetUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/structs/EnumerableSetUpgradeable.sol";
import {PausableUpgradeable} from "../../lib/openzeppelin-contracts-upgradeable/contracts/security/PausableUpgradeable.sol";

import {IAvatar} from "../interfaces/badger/IAvatar.sol";
import {IAggregatorV3} from "../interfaces/chainlink/IAggregatorV3.sol";
import {KeeperCompatibleInterface} from "../interfaces/chainlink/KeeperCompatibleInterface.sol";
import {IKeeperRegistry} from "../interfaces/chainlink/IKeeperRegistry.sol";
import {ILink} from "../interfaces/chainlink/ILink.sol";
import {IKeeperRegistrar} from "../interfaces/chainlink/IKeeperRegistrar.sol";

/// @title   AvatarRegistry
/// @author  Petrovska @ BadgerDAO
/// @dev  Allows the registry to register new avatars and top-up under funded
/// upkeeps via CL
contract AvatarRegistry is PausableUpgradeable, KeeperCompatibleInterface {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    /* ========== STRUCT & ENUMS ========== */
    enum OperationKeeperType {
        REGISTER_UPKEEP,
        TOPUP_UPKEEP
    }

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

    /* ========== CONSTANTS VARIABLES ========== */
    string public constant AVATAR_REGISTRY_NAME = "BadgerDAO Avatar Registry";
    address public constant KEEPER_REGISTRAR =
        0xDb8e8e2ccb5C033938736aa89Fe4fa1eDfD15a1d;
    address public constant KEEPER_REGISTRY =
        0x02777053d6764996e594c3E88AF1D58D5363a2e6;
    IKeeperRegistry public constant CL_REGISTRY =
        IKeeperRegistry(KEEPER_REGISTRY);
    address public constant ADMIN_KEEPERS =
        0x86cbD0ce0c087b482782c181dA8d191De18C8275;
    ILink public constant LINK =
        ILink(0x514910771AF9Ca656af840dff83E8264EcF986CA);
    uint256 internal constant CL_FEED_HEARTBEAT_GAS = 2 hours;
    IAggregatorV3 public constant FAST_GAS_FEED =
        IAggregatorV3(0x169E633A2D1E6c10dD91238Ba11c4A708dfEF37C);
    IAggregatorV3 public constant LINK_ETH_FEED =
        IAggregatorV3(0xDC530D9457755926550b59e8ECcdaE7624181557);
    uint256 internal constant CL_FEED_HEARTBEAT_LINK = 6 hours;
    uint256 internal constant ROUNDS_TOP_UP = 20;
    uint256 internal constant MIN_FUNDING_UPKEEP = 5 ether;
    uint256 internal constant REGISTRY_GAS_OVERHEAD = 80_000;
    uint256 internal constant PPB_BASE = 1_000_000_000;

    /* ========== STATE VARIABLES ========== */
    address public governance;
    uint256 public avatarMonitoringUpKeepId;

    /// @dev set helper for ease of iterating thru avatars
    EnumerableSetUpgradeable.AddressSet internal _avatars;
    mapping(address => AvatarInfo) public avatarsInfo;

    /***************************************
                    ERRORS
    ****************************************/
    error NotGovernance(address caller);
    error NotKeeper(address caller);

    error StalePriceFeed(
        address priceFeedAddress,
        uint256 currentTime,
        uint256 updateTime,
        uint256 maxPeriod
    );

    error NotAutoApproveKeeper();

    error NotUnderFundedUpkeep(uint256 upKeepId);

    /***************************************
                    MODIFIERS
    ****************************************/
    /// @notice Checks whether a call is from the governance.
    modifier onlyGovernance() {
        if (msg.sender != governance) {
            revert NotGovernance(msg.sender);
        }
        _;
    }

    /// @notice Checks whether a call is from the keeper.
    modifier onlyKeeper() {
        if (msg.sender != KEEPER_REGISTRY) {
            revert NotKeeper(msg.sender);
        }
        _;
    }

    /* ========== EVENT ========== */
    event NewAvatar(
        address avatarAddress,
        string name,
        uint256 gasLimit,
        uint256 timestamp
    );

    event RemoveAvatar(address avatarAddress, uint256 timestamp);

    event UpdateAvatarStatus(
        address avatarAddress,
        AvatarStatus oldStatus,
        AvatarStatus newStatus,
        uint256 timestamp
    );

    /***************************************
               ADMIN - GOVERNANCE
    ****************************************/
    /// @dev It will initiate the upKeep job for monitoring avatars
    /// @notice only callable via governance
    /// @param gasLimit gas limit for the avatar monitoring upkeep task
    function avatarMonitoring(uint256 gasLimit) external onlyGovernance {
        require(gasLimit > 0, "AvatarRegistry: gasLimit=0!");

        avatarMonitoringUpKeepId = _registerUpKeep(
            address(this),
            gasLimit,
            AVATAR_REGISTRY_NAME
        );

        if (avatarMonitoringUpKeepId > 0) {
            /// @dev give allowance of spending LINK funds
            LINK.approve(KEEPER_REGISTRY, type(uint256).max);
        }
    }

    /// @dev Adds an avatar into the registry
    /// @notice only callable via governance
    /// @param avatarAddress contract address to be register as new avatar
    /// @param name avatar's name
    /// @param gasLimit amount of gas to provide the target contract when
    /// performing upkeep
    function addAvatar(
        address avatarAddress,
        string memory name,
        uint256 gasLimit
    ) external onlyGovernance {
        /// @dev sanity checks before adding a new avatar in storage
        require(
            avatarAddress != address(0),
            "AvatarRegistry: AvatarRegistry: zero-address!"
        );
        require(
            avatarsInfo[avatarAddress].gasLimit == 0,
            "AvatarRegistry: avatar-already-added!"
        );
        require(gasLimit > 0, "AvatarRegistry: gasLimit=0!");

        require(_avatars.add(avatarAddress), "AvatarRegistry: not-add-in-set!");
        avatarsInfo[avatarAddress] = AvatarInfo({
            name: name,
            gasLimit: gasLimit,
            status: AvatarStatus.TESTING,
            upKeepId: 0
        });

        emit NewAvatar(avatarAddress, name, gasLimit, block.timestamp);
    }

    /// @dev Removes an avatar into the registry
    /// @notice only callable via governance
    /// @param avatarAddress contract address to be remove from the registry
    function removeAvatar(address avatarAddress) external onlyGovernance {
        require(
            _avatars.contains(avatarAddress),
            "AvatarRegistry: Avatar doesnt exist!"
        );
        require(
            _avatars.remove(avatarAddress),
            "AvatarRegistry: Not remove in the set!"
        );

        delete avatarsInfo[avatarAddress];

        emit RemoveAvatar(avatarAddress, block.timestamp);
    }

    /// @dev Updates status of an avatar in the registry
    /// @notice only callable via governance
    /// @param avatarAddress contract address update status of
    /// @param newStatus latest status of the avatar
    function updateStatus(address avatarAddress, AvatarStatus newStatus)
        external
        onlyGovernance
    {
        require(
            _avatars.contains(avatarAddress),
            "AvatarRegistry: Avatar doesnt exist!"
        );

        AvatarStatus oldStatus = avatarsInfo[avatarAddress].status;
        require(
            oldStatus != newStatus,
            "AvatarRegistry: Updating to same status!"
        );

        avatarsInfo[avatarAddress].status = newStatus;

        emit UpdateAvatarStatus(
            avatarAddress,
            oldStatus,
            newStatus,
            block.timestamp
        );
    }

    /***************************************
                KEEPERS - EXECUTORS
    ****************************************/
    /// @dev Runs off-chain at every block to determine if the `performUpkeep`
    /// function should be called on-chain.
    function checkUpkeep(bytes calldata)
        external
        view
        override
        whenNotPaused
        returns (bool upkeepNeeded_, bytes memory performData_)
    {
        address[] memory avatarsInTestStatus = getAvatarsInTestStatus();

        for (uint256 i = 0; i < avatarsInTestStatus.length; i++) {
            /// @dev requires that CL keeper is config properly
            if (IAvatar(avatarsInTestStatus[i]).keeper() != KEEPER_REGISTRY) {
                continue;
            }

            /// @dev prio `test` avatar unregister
            if (avatarsInfo[avatarsInTestStatus[i]].upKeepId == 0) {
                upkeepNeeded_ = true;
                performData_ = abi.encode(
                    avatarsInTestStatus[i],
                    OperationKeeperType.REGISTER_UPKEEP
                );
                break;
            }

            /// @dev check for under funded avatar upkeeps
            (, , bool underFunded) = _isAvatarUpKeepUnderFunded(
                avatarsInTestStatus[i]
            );
            if (underFunded) {
                upkeepNeeded_ = true;
                performData_ = abi.encode(
                    avatarsInTestStatus[i],
                    OperationKeeperType.TOPUP_UPKEEP
                );
                break;
            }
        }

        /// @dev check for the registry itself if its upkeep needs topup
    }

    /// @dev Contains the logic that should be executed on-chain when
    /// `checkUpkeep` returns true.
    function performUpkeep(bytes calldata _performData)
        external
        override
        onlyKeeper
    {
        (address avatarTarget, OperationKeeperType operationType) = abi.decode(
            _performData,
            (address, OperationKeeperType)
        );

        /// @dev check on-chain that config in avatar is correct
        require(
            IAvatar(avatarTarget).keeper() != KEEPER_REGISTRY,
            "AvatarRegistry: CL registry not set!"
        );
        require(
            avatarsInfo[avatarTarget].upKeepId == 0,
            "AvatarRegistry: UpKeep already register!"
        );

        if (operationType == OperationKeeperType.REGISTER_UPKEEP) {
            _registerAndRecordId(avatarTarget);
        } else {
            _topupUpkeep(avatarTarget);
        }
    }

    /// @dev returns the fast gwei and price of link/eth from CL
    /// @return gasWei current fastest gas value in wei
    /// @return linkEth latest answer of feed of link/eth
    function _getFeedData()
        internal
        view
        returns (uint256 gasWei, uint256 linkEth)
    {
        uint256 timestamp;
        int256 feedValue;

        /// @dev check as ref current fast wei gas
        (, feedValue, , timestamp, ) = FAST_GAS_FEED.latestRoundData();

        if (block.timestamp - timestamp > CL_FEED_HEARTBEAT_GAS) {
            revert StalePriceFeed(
                address(FAST_GAS_FEED),
                block.timestamp,
                timestamp,
                CL_FEED_HEARTBEAT_GAS
            );
        }

        gasWei = uint256(feedValue);

        /// @dev check latest oracle rate link/eth
        (, feedValue, , timestamp, ) = LINK_ETH_FEED.latestRoundData();

        if (block.timestamp - timestamp > CL_FEED_HEARTBEAT_LINK) {
            revert StalePriceFeed(
                address(LINK_ETH_FEED),
                block.timestamp,
                timestamp,
                CL_FEED_HEARTBEAT_LINK
            );
        }

        linkEth = uint256(feedValue);
    }

    /// @dev converts a gas limit value into link expressed amount
    /// @param gasLimit amount of gas to provide the target contract when
    /// performing upkeep
    /// @return linkAmount amount of LINK needed to cover the job
    function _getLinkAmount(uint256 gasLimit)
        internal
        view
        returns (uint256 linkAmount)
    {
        (, IKeeperRegistry.Config memory _c, ) = CL_REGISTRY.getState();
        (uint256 fastGasWei, uint256 linkEth) = _getFeedData();

        uint256 adjustedGas = fastGasWei * _c.gasCeilingMultiplier;
        uint256 weiForGas = adjustedGas * (gasLimit + REGISTRY_GAS_OVERHEAD);
        uint256 premium = PPB_BASE + _c.paymentPremiumPPB;

        /// @dev amount of LINK to carry one `performUpKeep` operation
        linkAmount =
            ((weiForGas * (1e9) * (premium)) / (linkEth)) +
            (uint256(_c.flatFeeMicroLink) * (1e12));
    }

    /// @dev registers target avatar into the CL registry and saves
    /// `upKeepId` into the mapping
    /// @notice only callable from `performUpKeep` method via keepers
    /// @param avatar contract avatar target to register
    function _registerAndRecordId(address avatar) internal {
        avatarsInfo[avatar].upKeepId = _registerUpKeep(
            avatar,
            avatarsInfo[avatar].gasLimit,
            avatarsInfo[avatar].name
        );
    }

    /// @dev checks if an avatar upKeepId is under-funded, helper in `checkUpKeep`
    /// and `performUpKeep` methods
    /// @param avatar contract address to verify if under-funded
    function _isAvatarUpKeepUnderFunded(address avatar)
        internal
        view
        returns (
            uint256 upKeepId,
            uint96 minUpKeepBal,
            bool underFunded
        )
    {
        upKeepId = avatarsInfo[avatar].upKeepId;

        /// @dev check onchain the min and current amounts to consider top-up
        minUpKeepBal = CL_REGISTRY.getMinBalanceForUpkeep(upKeepId);
        (, , , uint96 currentUpKeepBal, , , , ) = CL_REGISTRY.getUpkeep(
            upKeepId
        );

        if (currentUpKeepBal <= minUpKeepBal * 3) {
            underFunded = true;
        }
    }

    /// @dev carries over the top-up action of an avatar upKeep
    /// @param avatar contract address to top-up its targetted upKeepId
    function _topupUpkeep(address avatar) internal {
        (
            uint256 upKeepId,
            uint96 minUpKeepBal,
            bool underFunded
        ) = _isAvatarUpKeepUnderFunded(avatar);

        if (!underFunded) {
            revert NotUnderFundedUpkeep(upKeepId);
        }

        uint96 topupAmount = minUpKeepBal * uint96(ROUNDS_TOP_UP);

        require(
            LINK.balanceOf(address(this)) >= topupAmount,
            "AvatarRegistry: Not enough LINK in registry!"
        );

        CL_REGISTRY.addFunds(upKeepId, topupAmount);
    }

    /// @dev carries registration of target contract in CL
    /// @param targetAddress contract which will be register
    /// @param gasLimit amount of gas to provide the target contract when
    /// performing upkeep
    /// @param name detailed name for the upkeep job
    /// @return upkeepID id of cl job
    function _registerUpKeep(
        address targetAddress,
        uint256 gasLimit,
        string memory name
    ) internal returns (uint256 upkeepID) {
        /// @dev we ensure we top-up enough LINK for couple of test-runs (20) and sanity checks
        uint256 linkAmount = _getLinkAmount(gasLimit) * ROUNDS_TOP_UP;
        uint256 registryLinkBal = LINK.balanceOf(address(this));
        require(
            linkAmount >= MIN_FUNDING_UPKEEP,
            "AvatarRegistry: Min funding 5 LINK!"
        );
        require(
            registryLinkBal >= MIN_FUNDING_UPKEEP &&
                registryLinkBal >= linkAmount,
            "AvatarRegistry: Not enough LINK in registry!"
        );

        /// @dev check registry state before registering
        (
            IKeeperRegistry.State memory state,
            IKeeperRegistry.Config memory _c,
            address[] memory _k
        ) = CL_REGISTRY.getState();
        uint256 oldNonce = state.nonce;

        bytes memory data = abi.encodeCall(
            IKeeperRegistrar.register,
            (
                name,
                bytes(""),
                targetAddress,
                uint32(gasLimit),
                ADMIN_KEEPERS,
                bytes(""),
                uint96(linkAmount),
                0,
                address(this)
            )
        );

        LINK.transferAndCall(KEEPER_REGISTRAR, linkAmount, data);

        (state, _c, _k) = CL_REGISTRY.getState();
        uint256 newNonce = state.nonce;

        if (newNonce == oldNonce + 1) {
            upkeepID = uint256(
                keccak256(
                    abi.encodePacked(
                        blockhash(block.number - 1),
                        KEEPER_REGISTRY,
                        uint32(oldNonce)
                    )
                )
            );
        } else {
            revert NotAutoApproveKeeper();
        }
    }

    /***************************************
               PUBLIC FUNCTION
    ****************************************/
    /// @dev Returns all avatar addresses
    function getAvatars() public view returns (address[] memory) {
        return _avatars.values();
    }

    /// @dev Returns all avatar addresses which have `TESTING` status
    function getAvatarsInTestStatus() public view returns (address[] memory) {
        return _avatars.values();
    }
}
