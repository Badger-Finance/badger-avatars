// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import {OwnableUpgradeable} from "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";
import {GlobalAccessControlManaged} from "./GlobalAccessControlManaged.sol";
import "@gnosis-safe/base/Executor.sol";

/**
    Avatar
    Forwards calls from the owner
*/
contract BaseAvatar is
    GlobalAccessControlManaged,
    OwnableUpgradeable,
    Executor
{
    function __BaseAvatar_init(address _globalAccessControl, address _owner)
        public
        onlyInitializing
    {
        __GlobalAccessControlManaged_init(_globalAccessControl);
        __Ownable_init_unchained();
        transferOwnership(_owner);
    }

    /// ===== View Functions =====

    /// @notice Used to track the deployed version of BaseAvatar.
    /// @return Current version of the contract.
    function baseAvatarVersion() external pure returns (string memory) {
        return "1.0";
    }

    /// ===== Permissioned Actions: Owner =====

    /**
     * @dev Make arbitrary Ethereum call
     * @param to Address to call
     * @param value ETH value
     * @param data TX data
     */
    function call(
        address to,
        uint256 value,
        bytes memory data
    ) external payable virtual onlyOwner gacPausable returns (bool success) {
        return execute(to, value, data, Enum.Operation.DelegateCall, gasleft());
    }
}
