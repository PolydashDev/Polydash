// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Minimal views of PolydashFactory used by other Polydash contracts.
interface IPolydashFactory {
    function isLaunch(address launch) external view returns (bool);
    function tradingRewardsPool() external view returns (address);
    function platformFeeWallet() external view returns (address);
}

/// @notice Minimal views of PolydashLaunch used by the hook and the factory.
interface IPolydashLaunch {
    function token() external view returns (address);
    function hook() external view returns (address);
    function creatorPayoutWallet() external view returns (address);
    function graduated() external view returns (bool);
    function collectPlatformFees() external returns (uint256);
}

/// @notice PolydashLaunch functions used by PolydashCommitVault.
interface IPolydashLaunchCommit {
    function token() external view returns (address);
    function phase() external view returns (uint8);
    function commitments(address user) external view returns (uint256);
    function refunds(address user) external view returns (uint256);
    function commit() external payable;
    function uncommit() external;
    function claimRefund() external returns (uint256);
    function withdrawUnprocessedCommitment() external returns (uint256);
}

/// @notice Functions of PolydashHook used by launches and the factory.
interface IPolydashHook {
    function factory() external view returns (address);
    function deployGraduatedPool(uint256 tokenAmount, uint256 creatorFeeBps, uint256 sellSpikeBps, uint256 sellSpikeDuration)
        external
        payable
        returns (PoolId id, uint128 liquidity);
    function claimCreatorFees(PoolId id) external returns (uint256);
    function collectPlatformFees(address launch) external returns (uint256);
    function poolIdOf(address launch) external view returns (PoolId);
    function computePoolId(address token) external view returns (PoolId);
}

/// @notice BuybackRouter entry point.
interface IBuybackRouter {
    function buyback() external payable returns (uint256 polydashOut);
}
