// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IPolydashStakingFactory {
    function feeRecipient() external view returns (address);
}

/// @title PolydashStakingPool
/// @notice A single staking pool created through the PolydashStakingFactory.
///         Rewards stream linearly from startTime to endTime and are shared
///         pro-rata among stakers (Synthetix StakingRewards model).
///         Unstaking charges a fixed fee (set at creation) sent to the Polydash fee recipient.
///         Nobody - not the creator, not Polydash - can withdraw stakers' principal.
contract PolydashStakingPool is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e18;
    uint256 public constant BPS = 10_000;

    address public immutable factory;
    address public immutable creator;
    IERC20 public immutable stakeToken;
    IERC20 public immutable rewardToken;
    uint256 public immutable startTime;
    uint256 public immutable endTime;
    uint256 public immutable maxTotalStake; // 0 = unlimited
    uint256 public immutable unstakeFeeBps;

    string public name;
    string public description;

    bool public funded;
    uint256 public totalRewards; // actually received reward amount
    uint256 public rewardRate; // reward tokens per second, scaled by PRECISION

    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored; // scaled by PRECISION
    uint256 public unallocatedRewards; // scaled by PRECISION; accrued while nobody was staked
    bool public unallocatedRecovered;

    uint256 public totalStaked;
    uint256 public stakerCount;
    uint256 public totalRewardsPaid;

    mapping(address => uint256) public balanceOf;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount, uint256 fee);
    event RewardPaid(address indexed user, uint256 reward);
    event UnallocatedRecovered(address indexed creator, uint256 amount);

    error NotFactory();
    error NotCreator();
    error AlreadyFunded();
    error NotFunded();
    error ZeroAmount();
    error PoolEnded();
    error PoolNotEnded();
    error CapExceeded();
    error InsufficientBalance();
    error AlreadyRecovered();

    constructor(
        address _creator,
        address _stakeToken,
        address _rewardToken,
        uint256 _startTime,
        uint256 _endTime,
        uint256 _maxTotalStake,
        uint256 _unstakeFeeBps,
        string memory _name,
        string memory _description
    ) {
        factory = msg.sender;
        creator = _creator;
        stakeToken = IERC20(_stakeToken);
        rewardToken = IERC20(_rewardToken);
        startTime = _startTime;
        endTime = _endTime;
        maxTotalStake = _maxTotalStake;
        unstakeFeeBps = _unstakeFeeBps;
        name = _name;
        description = _description;
        lastUpdateTime = _startTime;
    }

    /// @dev Called by the factory right after it transfers the rewards in.
    ///      Uses the real received balance so fee-on-transfer reward tokens work.
    function initializeRewards() external returns (uint256 received) {
        if (msg.sender != factory) revert NotFactory();
        if (funded) revert AlreadyFunded();
        received = rewardToken.balanceOf(address(this));
        if (received == 0) revert ZeroAmount();
        funded = true;
        totalRewards = received;
        rewardRate = (received * PRECISION) / (endTime - startTime);
    }

    // ---------- views ----------

    function lastTimeRewardApplicable() public view returns (uint256) {
        if (block.timestamp < startTime) return startTime;
        return block.timestamp < endTime ? block.timestamp : endTime;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) return rewardPerTokenStored;
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * rewardRate) / totalStaked;
    }

    function earned(address account) public view returns (uint256) {
        return
            (balanceOf[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / PRECISION + rewards[account];
    }

    function pendingUnallocated() public view returns (uint256) {
        uint256 u = unallocatedRewards;
        if (totalStaked == 0) u += (lastTimeRewardApplicable() - lastUpdateTime) * rewardRate;
        return u / PRECISION;
    }

    function isActive() external view returns (bool) {
        return funded && block.timestamp < endTime;
    }

    // ---------- internal ----------

    function _updateReward(address account) internal {
        uint256 applicable = lastTimeRewardApplicable();
        if (totalStaked == 0) {
            unallocatedRewards += (applicable - lastUpdateTime) * rewardRate;
        } else {
            rewardPerTokenStored += ((applicable - lastUpdateTime) * rewardRate) / totalStaked;
        }
        lastUpdateTime = applicable;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    // ---------- user actions ----------

    function stake(uint256 amount) external nonReentrant {
        if (!funded) revert NotFunded();
        if (amount == 0) revert ZeroAmount();
        if (block.timestamp >= endTime) revert PoolEnded();
        _updateReward(msg.sender);

        uint256 before = stakeToken.balanceOf(address(this));
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = stakeToken.balanceOf(address(this)) - before;
        if (received == 0) revert ZeroAmount();
        if (maxTotalStake != 0 && totalStaked + received > maxTotalStake) revert CapExceeded();

        if (balanceOf[msg.sender] == 0) stakerCount += 1;
        balanceOf[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received);
    }

    function withdraw(uint256 amount) public nonReentrant {
        _withdraw(msg.sender, amount);
    }

    function claim() public nonReentrant {
        _claim(msg.sender);
    }

    function exit() external nonReentrant {
        _withdraw(msg.sender, balanceOf[msg.sender]);
        _claim(msg.sender);
    }

    /// @notice Withdraw principal without claiming rewards (rewards are forfeited). Always available.
    function emergencyWithdraw() external nonReentrant {
        uint256 bal = balanceOf[msg.sender];
        if (bal == 0) revert ZeroAmount();
        _updateReward(address(0));
        // forfeited rewards are returned to the creator via the unallocated bucket
        unallocatedRewards += (bal * (rewardPerTokenStored - userRewardPerTokenPaid[msg.sender])) + rewards[msg.sender] * PRECISION;
        rewards[msg.sender] = 0;
        userRewardPerTokenPaid[msg.sender] = rewardPerTokenStored;
        balanceOf[msg.sender] = 0;
        totalStaked -= bal;
        stakerCount -= 1;
        uint256 fee = _sendPrincipal(msg.sender, bal);
        emit Withdrawn(msg.sender, bal - fee, fee);
    }

    function _withdraw(address user, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        if (amount > balanceOf[user]) revert InsufficientBalance();
        _updateReward(user);
        balanceOf[user] -= amount;
        totalStaked -= amount;
        if (balanceOf[user] == 0) stakerCount -= 1;
        uint256 fee = _sendPrincipal(user, amount);
        emit Withdrawn(user, amount - fee, fee);
    }

    function _sendPrincipal(address user, uint256 amount) internal returns (uint256 fee) {
        fee = (amount * unstakeFeeBps) / BPS;
        if (fee > 0) {
            address recipient = IPolydashStakingFactory(factory).feeRecipient();
            stakeToken.safeTransfer(recipient, fee);
        }
        stakeToken.safeTransfer(user, amount - fee);
    }

    function _claim(address user) internal {
        _updateReward(user);
        uint256 reward = rewards[user];
        if (reward > 0) {
            rewards[user] = 0;
            totalRewardsPaid += reward;
            rewardToken.safeTransfer(user, reward);
            emit RewardPaid(user, reward);
        }
    }

    /// @notice After the pool ends, the creator can recover rewards that were never
    ///         allocated (periods with zero stakers + forfeited emergency-withdraw rewards).
    function recoverUnallocated() external nonReentrant {
        if (msg.sender != creator) revert NotCreator();
        if (block.timestamp < endTime) revert PoolNotEnded();
        _updateReward(address(0));
        uint256 amount = unallocatedRewards / PRECISION;
        if (amount == 0) revert ZeroAmount();
        unallocatedRewards -= amount * PRECISION;
        rewardToken.safeTransfer(creator, amount);
        emit UnallocatedRecovered(creator, amount);
    }
}
