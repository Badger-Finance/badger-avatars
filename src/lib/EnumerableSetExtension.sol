// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {EnumerableSetUpgradeable} from
    "../../lib/openzeppelin-contracts-upgradeable/contracts/utils/structs/EnumerableSetUpgradeable.sol";

library EnumerableSetExtension {
    function indexOf(EnumerableSetUpgradeable.UintSet storage set, uint256 value) internal view returns (uint256) {
        return set._inner._indexes[bytes32(value)] - 1;
    }
}
