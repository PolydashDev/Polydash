// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title FeeMath
/// @notice Single source of truth for the Polydash fee split. Pure functions only.
/// @dev Every fee is computed from the GROSS trade volume (in ETH) with floor rounding:
///        platformFee = gross * 20 / 10_000
///        creatorFee  = gross * creatorFeeBps / 10_000
///        taxFee      = gross * taxBps / 10_000        (anti-sniper / post-graduation sell spike surplus)
///      Because each component is floored independently, the platform fee is always exactly
///      floor(gross * 0.2%) - it is never rounded up and never shares a remainder with any other party.
library FeeMath {
    /// @notice Platform fee: 0.2% of trading volume. Hard-coded. There is no setter anywhere in the system.
    uint256 internal constant PLATFORM_FEE_BPS = 20;
    /// @notice Hard upper bound on the creator fee (2%).
    uint256 internal constant MAX_CREATOR_FEE_BPS = 200;
    uint256 internal constant BPS = 10_000;

    struct Fees {
        uint256 platform;
        uint256 creator;
        uint256 tax;
        uint256 total;
    }

    /// @notice Split fees out of a gross ETH amount.
    function split(uint256 gross, uint256 creatorFeeBps, uint256 taxBps) internal pure returns (Fees memory f) {
        f.platform = (gross * PLATFORM_FEE_BPS) / BPS;
        f.creator = (gross * creatorFeeBps) / BPS;
        f.tax = (gross * taxBps) / BPS;
        f.total = f.platform + f.creator + f.tax;
    }

    /// @notice Smallest gross amount whose net (gross - fee at `totalBps`) is >= `net`.
    /// @dev Used when the NET side of a trade is fixed (exact-output swaps, capped buys).
    function grossForNet(uint256 net, uint256 totalBps) internal pure returns (uint256) {
        return Math.mulDiv(net, BPS, BPS - totalBps, Math.Rounding.Ceil);
    }
}
