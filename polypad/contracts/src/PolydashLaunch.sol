// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {PolydashToken} from "./PolydashToken.sol";
import {BondingCurveMath} from "./libraries/BondingCurveMath.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {IPolydashHook} from "./interfaces/IPolydash.sol";

/// @title PolydashLaunch
/// @notice Per-token bonding curve (constant-product virtual AMM priced in ETH). Deployed as an EIP-1167
///         clone by PolydashFactory and initialised exactly once.
///
/// Lifecycle:  Pending (commit / uncommit)  ->  ProcessingCommitments  ->  Trading  ->  Graduated
///
/// Fees on every curve trade (all in ETH, all computed on the gross ETH amount):
///   - platform: exactly 20 bps (hard-coded, FeeMath.PLATFORM_FEE_BPS)
///   - creator : creatorFeeBps, fixed at launch, 0..500 bps
///   - anti-sniper surplus (public buys only, first minutes of trading): decays to 0, is NOT paid to anyone -
///     it is added to the permanently locked graduation liquidity.
///
/// Creator fees can only ever be paid to `creatorPayoutWallet`. No function lets the factory, its owner or
/// anyone else move, pause or redirect them.
contract PolydashLaunch is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ constants
    uint256 public constant PLATFORM_FEE_BPS = FeeMath.PLATFORM_FEE_BPS;
    uint256 public constant MAX_CREATOR_FEE_BPS = FeeMath.MAX_CREATOR_FEE_BPS;
    uint256 public constant PAYOUT_WALLET_DELAY = 48 hours;
    uint256 public constant MAX_BATCH = 200;
    uint256 public constant MIN_COMMITMENT = 0.0001 ether;

    enum Phase {
        Uninitialized,
        Pending,
        ProcessingCommitments,
        Trading,
        Graduated
    }

    struct InitParams {
        address token;
        address creator;
        address creatorPayoutWallet;
        address hook;
        uint256 creatorFeeBps;
        uint256 totalSupply;
        uint256 curveSupply;
        uint256 virtualEth;
        uint256 graduationThreshold;
        uint256 devBuyEth;
        uint256 launchTime;
        uint256 antiSniperFeeBps;
        uint256 antiSniperFeeDuration;
        uint256 antiSniperCapBlocks;
        uint256 antiSniperCapBps;
        uint256 sellSpikeBps;
        uint256 sellSpikeDuration;
    }

    // ------------------------------------------------------------------ config (set once in initialize)
    address public factory;
    address public token;
    address public creator;
    address public hook;
    uint256 public creatorFeeBps;
    uint256 public totalSupply;
    uint256 public curveSupply;
    uint256 public virtualEth;
    /// @notice Initial product virtualEth * curveSupply.
    uint256 public k;
    uint256 public graduationThreshold;
    uint256 public launchTime;
    uint256 public antiSniperFeeBps;
    uint256 public antiSniperFeeDuration;
    uint256 public antiSniperCapBlocks;
    uint256 public antiSniperCapBps;
    uint256 public sellSpikeBps;
    uint256 public sellSpikeDuration;

    // ------------------------------------------------------------------ state
    Phase public phase;
    uint256 public realEthRaised;
    uint256 public tokensSold;
    uint256 public tradingStartTime;
    uint256 public tradingStartBlock;

    uint256 public platformFeesAccrued;
    uint256 public creatorFeesAccrued;
    /// @notice Anti-sniper surplus; added to graduation liquidity, never withdrawable.
    uint256 public sniperTaxAccrued;

    uint256 public devBuyEth;
    uint256 public devBuyTokens;

    address public creatorPayoutWallet;
    address public pendingPayoutWallet;
    uint256 public payoutWalletChangeAt;

    mapping(address => uint256) public commitments;
    mapping(address => bool) internal _isCommitter;
    address[] public committers;
    uint256 public totalCommitted;
    uint256 public commitmentCursor;

    /// @notice Pull-refunds (over-threshold commitments / dev buy remainder).
    mapping(address => uint256) public refunds;
    uint256 public totalRefunds;

    mapping(address => uint256) public walletBought;

    PoolId public poolId;
    uint256 public graduationEth;
    uint256 public graduationTokens;
    uint256 public graduatedAt;

    // ------------------------------------------------------------------ events
    event Initialized(address indexed token, address indexed creator, uint256 creatorFeeBps, uint256 graduationThreshold);
    event Bought(
        address indexed buyer, uint256 ethIn, uint256 tokensOut, uint256 platformFee, uint256 creatorFee, uint256 price
    );
    event Sold(
        address indexed seller, uint256 tokensIn, uint256 ethOut, uint256 platformFee, uint256 creatorFee, uint256 price
    );
    event SniperTaxCollected(address indexed buyer, uint256 amount);
    event Graduated(
        address indexed token, uint256 ethAdded, uint256 tokensAdded, uint256 tokensBurned, PoolId poolId, uint256 timestamp
    );
    event DevBuyExecuted(address indexed creator, uint256 ethSpent, uint256 tokensReceived);
    event CreatorFeesClaimed(address indexed payoutWallet, uint256 amount);
    event PlatformFeesCollected(uint256 amount);
    event Committed(address indexed user, uint256 amount);
    event Uncommitted(address indexed user, uint256 amount);
    event CommitmentProcessed(address indexed user, uint256 ethCommitted, uint256 tokensReceived);
    event RefundCredited(address indexed user, uint256 amount);
    event RefundClaimed(address indexed user, uint256 amount);
    event WentLive(uint256 timestamp, uint256 committers);
    event TradingOpened(uint256 timestamp, uint256 blockNumber);
    event PayoutWalletChangeInitiated(address indexed oldWallet, address indexed newWallet, uint256 executeAt);
    event PayoutWalletChangeCancelled(address indexed cancelledWallet, address indexed cancelledBy);
    event PayoutWalletChanged(address indexed oldWallet, address indexed newWallet);

    // ------------------------------------------------------------------ errors
    error AlreadyInitialized();
    error OnlyFactory();
    error OnlyCreator();
    error WrongPhase(Phase current);
    error InvalidParams();
    error TooEarly();
    error Slippage();
    error ZeroAmount();
    error WalletCapExceeded(uint256 wouldHold, uint256 cap);
    error EthTransferFailed();
    error NothingToClaim();
    error NoPendingChange();

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    modifier inPhase(Phase p) {
        if (phase != p) revert WrongPhase(phase);
        _;
    }

    // ================================================================== initialisation

    /// @dev Locks the implementation contract so it can never be initialised (clones do not run constructors).
    constructor() {
        factory = address(this);
    }

    /// @notice Called once by the factory right after cloning. msg.value is the dev buy.
    function initialize(InitParams calldata p) external payable {
        if (phase != Phase.Uninitialized || factory != address(0)) revert AlreadyInitialized();
        if (
            p.creatorFeeBps > MAX_CREATOR_FEE_BPS || p.token == address(0) || p.hook == address(0)
                || p.creatorPayoutWallet == address(0) || msg.value != p.devBuyEth || p.curveSupply == 0
                || p.curveSupply > p.totalSupply || p.virtualEth == 0 || p.graduationThreshold == 0
        ) revert InvalidParams();

        factory = msg.sender;
        token = p.token;
        creator = p.creator;
        hook = p.hook;
        creatorPayoutWallet = p.creatorPayoutWallet;
        creatorFeeBps = p.creatorFeeBps;
        totalSupply = p.totalSupply;
        curveSupply = p.curveSupply;
        virtualEth = p.virtualEth;
        k = p.virtualEth * p.curveSupply;
        graduationThreshold = p.graduationThreshold;
        devBuyEth = p.devBuyEth;
        launchTime = p.launchTime;
        antiSniperFeeBps = p.antiSniperFeeBps;
        antiSniperFeeDuration = p.antiSniperFeeDuration;
        antiSniperCapBlocks = p.antiSniperCapBlocks;
        antiSniperCapBps = p.antiSniperCapBps;
        sellSpikeBps = p.sellSpikeBps;
        sellSpikeDuration = p.sellSpikeDuration;
        phase = Phase.Pending;

        emit Initialized(p.token, p.creator, p.creatorFeeBps, p.graduationThreshold);
    }

    // ================================================================== commitments (pre-launch)

    /// @notice Commit ETH before launch. It is executed as a buy (no anti-sniper surcharge, no wallet cap,
    ///         normal platform + creator fee) when the launch goes live, and the tokens are sent to you.
    function commit() external payable nonReentrant inPhase(Phase.Pending) {
        if (msg.value < MIN_COMMITMENT) revert ZeroAmount();
        if (!_isCommitter[msg.sender]) {
            _isCommitter[msg.sender] = true;
            committers.push(msg.sender);
        }
        commitments[msg.sender] += msg.value;
        totalCommitted += msg.value;
        emit Committed(msg.sender, msg.value);
    }

    /// @notice Withdraw your full commitment. Only possible before the launch goes live.
    function uncommit() external nonReentrant inPhase(Phase.Pending) {
        uint256 amount = commitments[msg.sender];
        if (amount == 0) revert NothingToClaim();
        commitments[msg.sender] = 0;
        totalCommitted -= amount;
        emit Uncommitted(msg.sender, amount);
        _sendEth(msg.sender, amount);
    }

    /// @notice Starts the launch: executes the dev buy, then processes up to MAX_BATCH commitments.
    ///         Callable by anyone once `launchTime` is reached (the factory calls it for immediate launches).
    function goLive() external nonReentrant inPhase(Phase.Pending) {
        if (block.timestamp < launchTime) revert TooEarly();
        phase = Phase.ProcessingCommitments;
        emit WentLive(block.timestamp, committers.length);

        if (devBuyEth > 0) {
            uint256 sent = devBuyEth;
            (uint256 tokensOut, uint256 ethUsed) = _executeBuy(creator, sent, false);
            if (ethUsed < sent) _creditRefund(creator, sent - ethUsed);
            devBuyEth = ethUsed;
            devBuyTokens = tokensOut;
            emit DevBuyExecuted(creator, ethUsed, tokensOut);
        }
        _processCommitments(MAX_BATCH);
        if (_thresholdReached()) _graduate();
    }

    /// @notice Process the next `maxCount` (<= MAX_BATCH) commitments. Callable by anyone.
    ///         Public trading opens automatically when the last commitment is processed.
    ///         Also callable after graduation while unprocessed commitments remain (they are refunded), so a
    ///         graduation inside an earlier batch can never strand later commitments.
    function processCommitmentBatch(uint256 maxCount) external nonReentrant {
        Phase ph = phase;
        if (ph != Phase.ProcessingCommitments && !(ph == Phase.Graduated && commitmentCursor < committers.length)) {
            revert WrongPhase(ph);
        }
        if (maxCount == 0 || maxCount > MAX_BATCH) revert InvalidParams();
        _processCommitments(maxCount);
        if (_thresholdReached() && phase != Phase.Graduated) _graduate();
    }

    /// @notice After graduation, withdraw a commitment that was never processed (instead of waiting for a batch).
    function withdrawUnprocessedCommitment() external nonReentrant inPhase(Phase.Graduated) returns (uint256 amount) {
        amount = commitments[msg.sender];
        if (amount == 0) revert NothingToClaim();
        commitments[msg.sender] = 0;
        totalCommitted -= amount;
        emit Uncommitted(msg.sender, amount);
        _sendEth(msg.sender, amount);
    }

    /// @dev Never makes an untrusted external call: buys only move the launch's own token. Graduation (the only
    ///      ETH-moving external call) is performed by the caller AFTER all state updates.
    function _processCommitments(uint256 maxCount) internal {
        uint256 cursor = commitmentCursor;
        uint256 end = Math.min(committers.length, cursor + maxCount);
        for (; cursor < end; ++cursor) {
            address user = committers[cursor];
            uint256 amount = commitments[user];
            if (amount == 0) continue;
            commitments[user] = 0;
            totalCommitted -= amount;
            if (_thresholdReached()) {
                // threshold already reached by earlier buys -> full refund
                _creditRefund(user, amount);
                emit CommitmentProcessed(user, amount, 0);
                continue;
            }
            (uint256 tokensOut, uint256 used) = _executeBuy(user, amount, false);
            if (used < amount) _creditRefund(user, amount - used);
            emit CommitmentProcessed(user, used, tokensOut);
        }
        commitmentCursor = cursor;
        if (cursor == committers.length && phase == Phase.ProcessingCommitments && !_thresholdReached()) {
            phase = Phase.Trading;
            tradingStartTime = block.timestamp;
            tradingStartBlock = block.number;
            emit TradingOpened(block.timestamp, block.number);
        }
    }

    function _thresholdReached() internal view returns (bool) {
        return realEthRaised >= graduationThreshold;
    }

    // ================================================================== trading

    /// @notice Buy tokens with ETH. If this buy reaches the graduation threshold it is capped, the unused ETH
    ///         is returned in the same transaction, and the token graduates to Uniswap V4 atomically.
    function buy(uint256 minTokensOut) external payable nonReentrant inPhase(Phase.Trading) returns (uint256 tokensOut) {
        if (msg.value == 0) revert ZeroAmount();
        uint256 used;
        (tokensOut, used) = _executeBuy(msg.sender, msg.value, true);
        // slither-disable-next-line incorrect-equality
        if (tokensOut == 0 || tokensOut < minTokensOut) revert Slippage();
        if (_thresholdReached()) _graduate();
        if (used < msg.value) _sendEth(msg.sender, msg.value - used);
    }

    /// @notice Sell tokens back to the curve. Requires an ERC-20 approval of `tokensIn` to this contract.
    function sell(uint256 tokensIn, uint256 minEthOut) external nonReentrant inPhase(Phase.Trading) returns (uint256 ethOut) {
        if (tokensIn == 0 || tokensIn > tokensSold) revert InvalidParams();
        uint256 grossEth = BondingCurveMath.ethOutForTokensIn(ethReserve(), tokenReserve(), tokensIn);
        if (grossEth > realEthRaised) grossEth = realEthRaised; // defensive; unreachable by construction
        FeeMath.Fees memory f = FeeMath.split(grossEth, creatorFeeBps, 0);
        ethOut = grossEth - f.total;
        // slither-disable-next-line incorrect-equality
        if (ethOut == 0 || ethOut < minEthOut) revert Slippage();

        realEthRaised -= grossEth;
        tokensSold -= tokensIn;
        platformFeesAccrued += f.platform;
        creatorFeesAccrued += f.creator;
        emit Sold(msg.sender, tokensIn, ethOut, f.platform, f.creator, spotPrice());

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);
        _sendEth(msg.sender, ethOut);
    }

    /// @dev Core buy. Returns tokens bought and gross ETH actually used (may be < grossEth if capped at threshold).
    ///      Must not be called once the threshold is reached. Does NOT graduate: callers do that last.
    function _executeBuy(address buyer, uint256 grossEth, bool isPublic) internal returns (uint256 tokensOut, uint256 used) {
        uint256 taxBps = isPublic ? currentSniperSurplusBps() : 0;
        FeeMath.Fees memory f = FeeMath.split(grossEth, creatorFeeBps, taxBps);
        uint256 net = grossEth - f.total;
        used = grossEth;

        uint256 remaining = graduationThreshold - realEthRaised;
        bool hitsThreshold = net >= remaining;
        if (hitsThreshold) {
            uint256 cappedGross = FeeMath.grossForNet(remaining, PLATFORM_FEE_BPS + creatorFeeBps + taxBps);
            if (cappedGross < grossEth) {
                used = cappedGross;
                f = FeeMath.split(cappedGross, creatorFeeBps, taxBps);
                net = cappedGross - f.total;
            }
        }

        tokensOut = BondingCurveMath.tokensOutForEthIn(ethReserve(), tokenReserve(), net);

        if (isPublic && antiSniperCapBlocks > 0 && block.number < tradingStartBlock + antiSniperCapBlocks) {
            uint256 cap = (totalSupply * antiSniperCapBps) / FeeMath.BPS;
            uint256 wouldHold = walletBought[buyer] + tokensOut;
            if (wouldHold > cap) revert WalletCapExceeded(wouldHold, cap);
            walletBought[buyer] = wouldHold;
        }

        realEthRaised += net;
        tokensSold += tokensOut;
        platformFeesAccrued += f.platform;
        creatorFeesAccrued += f.creator;
        if (f.tax > 0) {
            sniperTaxAccrued += f.tax;
            emit SniperTaxCollected(buyer, f.tax);
        }
        emit Bought(buyer, used, tokensOut, f.platform, f.creator, spotPrice());

        IERC20(token).safeTransfer(buyer, tokensOut);
    }

    // ================================================================== graduation

    /// @dev Moves all curve ETH (+ anti-sniper surplus) and a price-matched amount of tokens into a full-range
    ///      Uniswap V4 position owned by the hook forever. Remaining tokens are burned.
    ///      LP tokens are sized at the final curve spot price so there is no price discontinuity at migration.
    function _graduate() internal {
        uint256 ethR = ethReserve();
        uint256 tokR = tokenReserve();
        uint256 lpEth = realEthRaised + sniperTaxAccrued;
        uint256 available = curveSupply - tokensSold + (totalSupply - curveSupply);
        uint256 lpTokens = Math.mulDiv(lpEth, tokR, ethR);
        if (lpTokens > available) lpTokens = available;
        uint256 toBurn = available - lpTokens;

        // The pool id is deterministic (ETH/token, fixed fee/spacing, this hook) -> recorded before any interaction.
        PoolId id = IPolydashHook(hook).computePoolId(token);

        // effects
        phase = Phase.Graduated;
        sniperTaxAccrued = 0;
        graduationEth = lpEth;
        graduationTokens = lpTokens;
        graduatedAt = block.timestamp;
        poolId = id;
        emit Graduated(token, lpEth, lpTokens, toBurn, id, block.timestamp);

        // interactions (token and hook are trusted, immutable-per-launch contracts)
        if (toBurn > 0) PolydashToken(token).burn(toBurn);
        IERC20(token).safeTransfer(hook, lpTokens);
        // slither-disable-next-line arbitrary-send-eth
        (PoolId deployed, uint128 liquidity) = IPolydashHook(hook).deployGraduatedPool{value: lpEth}(
            lpTokens, creatorFeeBps, sellSpikeBps, sellSpikeDuration
        );
        // slither-disable-next-line incorrect-equality
        if (PoolId.unwrap(deployed) != PoolId.unwrap(id) || liquidity == 0) revert InvalidParams();
    }

    // ================================================================== creator fees

    /// @notice Pays ALL accrued creator fees (bonding curve, and post-graduation hook fees) to
    ///         `creatorPayoutWallet`. Anyone may call; the destination can never be anything else.
    function claimCreatorFees() external nonReentrant returns (uint256 amount) {
        amount = creatorFeesAccrued;
        address wallet = creatorPayoutWallet;
        if (amount > 0) {
            creatorFeesAccrued = 0;
            emit CreatorFeesClaimed(wallet, amount);
            _sendEth(wallet, amount);
        }
        if (phase == Phase.Graduated) {
            amount += IPolydashHook(hook).claimCreatorFees(poolId);
        }
        if (amount == 0) revert NothingToClaim();
    }

    /// @notice Creator starts a 48h timelocked change of the payout wallet. Overwrites any pending change.
    function initiatePayoutWalletChange(address newWallet) external nonReentrant {
        if (msg.sender != creator) revert OnlyCreator();
        if (newWallet == address(0)) revert InvalidParams();
        pendingPayoutWallet = newWallet;
        payoutWalletChangeAt = block.timestamp + PAYOUT_WALLET_DELAY;
        emit PayoutWalletChangeInitiated(creatorPayoutWallet, newWallet, payoutWalletChangeAt);
    }

    /// @notice Cancel a pending change. Callable by the creator OR the current payout wallet, so the payout
    ///         wallet owner can veto a change made with a compromised creator key.
    function cancelPayoutWalletChange() external nonReentrant {
        if (msg.sender != creator && msg.sender != creatorPayoutWallet) revert OnlyCreator();
        address pending = pendingPayoutWallet;
        if (pending == address(0)) revert NoPendingChange();
        pendingPayoutWallet = address(0);
        payoutWalletChangeAt = 0;
        emit PayoutWalletChangeCancelled(pending, msg.sender);
    }

    /// @notice Execute a pending change after the 48h delay. Callable by anyone. Fees accrued up to this point
    ///         are first paid to the OLD wallet (best effort - if the old wallet rejects ETH they roll over).
    function executePayoutWalletChange() external nonReentrant {
        address newWallet = pendingPayoutWallet;
        if (newWallet == address(0)) revert NoPendingChange();
        if (block.timestamp < payoutWalletChangeAt) revert TooEarly();
        address oldWallet = creatorPayoutWallet;
        uint256 owed = creatorFeesAccrued;

        // effects first (every state-changing entry point of this contract is nonReentrant as well)
        creatorFeesAccrued = 0;
        pendingPayoutWallet = address(0);
        payoutWalletChangeAt = 0;

        // post-graduation fees accrued so far are paid by the hook to the CURRENT (old) wallet. The hook is trusted
        // and any re-entry from the receiving wallet hits this contract's nonReentrant lock.
        if (phase == Phase.Graduated) {
            // slither-disable-next-line unused-return,reentrancy-no-eth
            try IPolydashHook(hook).claimCreatorFees(poolId) returns (uint256) {} catch {}
        }
        creatorPayoutWallet = newWallet;
        emit PayoutWalletChanged(oldWallet, newWallet);

        // curve fees accrued so far go to the old wallet; if it rejects ETH they roll over to the new one
        if (owed > 0) {
            (bool ok,) = oldWallet.call{value: owed}("");
            if (ok) emit CreatorFeesClaimed(oldWallet, owed);
            // slither-disable-next-line reentrancy-eth
            else creatorFeesAccrued += owed; // rollover; every writer of creatorFeesAccrued is nonReentrant
        }
    }

    // ================================================================== platform fees / refunds

    /// @notice Sends accrued platform fees to the factory, which forwards them to the platform fee wallet
    ///         (and optionally the buyback router). Only the factory can call this.
    function collectPlatformFees() external nonReentrant onlyFactory returns (uint256 amount) {
        amount = platformFeesAccrued;
        if (amount == 0) return 0;
        platformFeesAccrued = 0;
        emit PlatformFeesCollected(amount);
        _sendEth(factory, amount);
    }

    function claimRefund() external nonReentrant returns (uint256 amount) {
        amount = refunds[msg.sender];
        if (amount == 0) revert NothingToClaim();
        refunds[msg.sender] = 0;
        totalRefunds -= amount;
        emit RefundClaimed(msg.sender, amount);
        _sendEth(msg.sender, amount);
    }

    function _creditRefund(address user, uint256 amount) internal {
        refunds[user] += amount;
        totalRefunds += amount;
        emit RefundCredited(user, amount);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    // ================================================================== views

    function ethReserve() public view returns (uint256) {
        return virtualEth + realEthRaised;
    }

    function tokenReserve() public view returns (uint256) {
        return curveSupply - tokensSold;
    }

    function spotPrice() public view returns (uint256) {
        return BondingCurveMath.spotPrice(ethReserve(), tokenReserve());
    }

    function graduated() external view returns (bool) {
        return phase == Phase.Graduated;
    }

    function committersLength() external view returns (uint256) {
        return committers.length;
    }

    /// @notice Current anti-sniper surplus (bps) on top of platform + creator fee. Linearly decays from
    ///         (antiSniperFeeBps - creatorFeeBps) to 0 over `antiSniperFeeDuration` seconds after trading opens.
    function currentSniperSurplusBps() public view returns (uint256) {
        if (phase != Phase.Trading || antiSniperFeeDuration == 0) return 0;
        uint256 elapsed = block.timestamp - tradingStartTime;
        if (elapsed >= antiSniperFeeDuration) return 0;
        uint256 high = (antiSniperFeeBps * (antiSniperFeeDuration - elapsed)) / antiSniperFeeDuration;
        return high > creatorFeeBps ? high - creatorFeeBps : 0;
    }

    /// @notice Total fee (bps) a public buy pays right now.
    function currentBuyFeeBps() external view returns (uint256) {
        return PLATFORM_FEE_BPS + creatorFeeBps + currentSniperSurplusBps();
    }

    /// @notice Quote a public buy (ignores the threshold cap).
    function quoteBuy(uint256 ethIn) external view returns (uint256 tokensOut, FeeMath.Fees memory fees) {
        fees = FeeMath.split(ethIn, creatorFeeBps, currentSniperSurplusBps());
        tokensOut = BondingCurveMath.tokensOutForEthIn(ethReserve(), tokenReserve(), ethIn - fees.total);
    }

    function quoteSell(uint256 tokensIn) external view returns (uint256 ethOut, FeeMath.Fees memory fees) {
        uint256 gross = BondingCurveMath.ethOutForTokensIn(ethReserve(), tokenReserve(), tokensIn);
        fees = FeeMath.split(gross, creatorFeeBps, 0);
        ethOut = gross - fees.total;
    }
}
