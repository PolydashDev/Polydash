// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title BondingCurveMath
/// @notice Pure constant-product (x * y = k) virtual-AMM math used by PolydashLaunch.
/// @dev ethReserve   = virtualEth + realEthRaised
///      tokenReserve = curveSupply - tokensSold
///      All divisions that determine what stays in the pool round UP (in favour of the pool), so the
///      product ethReserve * tokenReserve can only stay equal or grow by rounding dust - it never shrinks.
///      All multiplications go through 512-bit mulDiv, so no intermediate overflow is possible.
library BondingCurveMath {
    error ZeroReserve();

    /// @notice Tokens received for `netEthIn` (after fees).
    function tokensOutForEthIn(uint256 ethReserve, uint256 tokenReserve, uint256 netEthIn)
        internal
        pure
        returns (uint256 tokensOut)
    {
        if (ethReserve == 0 || tokenReserve == 0) revert ZeroReserve();
        uint256 newEthReserve = ethReserve + netEthIn;
        uint256 newTokenReserve = Math.mulDiv(ethReserve, tokenReserve, newEthReserve, Math.Rounding.Ceil);
        tokensOut = tokenReserve - newTokenReserve;
    }

    /// @notice Gross ETH (before fees) released for `tokensIn`.
    function ethOutForTokensIn(uint256 ethReserve, uint256 tokenReserve, uint256 tokensIn)
        internal
        pure
        returns (uint256 grossEthOut)
    {
        if (ethReserve == 0 || tokenReserve == 0) revert ZeroReserve();
        uint256 newTokenReserve = tokenReserve + tokensIn;
        uint256 newEthReserve = Math.mulDiv(ethReserve, tokenReserve, newTokenReserve, Math.Rounding.Ceil);
        grossEthOut = ethReserve - newEthReserve;
    }

    /// @notice Spot price in wei per 1e18 token units.
    function spotPrice(uint256 ethReserve, uint256 tokenReserve) internal pure returns (uint256) {
        if (tokenReserve == 0) revert ZeroReserve();
        return Math.mulDiv(ethReserve, 1e18, tokenReserve);
    }

    /// @notice ETH reserve at which the fully-diluted market cap (spot price * totalSupply) equals `marketCapEth`.
    /// @dev mcap = (E / T) * S and E * T = k  =>  E^2 = mcap * k / S  =>  E = sqrt(mcap * k / S)
    function ethReserveForMarketCap(uint256 marketCapEth, uint256 k, uint256 totalSupply)
        internal
        pure
        returns (uint256)
    {
        return Math.sqrt(Math.mulDiv(marketCapEth, k, totalSupply));
    }
}
