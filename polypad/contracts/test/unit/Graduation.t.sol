// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashToken} from "../../src/PolydashToken.sol";
import {PolydashFactory} from "../../src/PolydashFactory.sol";
import {PolydashHook} from "../../src/PolydashHook.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";

contract GraduationTest is BaseTest {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    PolydashLaunch l;
    PolydashToken t;

    function setUp() public override {
        super.setUp();
        _disableAntiSniper();
        (l, t) = _launch(100);
    }

    function test_GraduatesInOneTxAndLocksLiquidity() public {
        uint256 supplyBefore = t.totalSupply();
        _graduate(l);
        assertEq(uint8(l.phase()), uint8(PolydashLaunch.Phase.Graduated));
        PoolId id = l.poolId();
        assertEq(PoolId.unwrap(id), PoolId.unwrap(hook.poolIdOf(address(l))));

        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(id);
        assertGt(sqrtP, 0, "pool initialised");

        uint128 locked = hook.lockedLiquidity(id);
        assertGt(locked, 0);
        assertEq(hook.positionLiquidity(id), locked, "hook owns the full position");
        assertEq(IPoolManager(address(manager)).getLiquidity(id), locked, "only liquidity in the pool");

        // launch keeps no ETH beyond fees, keeps no tokens
        assertEq(t.balanceOf(address(l)), 0);
        assertEq(address(l).balance, l.platformFeesAccrued() + l.creatorFeesAccrued() + l.totalRefunds());
        // tokens not used for LP were burned
        assertLt(t.totalSupply(), supplyBefore);
        assertEq(t.balanceOf(address(hook)), 0);
        assertGe(l.graduationEth(), l.graduationThreshold());
    }

    function test_PoolPriceMatchesFinalCurvePrice() public {
        _graduate(l);
        (uint160 sqrtP,,,) = IPoolManager(address(manager)).getSlot0(l.poolId());
        uint256 priceX96 = FullMath.mulDiv(sqrtP, sqrtP, 1 << 96);
        uint256 tokensPerEthPool = FullMath.mulDiv(priceX96, 1e18, 1 << 96);
        uint256 tokensPerEthCurve = l.tokenReserve() * 1e18 / l.ethReserve();
        assertApproxEqRel(tokensPerEthPool, tokensPerEthCurve, 1e12); // 0.0001%
    }

    function test_CurveDisabledAfterGraduation() public {
        _graduate(l);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PolydashLaunch.WrongPhase.selector, PolydashLaunch.Phase.Graduated));
        l.buy{value: 1 ether}(0);

        uint256 bal = t.balanceOf(alice);
        vm.startPrank(alice);
        t.approve(address(l), bal);
        vm.expectRevert(abi.encodeWithSelector(PolydashLaunch.WrongPhase.selector, PolydashLaunch.Phase.Graduated));
        l.sell(bal, 0);
        vm.stopPrank();
    }

    function test_ExternalPoolInitWithHookReverts() public {
        _graduate(l);
        PoolKey memory key = hook.poolKeyOf(address(l));
        key.tickSpacing = 60; // different pool, same hook
        vm.expectRevert();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));
    }

    function test_OnlyLaunchCanDeployPool() public {
        vm.deal(address(this), 1 ether);
        vm.expectRevert(PolydashHook.NotLaunch.selector);
        hook.deployGraduatedPool{value: 1 ether}(1e18, 100, 0, 0);
    }

    function test_UnlockCallbackNotCallableDirectly() public {
        vm.expectRevert(PolydashHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
    }

    function test_HookRejectsStrayEth() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_NoOneCanRemoveLockedLiquidity() public {
        _graduate(l);
        PoolKey memory key = hook.poolKeyOf(address(l));
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(manager);
        uint128 locked = hook.lockedLiquidity(l.poolId());
        // a third party has no position to withdraw from (position key includes owner = router)
        vm.expectRevert();
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(200),
                tickUpper: TickMath.maxUsableTick(200),
                liquidityDelta: -int256(uint256(locked)),
                salt: bytes32(0)
            }),
            ""
        );
        // the hook exposes no removal function; it is only reachable via unlockCallback which requires _deploying
        assertEq(hook.positionLiquidity(l.poolId()), locked);
    }

    // ------------------------------------------------------------------ V4 swap fees (always ETH)

    function test_V4ExactInBuyCharges20BpsInEth() public {
        _graduate(l);
        PoolId id = l.poolId();
        uint256 tokBefore = t.balanceOf(bob);
        BalanceDelta d = _v4Swap(l, bob, true, -1 ether);
        assertEq(d.amount0(), -1 ether, "user pays exactly 1 ETH incl. fees");
        assertGt(t.balanceOf(bob), tokBefore);
        (,,,,,, , uint256 plat, uint256 cre,) = hook.pools(id);
        assertEq(plat, 1 ether * 20 / 10_000);
        assertEq(cre, 1 ether * 100 / 10_000);
        assertEq(address(hook).balance, plat + cre);
        assertEq(t.balanceOf(address(hook)), 0, "hook never receives tokens as fees");
    }

    function test_V4ExactInSellCharges20BpsInEth() public {
        _graduate(l);
        uint256 amt = t.balanceOf(alice) / 10;
        uint256 ethBefore = alice.balance;
        BalanceDelta d = _v4Swap(l, alice, false, -int256(amt));
        uint256 received = alice.balance - ethBefore;
        assertEq(uint256(int256(d.amount0())), received);
        (,,,,,, , uint256 plat, uint256 cre,) = hook.pools(l.poolId());
        uint256 gross = received + plat + cre;
        assertEq(plat, gross * 20 / 10_000);
        assertEq(cre, gross * 100 / 10_000);
        assertEq(t.balanceOf(address(hook)), 0);
    }

    function test_V4ExactOutBuyCharges20BpsInEth() public {
        _graduate(l);
        int256 wantTokens = 1_000_000e18;
        uint256 before = t.balanceOf(bob);
        BalanceDelta d = _v4Swap(l, bob, true, wantTokens);
        assertEq(t.balanceOf(bob) - before, uint256(wantTokens));
        uint256 paid = uint256(-int256(d.amount0()));
        (,,,,,, , uint256 plat, uint256 cre,) = hook.pools(l.poolId());
        // fee is 1.2% of the total paid (rounding up in favour of fee by <= a few wei)
        assertApproxEqAbs(plat, paid * 20 / 10_000, 2);
        assertApproxEqAbs(cre, paid * 100 / 10_000, 2);
    }

    function test_V4ExactOutSellCharges20BpsInEth() public {
        _graduate(l);
        int256 wantEth = 0.5 ether;
        uint256 ethBefore = alice.balance;
        _v4Swap(l, alice, false, wantEth);
        assertEq(alice.balance - ethBefore, uint256(wantEth));
        (,,,,,, , uint256 plat, uint256 cre,) = hook.pools(l.poolId());
        uint256 gross = FeeMath.grossForNet(uint256(wantEth), 120);
        assertEq(plat, gross * 20 / 10_000);
        assertEq(cre, gross * 100 / 10_000);
    }

    function test_V4PlatformFeesFlowToFeeWalletViaFactory() public {
        _graduate(l);
        factory.collectPlatformFees(address(l)); // curve fees first
        uint256 before = feeWallet.balance;
        _v4Swap(l, bob, true, -2 ether);
        uint256 got = factory.collectPlatformFees(address(l));
        assertEq(got, 2 ether * 20 / 10_000);
        assertEq(feeWallet.balance - before, got);
    }

    function test_HookPlatformFeesOnlyFactory() public {
        _graduate(l);
        vm.expectRevert(PolydashHook.OnlyFactory.selector);
        hook.collectPlatformFees(address(l));
    }

    function test_V4CreatorFeesClaimToPayoutWallet() public {
        _graduate(l);
        l.claimCreatorFees(); // drain curve creator fees
        _v4Swap(l, bob, true, -1 ether);
        uint256 before = payout.balance;
        vm.prank(carol); // anyone can trigger
        uint256 amt = l.claimCreatorFees();
        assertEq(amt, 1 ether * 100 / 10_000);
        assertEq(payout.balance - before, amt);
        // direct hook claim also pays the payout wallet only
        _v4Swap(l, bob, true, -1 ether);
        vm.prank(carol);
        hook.claimCreatorFees(l.poolId());
        assertEq(payout.balance - before, 2 * amt);
    }

    function test_SellSpikeAfterGraduation() public {
        vm.prank(owner);
        factory.setPostGraduationSellSpike(500, 10 minutes);
        (PolydashLaunch l2, PolydashToken t2) = _launch(100);
        _graduate(l2);
        PoolId id = l2.poolId();
        uint256 amt = t2.balanceOf(alice) / 20;
        uint256 feeGrowthBefore;
        (feeGrowthBefore,) = IPoolManager(address(manager)).getFeeGrowthGlobals(id);

        uint256 ethBefore = alice.balance;
        _v4Swap(l2, alice, false, -int256(amt));
        uint256 received = alice.balance - ethBefore;
        (,,,,,, , uint256 plat, uint256 cre,) = hook.pools(id);
        uint256 gross = (plat * 10_000) / 20;
        // user received gross - 20 - 100 - 500 bps
        assertApproxEqAbs(received, gross - gross * 620 / 10_000, 1e10);
        (uint256 feeGrowthAfter,) = IPoolManager(address(manager)).getFeeGrowthGlobals(id);
        assertGt(feeGrowthAfter, feeGrowthBefore, "spike donated to locked LP");
        assertApproxEqAbs(cre, gross * 100 / 10_000, 1e4);

        // spike expires
        vm.warp(block.timestamp + 11 minutes);
        uint256 platBefore = plat;
        ethBefore = alice.balance;
        _v4Swap(l2, alice, false, -int256(amt / 10));
        received = alice.balance - ethBefore;
        (,,,,,, , plat,,) = hook.pools(id);
        uint256 gross2 = received + (plat - platBefore) * 6; // plat 20 + creator 100 = 6x platform
        assertApproxEqAbs((plat - platBefore), gross2 * 20 / 10_000, 2);
    }

    function test_SellSpikeOffByDefault() public {
        _graduate(l);
        (,,,, uint24 spike,,,,,) = hook.pools(l.poolId());
        assertEq(spike, 0);
    }

    function test_BuysAndSellsBothDirectionsKeepPoolSolvent() public {
        _graduate(l);
        for (uint256 i; i < 5; ++i) {
            _v4Swap(l, bob, true, -0.5 ether);
            _v4Swap(l, bob, false, -int256(t.balanceOf(bob) / 2));
        }
        assertEq(hook.positionLiquidity(l.poolId()), hook.lockedLiquidity(l.poolId()));
    }

    function test_GraduationByCommitmentsAtGoLive() public {
        PolydashFactory.LaunchParams memory p = _params(100, 0, 1 hours);
        (PolydashLaunch l2,) = _launchWith(p);
        vm.prank(alice);
        l2.commit{value: 10 ether}();
        vm.prank(bob);
        l2.commit{value: 10 ether}();
        vm.warp(block.timestamp + 1 hours);
        l2.goLive();
        assertTrue(l2.graduated());
        assertGt(l2.refunds(bob), 0, "bob's excess refunded");
        uint256 owed = l2.refunds(bob);
        uint256 before = bob.balance;
        vm.prank(bob);
        l2.claimRefund();
        assertEq(bob.balance - before, owed);
        assertEq(l2.refunds(bob), 0);
    }

    function test_GraduationByDevBuy() public {
        PolydashFactory.LaunchParams memory p = _params(100, 20 ether, 0);
        (PolydashLaunch l2,) = _launchWith(p);
        assertTrue(l2.graduated());
        assertGt(l2.refunds(creator), 0);
        assertGt(l2.devBuyTokens(), 0);
    }

    function test_UnusedCallbacksRevert() public {
        PoolKey memory key;
        IPoolManager.ModifyLiquidityParams memory mp;
        BalanceDelta zero;
        vm.expectRevert(PolydashHook.ExternalInitNotAllowed.selector);
        hook.beforeInitialize(address(0), key, 0);
        vm.expectRevert(PolydashHook.HookNotImplemented.selector);
        hook.afterInitialize(address(0), key, 0, 0);
        vm.expectRevert(PolydashHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(0), key, mp, "");
        vm.expectRevert(PolydashHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(0), key, mp, zero, zero, "");
        vm.expectRevert(PolydashHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(0), key, mp, "");
        vm.expectRevert(PolydashHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(0), key, mp, zero, zero, "");
        vm.expectRevert(PolydashHook.HookNotImplemented.selector);
        hook.beforeDonate(address(0), key, 0, 0, "");
        vm.expectRevert(PolydashHook.HookNotImplemented.selector);
        hook.afterDonate(address(0), key, 0, 0, "");
    }

    function test_SwapCallbacksOnlyPoolManager() public {
        _graduate(l);
        PoolKey memory key = hook.poolKeyOf(address(l));
        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams(true, -1, 0);
        vm.expectRevert(PolydashHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, sp, "");
        BalanceDelta zero;
        vm.expectRevert(PolydashHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, sp, zero, "");
    }

    function test_ClaimOnUnknownPoolReverts() public {
        vm.expectRevert(PolydashHook.UnknownPool.selector);
        hook.claimCreatorFees(PoolId.wrap(bytes32(uint256(1))));
    }
}
