// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {FeeMath} from "./libraries/FeeMath.sol";
import {HookPermissions} from "./libraries/HookPermissions.sol";
import {IPolydashFactory, IPolydashLaunch} from "./interfaces/IPolydash.sol";

/// @title PolydashHook
/// @notice Uniswap V4 hook for graduated Polydash tokens.
///         1. Creates the ETH/token pool and adds full-range liquidity that is owned by this contract FOREVER.
///            There is no code path that removes liquidity (no negative modifyLiquidity call exists).
///         2. Charges the 0.2% platform fee + the creator fee on every swap, always in ETH:
///              - ETH is the specified currency (exact-in buy / exact-out sell)  -> beforeSwap
///              - ETH is the unspecified currency (exact-in sell / exact-out buy) -> afterSwap
///            No fee is ever taken in the launched token.
///         3. Blocks anyone else from initialising pools that use this hook (beforeInitialize always reverts;
///            V4 skips that callback when the hook itself initialises).
contract PolydashHook is IHooks, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;

    uint256 public constant PLATFORM_FEE_BPS = FeeMath.PLATFORM_FEE_BPS;
    int24 public constant TICK_SPACING = 200;
    uint24 public constant LP_FEE = 0;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;
    address public immutable factory;

    struct PoolConfig {
        address launchAddress;
        address token;
        uint24 platformFeeBps; // always 20
        uint24 creatorFeeBps;
        uint24 sellSpikeBps;
        uint64 sellSpikeEnd;
        uint128 liquidity;
        uint256 platformFeesAccrued;
        uint256 creatorFeesAccrued;
        bool active;
    }

    mapping(PoolId => PoolConfig) public pools;
    mapping(address launch => PoolId) public poolIdOf;

    bool private _deploying;

    event PoolGraduated(
        PoolId indexed id, address indexed launch, address indexed token, uint256 ethLiquidity, uint256 tokenLiquidity, uint128 liquidity
    );
    event SwapFeesCollected(
        PoolId indexed id, bool isBuy, uint256 grossEth, uint256 platformFee, uint256 creatorFee, uint256 sellSpikeFee
    );
    event CreatorFeesClaimed(PoolId indexed id, address indexed payoutWallet, uint256 amount);
    event PlatformFeesCollected(PoolId indexed id, uint256 amount);

    error OnlyPoolManager();
    error OnlyFactory();
    error NotLaunch();
    error AlreadyGraduated();
    error UnknownPool();
    error HookNotImplemented();
    error ExternalInitNotAllowed();
    error InsufficientTokens();
    error InvalidPrice();
    error EthTransferFailed();
    error InvalidParams();

    constructor(IPoolManager _poolManager, address _factory) {
        if (address(_poolManager) == address(0) || _factory == address(0)) revert InvalidParams();
        poolManager = _poolManager;
        factory = _factory;
        Hooks.validateHookPermissions(IHooks(address(this)), HookPermissions.permissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    /// @dev Only the PoolManager sends ETH here (via `take`). Graduation ETH arrives through deployGraduatedPool.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
    }

    // ================================================================== graduation

    /// @notice Called by a PolydashLaunch during graduation. The launch has already transferred `tokenAmount`
    ///         tokens to this contract; msg.value is the ETH side.
    function deployGraduatedPool(uint256 tokenAmount, uint256 creatorFeeBps, uint256 sellSpikeBps, uint256 sellSpikeDuration)
        external
        payable
        nonReentrant
        returns (PoolId id, uint128 liquidity)
    {
        address launch = msg.sender;
        if (!IPolydashFactory(factory).isLaunch(launch)) revert NotLaunch();
        if (PoolId.unwrap(poolIdOf[launch]) != bytes32(0)) revert AlreadyGraduated();
        if (creatorFeeBps > FeeMath.MAX_CREATOR_FEE_BPS || sellSpikeBps > 1000) revert InvalidParams();
        address token = IPolydashLaunch(launch).token();
        if (IERC20(token).balanceOf(address(this)) < tokenAmount) revert InsufficientTokens();
        uint256 ethAmount = msg.value;
        if (ethAmount == 0 || tokenAmount == 0) revert InvalidParams();

        PoolKey memory key = _keyFor(token);
        id = key.toId();

        // price of currency0 (ETH) in currency1 (token): P = token/eth, sqrtPriceX96 = sqrt(P * 2^192)
        uint160 sqrtPriceX96 = Math.sqrt(Math.mulDiv(tokenAmount, 1 << 192, ethAmount)).toUint160();
        if (sqrtPriceX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceX96 >= TickMath.MAX_SQRT_PRICE) revert InvalidPrice();

        int24 tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            ethAmount,
            tokenAmount
        );

        // effects
        poolIdOf[launch] = id;
        pools[id] = PoolConfig({
            launchAddress: launch,
            token: token,
            platformFeeBps: uint24(PLATFORM_FEE_BPS),
            creatorFeeBps: uint24(creatorFeeBps),
            sellSpikeBps: uint24(sellSpikeBps),
            sellSpikeEnd: uint64(block.timestamp + sellSpikeDuration),
            liquidity: liquidity,
            platformFeesAccrued: 0,
            creatorFeesAccrued: 0,
            active: true
        });

        // interactions (PoolManager is the canonical, immutable Uniswap v4 singleton)
        // slither-disable-next-line unused-return
        poolManager.initialize(key, sqrtPriceX96);
        // `_deploying` is a guard that is only true for the duration of unlock() -> unlockCallback().
        // slither-disable-next-line reentrancy-benign
        _deploying = true;
        bytes memory res = poolManager.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
        // slither-disable-next-line write-after-write,reentrancy-benign
        _deploying = false;
        (uint256 ethUsed, uint256 tokensUsed) = abi.decode(res, (uint256, uint256));

        // rounding dust: burn leftover tokens, send leftover wei to the dead address (no one can recover it)
        if (tokenAmount > tokensUsed) ERC20Burnable(token).burn(tokenAmount - tokensUsed);
        if (ethAmount > ethUsed) {
            (bool ok,) = DEAD.call{value: ethAmount - ethUsed}("");
            if (!ok) revert EthTransferFailed();
        }
        emit PoolGraduated(id, launch, token, ethUsed, tokensUsed, liquidity);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only reachable during deployGraduatedPool. Adds liquidity with a POSITIVE delta only.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_deploying) revert InvalidParams();
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint128));
        // fee delta is always zero for a fresh position (LP_FEE = 0, nothing accrued yet)
        // slither-disable-next-line unused-return
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        uint256 ethOwed = uint256(uint128(-delta.amount0()));
        uint256 tokensOwed = uint256(uint128(-delta.amount1()));
        // settle() returns the amount paid, which by construction equals what we pass / transfer
        // slither-disable-next-line unused-return
        poolManager.settle{value: ethOwed}();
        poolManager.sync(key.currency1);
        IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(poolManager), tokensOwed);
        // slither-disable-next-line unused-return
        poolManager.settle();
        return abi.encode(ethOwed, tokensOwed);
    }

    // ================================================================== swap fees

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactIn = params.amountSpecified < 0;
        // specified currency is currency0 (ETH) iff exactIn == zeroForOne
        if (exactIn != params.zeroForOne) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        PoolId id = key.toId();
        PoolConfig storage c = _config(id);
        bool isBuy = params.zeroForOne;
        uint256 taxBps = isBuy ? 0 : _sellSpikeBps(c);
        uint256 amount = exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        // exact-in buy: fee comes out of the ETH paid. exact-out sell: pool releases (amount + fee), user gets amount.
        uint256 gross =
            exactIn ? amount : FeeMath.grossForNet(amount, PLATFORM_FEE_BPS + c.creatorFeeBps + taxBps);
        uint256 fee = _charge(key, id, c, isBuy, gross, taxBps);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt256().toInt128(), 0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyPoolManager returns (bytes4, int128) {
        bool exactIn = params.amountSpecified < 0;
        if (exactIn == params.zeroForOne) return (IHooks.afterSwap.selector, 0); // handled in beforeSwap
        PoolId id = key.toId();
        PoolConfig storage c = _config(id);
        bool isBuy = params.zeroForOne;
        int128 ethDelta = delta.amount0();
        uint256 gross;
        uint256 taxBps = 0;
        if (isBuy) {
            // exact-out buy: user pays ethIn to the pool; fee is charged on top so it equals bps of the total paid
            gross = FeeMath.grossForNet(uint256(uint128(-ethDelta)), PLATFORM_FEE_BPS + c.creatorFeeBps);
        } else {
            // exact-in sell: pool releases ethOut; fee is deducted from it
            taxBps = _sellSpikeBps(c);
            gross = uint256(uint128(ethDelta));
        }
        uint256 fee = _charge(key, id, c, isBuy, gross, taxBps);
        return (IHooks.afterSwap.selector, fee.toInt256().toInt128());
    }

    /// @dev Takes platform + creator fee in ETH from the PoolManager into this contract and donates the
    ///      optional sell-spike surplus to the (permanently locked) pool liquidity. The caller of the swap pays
    ///      exactly `total` because the hook returns it as its delta.
    function _charge(PoolKey calldata key, PoolId id, PoolConfig storage c, bool isBuy, uint256 gross, uint256 taxBps)
        internal
        returns (uint256 total)
    {
        FeeMath.Fees memory f = FeeMath.split(gross, c.creatorFeeBps, taxBps);
        total = f.total;
        if (total == 0) return 0;
        c.platformFeesAccrued += f.platform;
        c.creatorFeesAccrued += f.creator;
        uint256 toTake = f.platform + f.creator;
        emit SwapFeesCollected(id, isBuy, gross, f.platform, f.creator, f.tax);
        if (toTake > 0) poolManager.take(key.currency0, address(this), toTake);
        // slither-disable-next-line unused-return
        if (f.tax > 0) poolManager.donate(key, f.tax, 0, "");
    }

    function _config(PoolId id) internal view returns (PoolConfig storage c) {
        c = pools[id];
        if (!c.active) revert UnknownPool();
    }

    function _sellSpikeBps(PoolConfig storage c) internal view returns (uint256) {
        return block.timestamp < c.sellSpikeEnd ? c.sellSpikeBps : 0;
    }

    // ================================================================== claims

    /// @notice Pays all accrued post-graduation creator fees for `id` to the launch's current
    ///         creatorPayoutWallet. Anyone may call. No approval or signature involved.
    function claimCreatorFees(PoolId id) external nonReentrant returns (uint256 amount) {
        PoolConfig storage c = _config(id);
        amount = c.creatorFeesAccrued;
        if (amount == 0) return 0;
        c.creatorFeesAccrued = 0;
        address wallet = IPolydashLaunch(c.launchAddress).creatorPayoutWallet();
        emit CreatorFeesClaimed(id, wallet, amount);
        (bool ok,) = wallet.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @notice Sends accrued platform fees of a graduated launch to the factory. Factory only.
    function collectPlatformFees(address launch) external nonReentrant returns (uint256 amount) {
        if (msg.sender != factory) revert OnlyFactory();
        PoolId id = poolIdOf[launch];
        PoolConfig storage c = pools[id];
        if (!c.active) return 0;
        amount = c.platformFeesAccrued;
        if (amount == 0) return 0;
        c.platformFeesAccrued = 0;
        emit PlatformFeesCollected(id, amount);
        (bool ok,) = factory.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    // ================================================================== views

    /// @notice Liquidity permanently locked for the pool (recorded at graduation).
    function lockedLiquidity(PoolId id) external view returns (uint128) {
        return pools[id].liquidity;
    }

    /// @notice Live liquidity of the hook-owned position as reported by the PoolManager.
    function positionLiquidity(PoolId id) external view returns (uint128 liquidity) {
        // slither-disable-next-line unused-return
        (liquidity,,) = poolManager.getPositionInfo(
            id, address(this), TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), bytes32(0)
        );
    }

    function poolKeyOf(address launch) external view returns (PoolKey memory) {
        return _keyFor(pools[poolIdOf[launch]].token);
    }

    /// @notice Deterministic id of the graduation pool for `token` (ETH/token, LP_FEE, TICK_SPACING, this hook).
    function computePoolId(address token) external view returns (PoolId) {
        return _keyFor(token).toId();
    }

    function _keyFor(address token) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)), // native ETH always sorts first
            currency1: Currency.wrap(token),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    // ================================================================== unused / blocked callbacks

    /// @dev Always reverts: only this contract may create pools with this hook (self-initialisation skips it).
    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        revert ExternalInitNotAllowed();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
