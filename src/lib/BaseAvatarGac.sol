// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseAvatar} from "./BaseAvatar.sol";
import {GlobalAccessControlManaged} from "./GlobalAccessControlManaged.sol";

/// @title BaseAvatarGac
/// @notice Forwards calls from the owner
// TODO: See if we need GAC
contract BaseAvatarGac is BaseAvatar, GlobalAccessControlManaged {
    function __BaseAvatarGac_init(address _owner, address _globalAccessControl) public onlyInitializing {
        __BaseAvatar_init(_owner);
        __GlobalAccessControlManaged_init(_globalAccessControl);
    }

    ////////////////////////////////////////////////////////////////////////////
    // PUBLIC: Owner
    ////////////////////////////////////////////////////////////////////////////

    /// @dev Make arbitrary Ethereum call
    /// @param to Address to call
    /// @param value ETH value
    /// @param data TX data
    function doCall(address to, uint256 value, bytes memory data)
        public
        payable
        virtual
        override
        gacPausable
        returns (bool success)
    {
        success = BaseAvatar.doCall(to, value, data);
    }
}
