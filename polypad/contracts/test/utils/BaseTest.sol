// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {PolydashFactory} from "../../src/PolydashFactory.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashToken} from "../../src/PolydashToken.sol";
import {PolydashHook} from "../../src/PolydashHook.sol";
import {HookPermissions} from "../../src/libraries/HookPermissions.sol";
import {MockV4PoolManager} from "../mocks/MockV4PoolManager.sol";

abstract contract BaseTest is Test {
    MockV4PoolManager internal manager;
    PolydashFactory internal factory;
    PolydashHook internal hook;
    PoolSwapTest internal swapRouter;

    address internal owner = makeAddr("owner");
    address internal feeWallet = makeAddr("feeWallet");
    address internal creator = makeAddr("creator");
    address internal payout = makeAddr("payout");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function setUp() public virtual {
        manager = new MockV4PoolManager(address(this));
        PolydashLaunch impl = new PolydashLaunch();
        factory = new PolydashFactory(owner, address(impl), feeWallet);

        address hookAddr = address(uint160(0x4444 << 144) | HookPermissions.FLAGS);
        deployCodeTo("PolydashHook.sol:PolydashHook", abi.encode(IPoolManager(address(manager)), address(factory)), hookAddr);
        hook = PolydashHook(payable(hookAddr));

        vm.prank(owner);
        factory.setHook(hookAddr);

        swapRouter = new PoolSwapTest(manager);

        vm.deal(creator, 1_000 ether);
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _disableAntiSniper() internal {
        vm.prank(owner);
        factory.setAntiSniperConfig(0, 0, 0, 10_000);
    }

    function _params(uint256 creatorFeeBps, uint256 devBuy, uint256 delay)
        internal
        view
        returns (PolydashFactory.LaunchParams memory p)
    {
        string[] memory socials = new string[](2);
        socials[0] = "https://x.com/polydash";
        socials[1] = "https://t.me/polydash";
        p = PolydashFactory.LaunchParams({
            name: "Test Token",
            symbol: "TEST",
            imageUri: "ipfs://image",
            description: "a test token",
            socialLinks: socials,
            creatorFeeBps: creatorFeeBps,
            creatorPayoutWallet: payout,
            devBuyEth: devBuy,
            totalSupply: 0,
            virtualEthReserve: 0,
            launchDelay: delay
        });
    }

    function _launch(uint256 creatorFeeBps) internal returns (PolydashLaunch l, PolydashToken t) {
        return _launchWith(_params(creatorFeeBps, 0, 0));
    }

    function _launchWith(PolydashFactory.LaunchParams memory p) internal returns (PolydashLaunch l, PolydashToken t) {
        vm.prank(creator);
        (address la, address ta) = factory.createLaunch{value: p.devBuyEth}(p);
        l = PolydashLaunch(payable(la));
        t = PolydashToken(ta);
    }

    function _buy(PolydashLaunch l, address who, uint256 eth) internal returns (uint256) {
        vm.prank(who);
        return l.buy{value: eth}(0);
    }

    function _sell(PolydashLaunch l, address who, uint256 amount) internal returns (uint256) {
        vm.startPrank(who);
        IERC20(l.token()).approve(address(l), amount);
        uint256 out = l.sell(amount, 0);
        vm.stopPrank();
        return out;
    }

    function _graduate(PolydashLaunch l) internal {
        uint256 amount = (l.graduationThreshold() - l.realEthRaised()) * 2;
        vm.prank(alice);
        l.buy{value: amount}(0);
        require(l.graduated(), "not graduated");
    }

    /// @dev Swap on the graduated V4 pool through the canonical v4-core test router.
    function _v4Swap(PolydashLaunch l, address who, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta)
    {
        PoolKey memory key = hook.poolKeyOf(address(l));
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.startPrank(who);
        IERC20(l.token()).approve(address(swapRouter), type(uint256).max);
        uint256 value = zeroForOne ? 100 ether : 0;
        delta = swapRouter.swap{value: value}(key, sp, ts, "");
        vm.stopPrank();
    }

    function _product(PolydashLaunch l) internal view returns (uint256) {
        return l.ethReserve() * l.tokenReserve();
    }
}
