// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title JBBuybackDelegateOperations
/// @notice JB specific operation indexes for the JBBuybackDelegate
library JBBuybackDelegateOperations {
    // [0..18] - JBOperations
    // 19 - JBOperations2 (ENS/Handle)
    // 20 - JBUriOperations (Set token URI)
    // [21..23] - JB721Operations

    uint256 public constant MODIFY_POOL = 24;
}
