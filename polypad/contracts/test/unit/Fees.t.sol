// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashToken} from "../../src/PolydashToken.sol";
import {PolydashFactory} from "../../src/PolydashFactory.sol";
import {PolydashHook} from "../../src/PolydashHook.sol";
import {BuybackRouter} from "../../src/BuybackRouter.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";
import {MockERC20, MockSwapRouter, MockV3Pool} from "../mocks/MockSwapRouter.sol";

contract FeesTest is BaseTest {
    PolydashLaunch l;
    PolydashToken t;

    function setUp() public override {
        super.setUp();
        _disableAntiSniper();
        (l, t) = _launch(100);
    }

    function test_PlatformFeeConstantIs20EverywhereAndHasNoSetter() public view {
        assertEq(factory.PLATFORM_FEE_BPS(), 20);
        assertEq(l.PLATFORM_FEE_BPS(), 20);
        assertEq(hook.PLATFORM_FEE_BPS(), 20);
        assertEq(FeeMath.PLATFORM_FEE_BPS, 20);
    }

    function test_NoPlatformFeeSetterSelectorExists() public {
        bytes[4] memory calls = [
            abi.encodeWithSignature("setPlatformFeeBps(uint256)", 21),
            abi.encodeWithSignature("setPlatformFee(uint256)", 21),
            abi.encodeWithSignature("setFeeBps(uint256)", 21),
            abi.encodeWithSignature("setCreatorFeeBps(uint256)", 300)
        ];
        address[3] memory targets = [address(factory), address(l), address(hook)];
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 j; j < calls.length; ++j) {
                vm.prank(owner);
                (bool ok,) = targets[i].call(calls[j]);
                assertFalse(ok);
            }
        }
        assertEq(l.creatorFeeBps(), 100);
    }

    function test_BuyCollectsExactly20Bps() public {
        uint256[4] memory amounts = [uint256(1), 12_345, 0.333333333333333333 ether, 7.777 ether];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 before = l.platformFeesAccrued();
            uint256 beforeC = l.creatorFeesAccrued();
            vm.prank(alice);
            try l.buy{value: amounts[i]}(0) {
                assertEq(l.platformFeesAccrued() - before, amounts[i] * 20 / 10_000);
                assertEq(l.creatorFeesAccrued() - beforeC, amounts[i] * 100 / 10_000);
            } catch {
                // dust buys that yield 0 tokens revert; nothing accrues
                assertEq(l.platformFeesAccrued(), before);
            }
        }
    }

    function test_SellCollectsExactly20Bps() public {
        _buy(l, alice, 5 ether);
        uint256 amt = t.balanceOf(alice) / 3;
        (uint256 q, FeeMath.Fees memory f) = l.quoteSell(amt);
        uint256 gross = q + f.total;
        uint256 before = l.platformFeesAccrued();
        _sell(l, alice, amt);
        assertEq(l.platformFeesAccrued() - before, gross * 20 / 10_000);
        assertEq(f.platform, gross * 20 / 10_000);
    }

    function test_TotalFeeIsCreatorPlusPlatform() public {
        (PolydashLaunch l0,) = _launch(0);
        (PolydashLaunch l2,) = _launch(200);
        (, FeeMath.Fees memory f0) = l0.quoteBuy(1 ether);
        (, FeeMath.Fees memory f1) = l.quoteBuy(1 ether);
        (, FeeMath.Fees memory f2) = l2.quoteBuy(1 ether);
        assertEq(f0.total, 0.002 ether); // 0.2%
        assertEq(f1.total, 0.012 ether); // 1.2%
        assertEq(f2.total, 0.022 ether); // 2.2%
        assertEq(l.currentBuyFeeBps(), 120);
    }

    function test_CreatorFeeAbove200Reverts() public {
        vm.expectRevert(PolydashFactory.InvalidParams.selector);
        vm.prank(creator);
        factory.createLaunch(_params(201, 0, 0));
    }

    function test_CollectPlatformFeesGoesToWallet() public {
        _buy(l, alice, 3 ether);
        uint256 accrued = l.platformFeesAccrued();
        vm.prank(bob); // permissionless
        uint256 got = factory.collectPlatformFees(address(l));
        assertEq(got, accrued);
        assertEq(feeWallet.balance, accrued);
        assertEq(l.platformFeesAccrued(), 0);
        assertEq(factory.collectPlatformFees(address(l)), 0);
    }

    function test_OnlyFactoryCanPullLaunchPlatformFees() public {
        _buy(l, alice, 1 ether);
        vm.expectRevert(PolydashLaunch.OnlyFactory.selector);
        vm.prank(owner);
        l.collectPlatformFees();
    }

    function test_CollectPlatformFeesUnknownLaunchReverts() public {
        vm.expectRevert(PolydashFactory.NotLaunch.selector);
        factory.collectPlatformFees(address(0xBEEF));
    }

    function test_CollectMany() public {
        (PolydashLaunch l2,) = _launch(50);
        _buy(l, alice, 1 ether);
        _buy(l2, alice, 2 ether);
        address[] memory ls = new address[](2);
        ls[0] = address(l);
        ls[1] = address(l2);
        uint256 total = factory.collectPlatformFeesMany(ls);
        assertEq(total, 0.002 ether + 0.004 ether);
        assertEq(feeWallet.balance, total);
    }

    // ------------------------------------------------------------------ fee wallet timelock

    function test_FeeWalletTimelock() public {
        address newWallet = makeAddr("newWallet");
        vm.prank(owner);
        factory.initiateFeeWalletChange(newWallet);
        assertEq(factory.feeWalletChangeAt(), block.timestamp + 48 hours);

        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(owner);
        vm.expectRevert(PolydashFactory.TooEarly.selector);
        factory.executeFeeWalletChange();

        vm.warp(block.timestamp + 1);
        vm.prank(owner);
        factory.executeFeeWalletChange();
        assertEq(factory.platformFeeWallet(), newWallet);
    }

    function test_FeeWalletTimelockOnlyOwnerAndCancel() public {
        vm.expectRevert();
        vm.prank(alice);
        factory.initiateFeeWalletChange(alice);

        vm.startPrank(owner);
        factory.initiateFeeWalletChange(alice);
        factory.cancelFeeWalletChange();
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(PolydashFactory.NoPendingChange.selector);
        factory.executeFeeWalletChange();
        vm.expectRevert(PolydashFactory.NoPendingChange.selector);
        factory.cancelFeeWalletChange();
        vm.expectRevert(PolydashFactory.InvalidParams.selector);
        factory.initiateFeeWalletChange(address(0));
        vm.stopPrank();
        assertEq(factory.platformFeeWallet(), feeWallet);
    }

    function test_OwnershipIsTwoStep() public {
        address multisig = makeAddr("multisig");
        vm.prank(owner);
        factory.transferOwnership(multisig);
        assertEq(factory.owner(), owner);
        vm.prank(multisig);
        factory.acceptOwnership();
        assertEq(factory.owner(), multisig);
    }

    // ------------------------------------------------------------------ buyback

    function _setupBuyback(uint256 haircut) internal returns (BuybackRouter router, MockERC20 pd, address rewards) {
        pd = new MockERC20("Polydash", "POLYDASH");
        MockERC20 weth = new MockERC20("WETH", "WETH");
        MockSwapRouter sr = new MockSwapRouter(pd, 0); // rate set below
        // tick 0 => price 1 (1 POLYDASH per WETH, both 18 decimals)
        MockV3Pool pool = new MockV3Pool(0);
        router = new BuybackRouter(owner, address(factory), address(sr), address(weth), address(pd), address(pool), 3000);
        sr = new MockSwapRouter(pd, 1e18);
        router = new BuybackRouter(owner, address(factory), address(sr), address(weth), address(pd), address(pool), 3000);
        sr.setHaircut(haircut);
        rewards = makeAddr("rewards");
        vm.startPrank(owner);
        factory.setTradingRewardsPool(rewards);
        factory.setBuybackConfig(true, 500, address(router));
        vm.stopPrank();
    }

    function test_BuybackOffByDefault() public view {
        assertFalse(factory.buybackEnabled());
        assertEq(factory.buybackBps(), 0);
    }

    function test_BuybackRoutesShareToRewardsPool() public {
        (, MockERC20 pd, address rewards) = _setupBuyback(100); // 1% price impact, within 2% slippage
        _buy(l, alice, 10 ether);
        uint256 accrued = l.platformFeesAccrued();
        factory.collectPlatformFees(address(l));
        uint256 toBuyback = accrued * 500 / 10_000;
        assertEq(feeWallet.balance, accrued - toBuyback);
        assertEq(pd.balanceOf(rewards), toBuyback * 99 / 100);
    }

    function test_BuybackSlippageFailureFallsBackToWallet() public {
        _setupBuyback(500); // 5% impact > 2% max slippage => router reverts
        _buy(l, alice, 10 ether);
        uint256 accrued = l.platformFeesAccrued();
        factory.collectPlatformFees(address(l));
        assertEq(feeWallet.balance, accrued);
    }

    function test_BuybackRouterAdmin() public {
        (BuybackRouter router,,) = _setupBuyback(0);
        vm.startPrank(owner);
        router.setMaxSlippageBps(500);
        vm.expectRevert(BuybackRouter.InvalidParams.selector);
        router.setMaxSlippageBps(1001);
        router.setTwapWindow(600);
        vm.expectRevert(BuybackRouter.InvalidParams.selector);
        router.setTwapWindow(10);
        vm.expectRevert(BuybackRouter.InvalidParams.selector);
        router.setPool(address(0), 500);
        router.setPool(address(1), 500);
        vm.stopPrank();
        assertEq(router.maxSlippageBps(), 500);
        assertEq(router.twapWindow(), 600);
        vm.expectRevert();
        vm.prank(alice);
        router.setMaxSlippageBps(1);
    }

    function test_BuybackDirectCall() public {
        (BuybackRouter router, MockERC20 pd, address rewards) = _setupBuyback(0);
        vm.prank(alice);
        uint256 out = router.buyback{value: 1 ether}();
        assertEq(out, 1 ether);
        assertEq(pd.balanceOf(rewards), 1 ether);
        vm.expectRevert(BuybackRouter.ZeroAmount.selector);
        router.buyback{value: 0}();
        vm.prank(owner);
        factory.setTradingRewardsPool(address(0));
        vm.expectRevert(BuybackRouter.NoRewardsPool.selector);
        router.buyback{value: 1}();
    }

    function test_BuybackQuoteAtTick() public {
        (BuybackRouter router,,) = _setupBuyback(0);
        assertApproxEqRel(router.quoteAtTick(0, 1 ether), 1 ether, 1e9);
        // tick 6932 ~ price 2 (or 1/2 depending on token order)
        uint256 q = router.quoteAtTick(6932, 1 ether);
        assertTrue(
            (q > 1.99 ether && q < 2.01 ether) || (q > 0.49 ether && q < 0.51 ether)
        );
        router.quoteAtTick(800_000, 1 ether); // large tick path
        router.quoteAtTick(-800_000, 1 ether);
    }

    function test_BuybackConfigBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(PolydashFactory.InvalidParams.selector);
        factory.setBuybackConfig(true, 500, address(0));
        vm.expectRevert(PolydashFactory.InvalidParams.selector);
        factory.setBuybackConfig(false, 10_001, address(1));
        vm.stopPrank();
    }
}
