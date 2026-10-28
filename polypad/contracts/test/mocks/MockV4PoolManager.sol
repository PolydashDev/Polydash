// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

/// @notice Local stand-in for the Robinhood Chain V4 PoolManager.
/// @dev This is the REAL, unmodified Uniswap v4-core v4.0.0 PoolManager (the same release deployed on-chain),
///      so the graduation and hook tests exercise genuine V4 accounting (deltas, settle/take, donate, hook
///      permissions, address flag validation) rather than a hand-written fake.
contract MockV4PoolManager is PoolManager {
    constructor(address owner_) PoolManager(owner_) {}
}
