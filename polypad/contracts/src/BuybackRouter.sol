// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IPolydashFactory, IBuybackRouter} from "./interfaces/IPolydash.sol";

/// @notice Subset of Uniswap SwapRouter02 (IV3SwapRouter) used here.
interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Subset of a Uniswap V3 pool used for the TWAP oracle.
interface IUniswapV3PoolOracle {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}

/// @title BuybackRouter
/// @notice Receives a share of Polydash platform fees (ETH), buys $POLYDASH on Uniswap V3 and sends it to
///         the Trading Rewards pool configured on the factory. Minimum output is derived from a TWAP
///         (not the manipulable spot price) minus `maxSlippageBps`.
contract BuybackRouter is IBuybackRouter, Ownable2Step, ReentrancyGuard {
    /// @notice $POLYDASH on Robinhood Chain.
    address public constant POLYDASH_MAINNET = 0x319525528f42167eF7fC18b77b889958080568e4;
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;

    address public immutable factory;
    address public immutable swapRouter;
    address public immutable weth;
    address public immutable polydash;

    address public v3Pool;
    uint24 public poolFee;
    uint32 public twapWindow = 30 minutes;
    uint256 public maxSlippageBps = 200;

    event BuybackExecuted(uint256 ethIn, uint256 polydashOut, address indexed rewardsPool);
    event MaxSlippageSet(uint256 bps);
    event TwapWindowSet(uint32 window);
    event PoolSet(address indexed pool, uint24 fee);

    error InvalidParams();
    error NoRewardsPool();
    error ZeroAmount();

    constructor(
        address initialOwner,
        address _factory,
        address _swapRouter,
        address _weth,
        address _polydash,
        address _v3Pool,
        uint24 _poolFee
    ) Ownable(initialOwner) {
        if (
            _factory == address(0) || _swapRouter == address(0) || _weth == address(0) || _polydash == address(0)
                || _v3Pool == address(0)
        ) {
            revert InvalidParams();
        }
        factory = _factory;
        swapRouter = _swapRouter;
        weth = _weth;
        polydash = _polydash;
        v3Pool = _v3Pool;
        poolFee = _poolFee;
    }

    /// @notice Swap all ETH sent for $POLYDASH, delivered straight to the Trading Rewards pool.
    function buyback() external payable override nonReentrant returns (uint256 polydashOut) {
        if (msg.value == 0) revert ZeroAmount();
        address rewardsPool = IPolydashFactory(factory).tradingRewardsPool();
        if (rewardsPool == address(0)) revert NoRewardsPool();
        uint256 minOut = (quoteTwap(msg.value) * (10_000 - maxSlippageBps)) / 10_000;
        polydashOut = ISwapRouter02(swapRouter).exactInputSingle{value: msg.value}(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: polydash,
                fee: poolFee,
                recipient: rewardsPool,
                amountIn: msg.value,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );
        emit BuybackExecuted(msg.value, polydashOut, rewardsPool);
    }

    /// @notice Expected $POLYDASH out for `ethIn` at the `twapWindow` time-weighted average tick.
    function quoteTwap(uint256 ethIn) public view returns (uint256) {
        uint32[] memory ago = new uint32[](2);
        ago[0] = twapWindow;
        // only tick cumulatives are needed; seconds-per-liquidity is irrelevant for a price TWAP
        // slither-disable-next-line unused-return
        (int56[] memory cumulatives,) = IUniswapV3PoolOracle(v3Pool).observe(ago);
        int56 delta = cumulatives[1] - cumulatives[0];
        int24 tick = int24(delta / int56(uint56(twapWindow)));
        if (delta < 0 && (delta % int56(uint56(twapWindow)) != 0)) tick--; // round toward negative infinity
        return quoteAtTick(tick, ethIn);
    }

    /// @notice Converts `ethIn` WETH to $POLYDASH at a given V3 tick (price = 1.0001^tick of token1/token0).
    function quoteAtTick(int24 tick, uint256 ethIn) public view returns (uint256) {
        uint256 sqrtP = TickMath.getSqrtPriceAtTick(tick);
        bool wethIsToken0 = weth < polydash;
        if (sqrtP <= type(uint128).max) {
            uint256 ratioX192 = sqrtP * sqrtP;
            return wethIsToken0 ? Math.mulDiv(ratioX192, ethIn, 1 << 192) : Math.mulDiv(1 << 192, ethIn, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtP, sqrtP, 1 << 64);
        return wethIsToken0 ? Math.mulDiv(ratioX128, ethIn, 1 << 128) : Math.mulDiv(1 << 128, ethIn, ratioX128);
    }

    function setMaxSlippageBps(uint256 bps) external onlyOwner {
        if (bps > MAX_SLIPPAGE_BPS) revert InvalidParams();
        maxSlippageBps = bps;
        emit MaxSlippageSet(bps);
    }

    function setTwapWindow(uint32 window) external onlyOwner {
        if (window < 60 || window > 1 days) revert InvalidParams();
        twapWindow = window;
        emit TwapWindowSet(window);
    }

    function setPool(address pool, uint24 fee) external onlyOwner {
        if (pool == address(0)) revert InvalidParams();
        v3Pool = pool;
        poolFee = fee;
        emit PoolSet(pool, fee);
    }
}
