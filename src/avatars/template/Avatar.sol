pragma solidity 0.8.12;
pragma experimental ABIEncoderV2;

import {BaseAvatar} from "../../lib/BaseAvatar.sol";

contract Avatar is BaseAvatar {
    /// @dev Initialize the Avatar with security settings and the designated owner
    /// @notice Proxies will set any non constant variable you declare as default value
    /// @dev add any extra changeable variable at end of initializer
    function initialize(address _globalAccessControl, address _owner)
        public
        initializer
    {
        __BaseAvatar_init(_globalAccessControl, _owner);
    }

    /// @dev Returns the name of the strategy
    function getName() external pure returns (string memory) {
        return "Avatar_Template";
    }

    /// NOTE: Add custom avatar functions below
}
