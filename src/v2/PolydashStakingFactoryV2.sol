// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PolydashStakingPoolV2} from "./PolydashStakingPoolV2.sol";

/// @title PolydashStakingFactoryV2
/// @notice Anyone can create a staking pool for any ERC20 by depositing the rewards and choosing a
///         claim fee of 1-5% (taken from rewards; 30% of it goes to the platform).
///         The owner can only change the platform fee recipient and the verified badge.
///         The owner can never touch pool funds.
contract PolydashStakingFactoryV2 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MIN_CLAIM_FEE_BPS = 100; // 1%
    uint256 public constant MAX_CLAIM_FEE_BPS = 500; // 5%
    uint256 public constant PLATFORM_SHARE_BPS = 3_000; // 30% of the claim fee
    uint256 public constant MIN_DURATION = 1 days;
    uint256 public constant MAX_DURATION = 3650 days;

    address public owner;
    address public pendingOwner;
    address public feeRecipient;

    address[] public allPools;
    mapping(address => bool) public isPool;
    mapping(address => bool) public verified;
    mapping(address => address[]) private _poolsByCreator;

    struct PoolInfo {
        address pool;
        address creator;
        address stakeToken;
        address rewardToken;
        string name;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint256 totalRewards;
        uint256 rewardRate; // scaled by 1e18
        uint256 totalStaked;
        uint256 maxTotalStake;
        uint256 stakerCount;
        uint256 claimFeeBps;
        bool verified;
    }

    event PoolCreated(
        address indexed pool,
        address indexed creator,
        address indexed stakeToken,
        address rewardToken,
        uint256 rewardAmount,
        uint256 startTime,
        uint256 endTime,
        uint256 claimFeeBps
    );
    event VerifiedSet(address indexed pool, bool verified);
    event FeeRecipientSet(address indexed recipient);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error InvalidParams();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _feeRecipient) {
        if (_feeRecipient == address(0)) revert InvalidParams();
        owner = msg.sender;
        feeRecipient = _feeRecipient;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /// @param startTime unix seconds; 0 or a past time means "start now"
    /// @param claimFeeBps fee taken from every reward claim, 100 (1%) to 500 (5%)
    function createPool(
        address stakeToken,
        address rewardToken,
        uint256 rewardAmount,
        uint256 startTime,
        uint256 duration,
        uint256 maxTotalStake,
        uint256 claimFeeBps,
        string calldata name,
        string calldata description
    ) external nonReentrant returns (address pool) {
        if (stakeToken == address(0) || rewardToken == address(0) || rewardAmount == 0) revert InvalidParams();
        if (rewardAmount > type(uint128).max) revert InvalidParams();
        if (claimFeeBps < MIN_CLAIM_FEE_BPS || claimFeeBps > MAX_CLAIM_FEE_BPS) revert InvalidParams();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidParams();
        if (bytes(name).length == 0 || bytes(name).length > 64 || bytes(description).length > 280) revert InvalidParams();
        // slither-disable-next-line timestamp
        if (startTime < block.timestamp) startTime = block.timestamp;
        // slither-disable-next-line timestamp
        if (startTime > block.timestamp + 365 days) revert InvalidParams();
        uint256 endTime = startTime + duration;

        pool = address(
            new PolydashStakingPoolV2(
                msg.sender, stakeToken, rewardToken, startTime, endTime, maxTotalStake, claimFeeBps, name, description
            )
        );
        allPools.push(pool);
        isPool[pool] = true;
        _poolsByCreator[msg.sender].push(pool);

        IERC20(rewardToken).safeTransferFrom(msg.sender, pool, rewardAmount);
        uint256 received = PolydashStakingPoolV2(pool).initializeRewards();
        // slither-disable-next-line reentrancy-events
        emit PoolCreated(pool, msg.sender, stakeToken, rewardToken, received, startTime, endTime, claimFeeBps);
    }

    // ---------- views ----------

    function poolsLength() external view returns (uint256) {
        return allPools.length;
    }

    function poolsByCreator(address creator) external view returns (address[] memory) {
        return _poolsByCreator[creator];
    }

    function getPoolInfo(address pool) public view returns (PoolInfo memory info) {
        if (!isPool[pool]) revert InvalidParams();
        PolydashStakingPoolV2 p = PolydashStakingPoolV2(pool);
        info.pool = pool;
        info.creator = p.creator();
        info.stakeToken = address(p.stakeToken());
        info.rewardToken = address(p.rewardToken());
        info.name = p.name();
        info.description = p.description();
        info.startTime = p.startTime();
        info.endTime = p.endTime();
        info.totalRewards = p.totalRewards();
        info.rewardRate = p.rewardRate();
        info.totalStaked = p.totalStaked();
        info.maxTotalStake = p.maxTotalStake();
        info.stakerCount = p.stakerCount();
        info.claimFeeBps = p.claimFeeBps();
        info.verified = verified[pool];
    }

    /// @notice Pool addresses, newest first. Token metadata (symbol/decimals) is intentionally not
    ///         read on-chain: the website reads it per token with failure isolation, so a token with
    ///         hostile metadata cannot break the pool list.
    function getPoolAddresses(uint256 offset, uint256 limit) external view returns (address[] memory list) {
        uint256 n = allPools.length;
        // slither-disable-next-line timestamp
        if (offset >= n) return new address[](0);
        // slither-disable-next-line timestamp
        uint256 count = n - offset < limit ? n - offset : limit;
        list = new address[](count);
        // slither-disable-next-line timestamp
        for (uint256 i = 0; i < count; i++) {
            list[i] = allPools[n - 1 - offset - i];
        }
    }

    // ---------- admin (cannot touch funds) ----------

    function setVerified(address pool, bool v) external onlyOwner {
        if (!isPool[pool]) revert InvalidParams();
        verified[pool] = v;
        emit VerifiedSet(pool, v);
    }

    function setFeeRecipient(address r) external onlyOwner {
        if (r == address(0)) revert InvalidParams();
        feeRecipient = r;
        emit FeeRecipientSet(r);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidParams();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
