// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseAvatarUtils} from "../BaseAvatarUtils.sol";
import {AvatarRegistryConstants} from "./AvatarRegistryConstants.sol";

contract AvatarRegistryUtils is BaseAvatarUtils, AvatarRegistryConstants {
    ////////////////////////////////////////////////////////////////////////////
    // INTERNAL VIEW
    ////////////////////////////////////////////////////////////////////////////
    function getLinkAmountInEth(uint256 _linkAmount) internal view returns (uint256 ethAmount_) {
        uint256 linkInEth = fetchPriceFromClFeed(LINK_ETH_FEED, CL_FEED_HEARTBEAT_LINK);
        // Divide by the rate from oracle since it is link expressed in eth
        ethAmount_ = (_linkAmount * 1 ether) / linkInEth;
    }
}
