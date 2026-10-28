// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PolydashStakingPool} from "./PolydashStakingPool.sol";

/// @title PolydashStakingFactory
/// @notice Anyone can create a staking pool for any ERC20 by depositing the rewards.
///         The owner can only change the fee recipient, the unstake fee for FUTURE pools
///         (capped at 5%) and the verified badge. The owner can never touch pool funds.
contract PolydashStakingFactory is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_UNSTAKE_FEE_BPS = 500; // 5% hard cap
    uint256 public constant MIN_DURATION = 1 days;
    uint256 public constant MAX_DURATION = 3650 days;

    address public owner;
    address public pendingOwner;
    address public feeRecipient;
    uint256 public unstakeFeeBps;

    address[] public allPools;
    mapping(address => bool) public isPool;
    mapping(address => bool) public verified;
    mapping(address => address[]) private _poolsByCreator;

    struct PoolInfo {
        address pool;
        address creator;
        address stakeToken;
        address rewardToken;
        string stakeSymbol;
        string rewardSymbol;
        uint8 stakeDecimals;
        uint8 rewardDecimals;
        string name;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint256 totalRewards;
        uint256 rewardRate; // scaled by 1e18
        uint256 totalStaked;
        uint256 maxTotalStake;
        uint256 stakerCount;
        uint256 unstakeFeeBps;
        bool verified;
    }

    event PoolCreated(
        address indexed pool,
        address indexed creator,
        address indexed stakeToken,
        address rewardToken,
        uint256 rewardAmount,
        uint256 startTime,
        uint256 endTime
    );
    event VerifiedSet(address indexed pool, bool verified);
    event FeeRecipientSet(address recipient);
    event UnstakeFeeSet(uint256 bps);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error InvalidParams();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _feeRecipient, uint256 _unstakeFeeBps) {
        if (_feeRecipient == address(0) || _unstakeFeeBps > MAX_UNSTAKE_FEE_BPS) revert InvalidParams();
        owner = msg.sender;
        feeRecipient = _feeRecipient;
        unstakeFeeBps = _unstakeFeeBps;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /// @param startTime unix seconds; 0 or a past time means "start now"
    function createPool(
        address stakeToken,
        address rewardToken,
        uint256 rewardAmount,
        uint256 startTime,
        uint256 duration,
        uint256 maxTotalStake,
        string calldata name,
        string calldata description
    ) external nonReentrant returns (address pool) {
        if (stakeToken == address(0) || rewardToken == address(0) || rewardAmount == 0) revert InvalidParams();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert InvalidParams();
        if (bytes(name).length == 0 || bytes(name).length > 64 || bytes(description).length > 280) revert InvalidParams();
        if (startTime < block.timestamp) startTime = block.timestamp;
        if (startTime > block.timestamp + 365 days) revert InvalidParams();
        uint256 endTime = startTime + duration;

        pool = address(
            new PolydashStakingPool(
                msg.sender, stakeToken, rewardToken, startTime, endTime, maxTotalStake, unstakeFeeBps, name, description
            )
        );
        IERC20(rewardToken).safeTransferFrom(msg.sender, pool, rewardAmount);
        uint256 received = PolydashStakingPool(pool).initializeRewards();

        allPools.push(pool);
        isPool[pool] = true;
        _poolsByCreator[msg.sender].push(pool);
        emit PoolCreated(pool, msg.sender, stakeToken, rewardToken, received, startTime, endTime);
    }

    // ---------- views ----------

    function poolsLength() external view returns (uint256) {
        return allPools.length;
    }

    function poolsByCreator(address creator) external view returns (address[] memory) {
        return _poolsByCreator[creator];
    }

    function getPoolInfo(address pool) public view returns (PoolInfo memory info) {
        PolydashStakingPool p = PolydashStakingPool(pool);
        info.pool = pool;
        info.creator = p.creator();
        info.stakeToken = address(p.stakeToken());
        info.rewardToken = address(p.rewardToken());
        (info.stakeSymbol, info.stakeDecimals) = _meta(info.stakeToken);
        (info.rewardSymbol, info.rewardDecimals) = _meta(info.rewardToken);
        info.name = p.name();
        info.description = p.description();
        info.startTime = p.startTime();
        info.endTime = p.endTime();
        info.totalRewards = p.totalRewards();
        info.rewardRate = p.rewardRate();
        info.totalStaked = p.totalStaked();
        info.maxTotalStake = p.maxTotalStake();
        info.stakerCount = p.stakerCount();
        info.unstakeFeeBps = p.unstakeFeeBps();
        info.verified = verified[pool];
    }

    /// @notice Newest-first page of pools.
    function getPools(uint256 offset, uint256 limit) external view returns (PoolInfo[] memory list) {
        uint256 n = allPools.length;
        if (offset >= n) return new PoolInfo[](0);
        uint256 count = n - offset < limit ? n - offset : limit;
        list = new PoolInfo[](count);
        for (uint256 i = 0; i < count; i++) {
            list[i] = getPoolInfo(allPools[n - 1 - offset - i]);
        }
    }

    function _meta(address token) internal view returns (string memory symbol, uint8 decimals) {
        try IERC20Metadata(token).symbol() returns (string memory s) {
            symbol = s;
        } catch {
            symbol = "???";
        }
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            decimals = d;
        } catch {
            decimals = 18;
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

    /// @notice Only affects pools created after the change.
    function setUnstakeFeeBps(uint256 bps) external onlyOwner {
        if (bps > MAX_UNSTAKE_FEE_BPS) revert InvalidParams();
        unstakeFeeBps = bps;
        emit UnstakeFeeSet(bps);
    }

    function transferOwnership(address newOwner) external onlyOwner {
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
