// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title HookPermissions
/// @notice The exact Uniswap V4 hook permission set used by PolydashHook and the matching address flag mask.
/// @dev Uniswap V4 encodes hook permissions in the lowest 14 bits of the hook address. Bit values (v4-core v4.0.0):
///        BEFORE_INITIALIZE_FLAG          = 1 << 13  -> used: blocks anyone else from creating pools with this hook
///        BEFORE_SWAP_FLAG                = 1 << 7   -> used: fee collection when ETH is the specified currency
///        AFTER_SWAP_FLAG                 = 1 << 6   -> used: fee collection when ETH is the unspecified currency
///        BEFORE_SWAP_RETURNS_DELTA_FLAG  = 1 << 3   -> used
///        AFTER_SWAP_RETURNS_DELTA_FLAG   = 1 << 2   -> used
///      No liquidity-removal hook is enabled, and the hook never calls modifyLiquidity with a negative delta.
library HookPermissions {
    uint160 internal constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    function permissions() internal pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }
}
