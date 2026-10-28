// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPolydashFactory, IPolydashLaunchCommit} from "./interfaces/IPolydash.sol";

/// @title PolydashCommitVault
/// @notice Pooled, fair-price pre-launch commitments for Polydash launches.
///
///         A launch processes its own commitments one by one in commit order, so earlier committers get a
///         better curve price. Committing through this vault instead pools everyone into ONE commitment on the
///         launch: the whole pool is bought in a single step and every depositor receives exactly the same
///         average price - tokens (and any over-threshold ETH refund) are split pro-rata to deposits.
///
///         Non-custodial and admin-free: there is no owner, no fee, no pause, no sweep. Funds only ever move
///         back to the depositor who put them in.
///
/// Flow per launch:
///   1. deposit(launch)              while the launch is Pending       -> ETH forwarded to launch.commit()
///   2. withdraw(launch, amount)     while the launch is Pending       -> launch.uncommit() + recommit the rest
///   3. settle(launch)               once the launch processed the vault's commitment (anyone may call)
///   4. claim(launch) / claimFor     after settlement -> pro-rata tokens + pro-rata ETH refund
contract PolydashCommitVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Mirrors PolydashLaunch.Phase.
    uint8 internal constant PHASE_PENDING = 1;
    uint8 internal constant PHASE_GRADUATED = 4;

    /// @notice Must equal PolydashLaunch.MIN_COMMITMENT so the pooled commitment is always accepted.
    uint256 public constant MIN_DEPOSIT = 0.0001 ether;

    IPolydashFactory public immutable factory;

    struct Pool {
        uint256 totalDeposited; // live sum of deposits (frozen at settlement)
        uint256 tokensReceived; // snapshot at settlement
        uint256 ethRefunded; // snapshot at settlement
        uint256 depositsClaimed; // sum of deposits already claimed
        uint256 tokensPaid;
        uint256 ethPaid;
        uint256 depositors;
        bool settled;
    }

    mapping(address launch => Pool) public pools;
    mapping(address launch => mapping(address user => uint256)) public deposits;
    mapping(address launch => mapping(address user => bool)) public claimed;

    event Deposited(address indexed launch, address indexed user, uint256 amount, uint256 totalDeposited);
    event Withdrawn(address indexed launch, address indexed user, uint256 amount, uint256 totalDeposited);
    event Settled(address indexed launch, uint256 totalDeposited, uint256 tokensReceived, uint256 ethRefunded);
    event Claimed(address indexed launch, address indexed user, uint256 deposit, uint256 tokens, uint256 eth);

    error NotLaunch();
    error WrongPhase(uint8 phase);
    error BelowMinimum();
    error InsufficientDeposit();
    error NotProcessed();
    error AlreadySettled();
    error NotSettled();
    error NothingToClaim();
    error UnexpectedEth();
    error EthTransferFailed();
    error InvalidParams();

    constructor(address _factory) {
        if (_factory == address(0)) revert InvalidParams();
        factory = IPolydashFactory(_factory);
    }

    /// @dev ETH is accepted only from factory-deployed launches (uncommit / refunds), never from users.
    receive() external payable {
        if (!factory.isLaunch(msg.sender)) revert UnexpectedEth();
    }

    // ================================================================== deposits (launch Pending)

    /// @notice Commit ETH to `launch` through the pool. Forwarded to the launch immediately.
    function deposit(address launch) external payable nonReentrant {
        _requirePending(launch);
        // every forwarded amount must satisfy the launch's own per-call minimum
        if (msg.value < MIN_DEPOSIT) revert BelowMinimum();
        uint256 newBalance = deposits[launch][msg.sender] + msg.value;

        Pool storage p = pools[launch];
        if (deposits[launch][msg.sender] == 0) ++p.depositors;
        deposits[launch][msg.sender] = newBalance;
        p.totalDeposited += msg.value;
        emit Deposited(launch, msg.sender, msg.value, p.totalDeposited);

        IPolydashLaunchCommit(launch).commit{value: msg.value}();
    }

    /// @notice Withdraw `amount` of your deposit while the launch is still Pending. The remaining balance must
    ///         be zero or at least MIN_DEPOSIT.
    function withdraw(address launch, uint256 amount) external nonReentrant {
        _requirePending(launch);
        uint256 bal = deposits[launch][msg.sender];
        if (amount == 0 || amount > bal) revert InsufficientDeposit();
        uint256 left = bal - amount;
        if (left != 0 && left < MIN_DEPOSIT) revert BelowMinimum();

        Pool storage p = pools[launch];
        deposits[launch][msg.sender] = left;
        if (left == 0) --p.depositors;
        uint256 remainingPool = p.totalDeposited - amount;
        p.totalDeposited = remainingPool;
        emit Withdrawn(launch, msg.sender, amount, remainingPool);

        // The launch only supports full uncommits: pull everything back, then recommit what remains.
        _pullFrom(launch, false);
        if (remainingPool > 0) IPolydashLaunchCommit(launch).commit{value: remainingPool}();
        _sendEth(msg.sender, amount);
    }

    // ================================================================== settlement

    /// @notice Snapshot the tokens (and refund) the pooled commitment produced. Callable by anyone once the
    ///         launch has processed the vault's commitment. Pulls any pending refund from the launch.
    function settle(address launch) public nonReentrant {
        if (!factory.isLaunch(launch)) revert NotLaunch();
        Pool storage p = pools[launch];
        if (p.settled) revert AlreadySettled();
        IPolydashLaunchCommit l = IPolydashLaunchCommit(launch);
        uint8 ph = l.phase();
        if (ph <= PHASE_PENDING) revert WrongPhase(ph);

        uint256 unprocessed = l.commitments(address(this));
        // After graduation an unprocessed commitment can be withdrawn directly instead of waiting for a batch.
        if (unprocessed > 0 && ph != PHASE_GRADUATED) revert NotProcessed();
        uint256 refund = l.refunds(address(this));

        uint256 tokens = IERC20(l.token()).balanceOf(address(this));
        p.settled = true;
        p.tokensReceived = tokens;
        p.ethRefunded = refund + unprocessed;
        emit Settled(launch, p.totalDeposited, tokens, refund + unprocessed);

        if (unprocessed > 0) _pullFrom(launch, true);
        // slither-disable-next-line unused-return
        if (refund > 0) l.claimRefund();
    }

    /// @notice Claim your pro-rata tokens and ETH refund (settles first if needed).
    function claim(address launch) external returns (uint256 tokens, uint256 eth) {
        return claimFor(launch, msg.sender);
    }

    /// @notice Anyone may push a depositor's share to them; funds always go to `user`.
    // settle() and _claim() each hold the reentrancy lock; the event ordering across them is benign
    // slither-disable-next-line reentrancy-events
    function claimFor(address launch, address user) public returns (uint256 tokens, uint256 eth) {
        if (!pools[launch].settled) settle(launch);
        return _claim(launch, user);
    }

    function _claim(address launch, address user) internal nonReentrant returns (uint256 tokens, uint256 eth) {
        Pool storage p = pools[launch];
        uint256 dep = deposits[launch][user];
        if (dep == 0 || claimed[launch][user]) revert NothingToClaim();
        claimed[launch][user] = true;

        uint256 claimedAfter = p.depositsClaimed + dep;
        if (claimedAfter == p.totalDeposited) {
            // last claimer receives the exact remainder -> zero rounding dust is left behind
            tokens = p.tokensReceived - p.tokensPaid;
            eth = p.ethRefunded - p.ethPaid;
        } else {
            tokens = Math.mulDiv(p.tokensReceived, dep, p.totalDeposited);
            eth = Math.mulDiv(p.ethRefunded, dep, p.totalDeposited);
        }
        p.depositsClaimed = claimedAfter;
        p.tokensPaid += tokens;
        p.ethPaid += eth;
        emit Claimed(launch, user, dep, tokens, eth);

        if (tokens > 0) IERC20(IPolydashLaunchCommit(launch).token()).safeTransfer(user, tokens);
        if (eth > 0) _sendEth(user, eth);
    }

    // ================================================================== views

    /// @notice Preview a depositor's share (only meaningful after settlement).
    function pendingClaim(address launch, address user) external view returns (uint256 tokens, uint256 eth) {
        Pool storage p = pools[launch];
        uint256 dep = deposits[launch][user];
        if (!p.settled || dep == 0 || claimed[launch][user]) return (0, 0);
        if (p.depositsClaimed + dep == p.totalDeposited) {
            return (p.tokensReceived - p.tokensPaid, p.ethRefunded - p.ethPaid);
        }
        return (Math.mulDiv(p.tokensReceived, dep, p.totalDeposited), Math.mulDiv(p.ethRefunded, dep, p.totalDeposited));
    }

    // ================================================================== internal

    function _requirePending(address launch) internal view {
        if (!factory.isLaunch(launch)) revert NotLaunch();
        uint8 ph = IPolydashLaunchCommit(launch).phase();
        if (ph != PHASE_PENDING) revert WrongPhase(ph);
        if (pools[launch].settled) revert AlreadySettled(); // unreachable while Pending; defensive
    }

    /// @dev Pulls the vault's full commitment back from `launch` (uncommit while Pending, or
    ///      withdrawUnprocessedCommitment after graduation).
    function _pullFrom(address launch, bool afterGraduation) internal {
        if (afterGraduation) {
            // slither-disable-next-line unused-return
            IPolydashLaunchCommit(launch).withdrawUnprocessedCommitment();
        } else {
            IPolydashLaunchCommit(launch).uncommit();
        }
    }

    /// @dev Only ever called with msg.sender (withdraw) or a depositor's own address (claim).
    // slither-disable-next-line arbitrary-send-eth
    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
