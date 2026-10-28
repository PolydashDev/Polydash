// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {PolydashToken} from "./PolydashToken.sol";
import {PolydashLaunch} from "./PolydashLaunch.sol";
import {BondingCurveMath} from "./libraries/BondingCurveMath.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {IPolydashHook, IPolydashLaunch, IBuybackRouter} from "./interfaces/IPolydash.sol";

/// @title PolydashFactory
/// @notice Deploys Polydash launches (EIP-1167 clones of PolydashLaunch + a fresh PolydashToken) and holds
///         global configuration. The owner should be a multisig (Ownable2Step).
///
///         The owner can NOT: change the 0.2% platform fee, touch creator fees, change a live launch's
///         parameters, or remove graduated liquidity. See docs/OWNER_CAPABILITIES.md.
///
/// Integration constants (not used on-chain yet):
///   $POLYDASH token       0x319525528f42167ef7fc18b77b889958080568e4 (Robinhood Chain)
///   Staking V2 Factory    0x904b8F5d95B593b5F4a6Dbb116b58e1d5CBe93f0 (Robinhood Chain)
contract PolydashFactory is Ownable2Step, ReentrancyGuard {
    // ------------------------------------------------------------------ constants
    /// @notice Platform fee, 0.2% of volume. Hard-coded: there is no setter in any contract.
    uint256 public constant PLATFORM_FEE_BPS = FeeMath.PLATFORM_FEE_BPS;
    uint256 public constant MAX_CREATOR_FEE_BPS = FeeMath.MAX_CREATOR_FEE_BPS;
    uint256 public constant DEFAULT_CREATOR_FEE_BPS = 100;
    uint256 public constant FEE_WALLET_DELAY = 48 hours;
    uint256 public constant CURVE_SUPPLY_BPS = 8_000; // 80% on the curve, 20% LP reserve

    uint256 public constant DEFAULT_TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant MIN_TOTAL_SUPPLY = 1_000_000 ether;
    uint256 public constant MAX_TOTAL_SUPPLY = 1_000_000_000_000 ether;
    uint256 public constant DEFAULT_VIRTUAL_ETH = 1.5 ether;
    uint256 public constant MIN_VIRTUAL_ETH = 0.01 ether;
    uint256 public constant MAX_VIRTUAL_ETH = 1_000 ether;
    uint256 public constant MIN_GRADUATION_ETH = 0.1 ether;
    uint256 public constant MAX_GRADUATION_ETH = 10_000 ether;
    uint256 public constant MAX_LAUNCH_DELAY = 30 days;
    uint256 public constant MAX_SOCIAL_LINKS = 10;

    uint256 public constant MAX_ANTI_SNIPER_FEE_BPS = 2_000;
    uint256 public constant MAX_ANTI_SNIPER_FEE_DURATION = 1 hours;
    uint256 public constant MAX_ANTI_SNIPER_CAP_BLOCKS = 100;
    uint256 public constant MAX_SELL_SPIKE_BPS = 1_000;
    uint256 public constant MAX_SELL_SPIKE_DURATION = 1 hours;

    address public constant POLYDASH_TOKEN = 0x319525528f42167eF7fC18b77b889958080568e4;
    address public constant STAKING_V2_FACTORY = 0x904b8F5d95B593b5F4a6Dbb116b58e1d5CBe93f0;

    enum GraduationMode {
        EthRaised,
        MarketCap
    }

    struct LaunchParams {
        string name;
        string symbol;
        string imageUri;
        string description;
        string[] socialLinks;
        uint256 creatorFeeBps; // 0..200, literal (0 means 0%). UIs should default to DEFAULT_CREATOR_FEE_BPS.
        address creatorPayoutWallet; // 0 => msg.sender
        uint256 devBuyEth; // must equal msg.value
        uint256 totalSupply; // 0 => DEFAULT_TOTAL_SUPPLY
        uint256 virtualEthReserve; // 0 => DEFAULT_VIRTUAL_ETH
        uint256 launchDelay; // seconds of pre-launch commitment window; 0 => live immediately
    }

    // ------------------------------------------------------------------ state
    address public immutable launchImplementation;
    address public hook;
    mapping(address => bool) public isHook;

    address public platformFeeWallet;
    address public pendingFeeWallet;
    uint256 public feeWalletChangeAt;

    GraduationMode public graduationMode;
    uint256 public graduationEthTarget = 15 ether;
    uint256 public graduationMarketCapTarget = 150 ether;

    uint256 public antiSniperHighFeeBps = 1_000;
    uint256 public antiSniperFeeDuration = 5 minutes;
    uint256 public antiSniperBlocks = 5;
    uint256 public antiSniperCapBps = 100;

    uint256 public postGraduationSellFeeBps;
    uint256 public postGraduationSellFeeDuration;

    bool public buybackEnabled;
    uint256 public buybackBps;
    address public buybackContract;
    address public tradingRewardsPool;

    address[] public allLaunches;
    mapping(address => bool) public isLaunch;
    mapping(address token => address launch) public launchOfToken;

    // ------------------------------------------------------------------ events
    event LaunchCreated(
        address indexed launch,
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string imageUri,
        uint256 creatorFeeBps,
        address creatorPayoutWallet
    );
    event LaunchConfigured(
        address indexed launch,
        uint256 devBuyEth,
        uint256 totalSupply,
        uint256 virtualEth,
        uint256 graduationThreshold,
        uint256 launchTime
    );
    event FeeWalletChangeInitiated(address indexed oldWallet, address indexed newWallet, uint256 executeAt);
    event FeeWalletChangeCancelled(address indexed cancelledWallet);
    event FeeWalletChanged(address indexed oldWallet, address indexed newWallet);
    event HookSet(address indexed hook);
    event GraduationTargetSet(GraduationMode mode, uint256 value);
    event AntiSniperConfigSet(uint256 highFeeBps, uint256 feeDuration, uint256 capBlocks, uint256 capBps);
    event PostGraduationSellSpikeSet(uint256 bps, uint256 duration);
    event BuybackConfigSet(bool enabled, uint256 bps, address indexed buybackContract);
    event TradingRewardsPoolSet(address indexed pool);
    event PlatformFeesDistributed(address indexed launch, uint256 total, uint256 toWallet, uint256 toBuyback);
    event BuybackFailed(uint256 amount);

    // ------------------------------------------------------------------ errors
    error InvalidParams();
    error HookNotSet();
    error NotLaunch();
    error NoPendingChange();
    error TooEarly();
    error EthTransferFailed();
    error UnexpectedEth();

    constructor(address initialOwner, address _launchImplementation, address _platformFeeWallet)
        Ownable(initialOwner)
    {
        if (_launchImplementation == address(0) || _platformFeeWallet == address(0)) revert InvalidParams();
        launchImplementation = _launchImplementation;
        platformFeeWallet = _platformFeeWallet;
    }

    /// @dev Accepts ETH only from launches and hooks (fee collection).
    receive() external payable {
        if (!isLaunch[msg.sender] && !isHook[msg.sender]) revert UnexpectedEth();
    }

    // ================================================================== launches

    function createLaunch(LaunchParams calldata p) external payable nonReentrant returns (address launch, address token) {
        if (hook == address(0)) revert HookNotSet();
        if (
            bytes(p.name).length == 0 || bytes(p.symbol).length == 0 || p.creatorFeeBps > MAX_CREATOR_FEE_BPS
                || p.socialLinks.length > MAX_SOCIAL_LINKS || msg.value != p.devBuyEth || p.launchDelay > MAX_LAUNCH_DELAY
        ) revert InvalidParams();

        PolydashLaunch.InitParams memory ip = _buildInitParams(p);
        launch = Clones.clone(launchImplementation);
        token = _deployToken(p, ip.totalSupply, launch);
        ip.token = token;
        isLaunch[launch] = true;
        launchOfToken[token] = launch;
        allLaunches.push(launch);

        emit LaunchCreated(launch, token, msg.sender, p.name, p.symbol, p.imageUri, p.creatorFeeBps, ip.creatorPayoutWallet);
        emit LaunchConfigured(launch, ip.devBuyEth, ip.totalSupply, ip.virtualEth, ip.graduationThreshold, ip.launchTime);

        PolydashLaunch(payable(launch)).initialize{value: msg.value}(ip);
        if (p.launchDelay == 0) PolydashLaunch(payable(launch)).goLive();
    }

    function _buildInitParams(LaunchParams calldata p) internal view returns (PolydashLaunch.InitParams memory ip) {
        uint256 supply = p.totalSupply == 0 ? DEFAULT_TOTAL_SUPPLY : p.totalSupply;
        uint256 vEth = p.virtualEthReserve == 0 ? DEFAULT_VIRTUAL_ETH : p.virtualEthReserve;
        if (supply < MIN_TOTAL_SUPPLY || supply > MAX_TOTAL_SUPPLY || vEth < MIN_VIRTUAL_ETH || vEth > MAX_VIRTUAL_ETH) {
            revert InvalidParams();
        }
        uint256 curveSupply = (supply * CURVE_SUPPLY_BPS) / FeeMath.BPS;
        ip.creator = msg.sender;
        ip.creatorPayoutWallet = p.creatorPayoutWallet == address(0) ? msg.sender : p.creatorPayoutWallet;
        ip.hook = hook;
        ip.creatorFeeBps = p.creatorFeeBps;
        ip.totalSupply = supply;
        ip.curveSupply = curveSupply;
        ip.virtualEth = vEth;
        ip.graduationThreshold = _graduationThreshold(vEth, curveSupply, supply);
        ip.devBuyEth = p.devBuyEth;
        ip.launchTime = block.timestamp + p.launchDelay;
        ip.antiSniperFeeBps = antiSniperHighFeeBps;
        ip.antiSniperFeeDuration = antiSniperFeeDuration;
        ip.antiSniperCapBlocks = antiSniperBlocks;
        ip.antiSniperCapBps = antiSniperCapBps;
        ip.sellSpikeBps = postGraduationSellFeeBps;
        ip.sellSpikeDuration = postGraduationSellFeeDuration;
    }

    function _deployToken(LaunchParams calldata p, uint256 supply, address launch) internal returns (address) {
        return address(new PolydashToken(p.name, p.symbol, supply, launch, p.imageUri, p.description, p.socialLinks));
    }

    function _graduationThreshold(uint256 vEth, uint256 curveSupply, uint256 supply) internal view returns (uint256) {
        if (graduationMode == GraduationMode.EthRaised) return graduationEthTarget;
        uint256 targetReserve =
            BondingCurveMath.ethReserveForMarketCap(graduationMarketCapTarget, vEth * curveSupply, supply);
        if (targetReserve <= vEth + MIN_GRADUATION_ETH) revert InvalidParams();
        return targetReserve - vEth;
    }

    /// @notice Preview the graduation threshold (ETH raised) a launch with these parameters would get.
    function previewGraduationThreshold(uint256 totalSupply_, uint256 virtualEth_) external view returns (uint256) {
        uint256 supply = totalSupply_ == 0 ? DEFAULT_TOTAL_SUPPLY : totalSupply_;
        uint256 vEth = virtualEth_ == 0 ? DEFAULT_VIRTUAL_ETH : virtualEth_;
        return _graduationThreshold(vEth, (supply * CURVE_SUPPLY_BPS) / FeeMath.BPS, supply);
    }

    function allLaunchesLength() external view returns (uint256) {
        return allLaunches.length;
    }

    // ================================================================== platform fees

    /// @notice Pull accrued platform fees from a launch (curve + post-graduation hook) and forward them to the
    ///         platform fee wallet (minus the optional buyback share). Permissionless: funds can only go to
    ///         the configured destinations.
    function collectPlatformFees(address launch) public nonReentrant returns (uint256 total) {
        if (!isLaunch[launch]) revert NotLaunch();
        // calls go only to factory-deployed launches and their hook (isLaunch checked above)
        // slither-disable-next-line calls-loop
        total = IPolydashLaunch(launch).collectPlatformFees();
        // slither-disable-next-line calls-loop
        if (IPolydashLaunch(launch).graduated()) {
            // slither-disable-next-line calls-loop
            total += IPolydashHook(IPolydashLaunch(launch).hook()).collectPlatformFees(launch);
        }
        if (total == 0) return 0;

        uint256 toBuyback = 0;
        if (buybackEnabled && buybackBps > 0) {
            toBuyback = (total * buybackBps) / FeeMath.BPS;
            if (toBuyback > 0) {
                // owner-configured router; a failing buyback never blocks fee collection
                // slither-disable-next-line arbitrary-send-eth,unused-return,calls-loop
                try IBuybackRouter(buybackContract).buyback{value: toBuyback}() {}
                catch {
                    emit BuybackFailed(toBuyback);
                    toBuyback = 0;
                }
            }
        }
        uint256 toWallet = total - toBuyback;
        emit PlatformFeesDistributed(launch, total, toWallet, toBuyback);
        if (toWallet > 0) {
            // destination is the 48h-timelocked platform fee wallet, never caller-controlled
            // slither-disable-next-line arbitrary-send-eth,calls-loop
            (bool ok,) = platformFeeWallet.call{value: toWallet}("");
            if (!ok) revert EthTransferFailed();
        }
    }

    function collectPlatformFeesMany(address[] calldata launches) external returns (uint256 total) {
        for (uint256 i; i < launches.length; ++i) {
            total += collectPlatformFees(launches[i]);
        }
    }

    // ================================================================== fee wallet timelock (48h)

    function initiateFeeWalletChange(address newWallet) external onlyOwner {
        if (newWallet == address(0)) revert InvalidParams();
        pendingFeeWallet = newWallet;
        feeWalletChangeAt = block.timestamp + FEE_WALLET_DELAY;
        emit FeeWalletChangeInitiated(platformFeeWallet, newWallet, feeWalletChangeAt);
    }

    function executeFeeWalletChange() external onlyOwner {
        address newWallet = pendingFeeWallet;
        if (newWallet == address(0)) revert NoPendingChange();
        if (block.timestamp < feeWalletChangeAt) revert TooEarly();
        address old = platformFeeWallet;
        platformFeeWallet = newWallet;
        pendingFeeWallet = address(0);
        feeWalletChangeAt = 0;
        emit FeeWalletChanged(old, newWallet);
    }

    function cancelFeeWalletChange() external onlyOwner {
        address pending = pendingFeeWallet;
        if (pending == address(0)) revert NoPendingChange();
        pendingFeeWallet = address(0);
        feeWalletChangeAt = 0;
        emit FeeWalletChangeCancelled(pending);
    }

    // ================================================================== owner configuration (future launches only)

    /// @notice Sets the hook used by FUTURE launches. Existing launches keep the hook they were created with.
    function setHook(address newHook) external onlyOwner {
        if (newHook == address(0) || IPolydashHook(newHook).factory() != address(this)) revert InvalidParams();
        hook = newHook;
        isHook[newHook] = true;
        emit HookSet(newHook);
    }

    function setGraduationTarget(GraduationMode mode, uint256 value) external onlyOwner {
        if (mode == GraduationMode.EthRaised) {
            if (value < MIN_GRADUATION_ETH || value > MAX_GRADUATION_ETH) revert InvalidParams();
            graduationEthTarget = value;
        } else {
            if (value == 0 || value > 10_000_000 ether) revert InvalidParams();
            graduationMarketCapTarget = value;
        }
        graduationMode = mode;
        emit GraduationTargetSet(mode, value);
    }

    function setAntiSniperConfig(uint256 highFeeBps, uint256 feeDuration, uint256 capBlocks, uint256 capBps)
        external
        onlyOwner
    {
        if (
            highFeeBps > MAX_ANTI_SNIPER_FEE_BPS || feeDuration > MAX_ANTI_SNIPER_FEE_DURATION
                || capBlocks > MAX_ANTI_SNIPER_CAP_BLOCKS || capBps == 0 || capBps > FeeMath.BPS
        ) revert InvalidParams();
        antiSniperHighFeeBps = highFeeBps;
        antiSniperFeeDuration = feeDuration;
        antiSniperBlocks = capBlocks;
        antiSniperCapBps = capBps;
        emit AntiSniperConfigSet(highFeeBps, feeDuration, capBlocks, capBps);
    }

    function setPostGraduationSellSpike(uint256 bps, uint256 duration) external onlyOwner {
        if (bps > MAX_SELL_SPIKE_BPS || duration > MAX_SELL_SPIKE_DURATION) revert InvalidParams();
        postGraduationSellFeeBps = bps;
        postGraduationSellFeeDuration = duration;
        emit PostGraduationSellSpikeSet(bps, duration);
    }

    function setBuybackConfig(bool enabled, uint256 bps, address router) external onlyOwner {
        if (bps > FeeMath.BPS || (enabled && router == address(0))) revert InvalidParams();
        buybackEnabled = enabled;
        buybackBps = bps;
        buybackContract = router;
        emit BuybackConfigSet(enabled, bps, router);
    }

    /// @dev address(0) is intentionally allowed: it disables buyback routing (BuybackRouter reverts NoRewardsPool).
    // slither-disable-next-line missing-zero-check
    function setTradingRewardsPool(address pool) external onlyOwner {
        tradingRewardsPool = pool;
        emit TradingRewardsPoolSet(pool);
    }
}
