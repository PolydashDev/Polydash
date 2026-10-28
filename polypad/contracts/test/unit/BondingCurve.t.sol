// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashToken} from "../../src/PolydashToken.sol";
import {PolydashFactory} from "../../src/PolydashFactory.sol";
import {BondingCurveMath} from "../../src/libraries/BondingCurveMath.sol";

contract BondingCurveTest is BaseTest {
    PolydashLaunch l;
    PolydashToken t;

    function setUp() public override {
        super.setUp();
        _disableAntiSniper();
        (l, t) = _launch(100);
    }

    function test_InitialState() public view {
        assertEq(uint8(l.phase()), uint8(PolydashLaunch.Phase.Trading));
        assertEq(l.totalSupply(), 1_000_000_000 ether);
        assertEq(l.curveSupply(), 800_000_000 ether);
        assertEq(l.virtualEth(), 1.5 ether);
        assertEq(l.k(), 1.5 ether * 800_000_000 ether);
        assertEq(t.balanceOf(address(l)), 1_000_000_000 ether);
        assertEq(l.graduationThreshold(), 15 ether);
        assertEq(t.imageUri(), "ipfs://image");
        assertEq(t.socialLinks().length, 2);
    }

    function test_BuyMatchesFormula() public {
        uint256 ethIn = 1 ether;
        uint256 fee = ethIn * 120 / 10_000;
        uint256 net = ethIn - fee;
        uint256 expected = 800_000_000 ether - (l.k() + (1.5 ether + net) - 1) / (1.5 ether + net);
        uint256 out = _buy(l, alice, ethIn);
        assertEq(out, expected);
        assertEq(t.balanceOf(alice), expected);
        assertEq(l.realEthRaised(), net);
        assertEq(l.tokensSold(), expected);
    }

    function test_KNeverDecreases_BuysAndSells() public {
        uint256 k0 = l.k();
        uint256[5] memory buys = [uint256(0.01 ether), 0.5 ether, 1 ether, 2.3 ether, 3 ether];
        for (uint256 i; i < buys.length; ++i) {
            _buy(l, alice, buys[i]);
            assertGe(_product(l), k0);
            // rounding drift is bounded by one unit of the larger reserve
            assertLe(_product(l) - k0, l.ethReserve() + l.tokenReserve());
        }
        uint256 bal = t.balanceOf(alice);
        _sell(l, alice, bal / 3);
        assertGe(_product(l), k0);
        _sell(l, alice, t.balanceOf(alice));
        assertGe(_product(l), k0);
        assertEq(l.tokensSold(), 0);
    }

    function test_PriceIncreasesMonotonicallyWithBuys() public {
        uint256 last = l.spotPrice();
        for (uint256 i; i < 10; ++i) {
            _buy(l, alice, 1 ether);
            uint256 p = l.spotPrice();
            assertGt(p, last);
            last = p;
        }
    }

    function test_PriceDecreasesWithSells() public {
        _buy(l, alice, 5 ether);
        uint256 last = l.spotPrice();
        uint256 chunk = t.balanceOf(alice) / 5;
        for (uint256 i; i < 4; ++i) {
            _sell(l, alice, chunk);
            assertLt(l.spotPrice(), last);
            last = l.spotPrice();
        }
    }

    function test_SellMatchesFormula() public {
        _buy(l, alice, 2 ether);
        uint256 amt = t.balanceOf(alice) / 2;
        uint256 er = l.ethReserve();
        uint256 tr = l.tokenReserve();
        uint256 gross = BondingCurveMath.ethOutForTokensIn(er, tr, amt);
        uint256 before = alice.balance;
        uint256 out = _sell(l, alice, amt);
        assertEq(out, gross - gross * 120 / 10_000);
        assertEq(alice.balance - before, out);
    }

    function test_BuyThenSellAllLosesOnlyFeesAndRounding() public {
        uint256 before = alice.balance;
        _buy(l, alice, 1 ether);
        _sell(l, alice, t.balanceOf(alice));
        uint256 lost = before - alice.balance;
        // 1.2% on the way in, ~1.2% on the way out
        assertApproxEqRel(lost, 0.0239 ether, 0.01e18);
        // rounding always favours the pool (k never shrinks): at most a few wei stay behind
        assertLe(l.realEthRaised(), 2);
    }

    function test_SellMoreThanSoldReverts() public {
        _buy(l, alice, 1 ether);
        uint256 tooMuch = l.tokensSold() + 1;
        vm.expectRevert(PolydashLaunch.InvalidParams.selector);
        vm.prank(alice);
        l.sell(tooMuch, 0);
    }

    function test_BuySlippageReverts() public {
        (uint256 q,) = l.quoteBuy(1 ether);
        vm.expectRevert(PolydashLaunch.Slippage.selector);
        vm.prank(alice);
        l.buy{value: 1 ether}(q + 1);
        vm.prank(alice);
        assertEq(l.buy{value: 1 ether}(q), q);
    }

    function test_SellSlippageReverts() public {
        _buy(l, alice, 1 ether);
        uint256 amt = t.balanceOf(alice);
        (uint256 q,) = l.quoteSell(amt);
        vm.startPrank(alice);
        t.approve(address(l), amt);
        vm.expectRevert(PolydashLaunch.Slippage.selector);
        l.sell(amt, q + 1);
        assertEq(l.sell(amt, q), q);
        vm.stopPrank();
    }

    function test_ZeroBuyReverts() public {
        vm.expectRevert(PolydashLaunch.ZeroAmount.selector);
        vm.prank(alice);
        l.buy{value: 0}(0);
    }

    function test_GraduationTriggersExactlyAtThreshold() public {
        _buy(l, alice, 10 ether);
        assertFalse(l.graduated());
        uint256 remaining = l.graduationThreshold() - l.realEthRaised();
        // a buy a few wei short of the threshold does not graduate
        uint256 gross = (remaining - 10) * 10_000 / (10_000 - 120);
        _buy(l, bob, gross);
        assertFalse(l.graduated());
        assertLt(l.realEthRaised(), l.graduationThreshold());
        _buy(l, bob, 1 ether);
        assertTrue(l.graduated());
        assertGe(l.graduationEth(), 15 ether);
        assertLe(l.graduationEth(), 15 ether + 3);
    }

    function test_OverThresholdBuyIsCappedAndRefunded() public {
        uint256 before = alice.balance;
        _buy(l, alice, 50 ether);
        assertTrue(l.graduated());
        uint256 spent = before - alice.balance;
        // ~15 ETH net + 1.2% fees
        assertApproxEqAbs(spent, uint256(15 ether) * 10_000 / 9_880, 10);
    }

    function test_MarketCapGraduationMode() public {
        vm.prank(owner);
        factory.setGraduationTarget(PolydashFactory.GraduationMode.MarketCap, 100 ether);
        (PolydashLaunch l2,) = _launch(100);
        uint256 thr = l2.graduationThreshold();
        // mcap at threshold == target (within rounding)
        uint256 er = l2.virtualEth() + thr;
        uint256 tr = l2.k() / er;
        uint256 mcap = er * l2.totalSupply() / tr;
        assertApproxEqRel(mcap, 100 ether, 1e12);
        assertEq(factory.previewGraduationThreshold(0, 0), thr);
    }

    function test_CustomSupplyAndVirtualReserve() public {
        PolydashFactory.LaunchParams memory p = _params(50, 0, 0);
        p.totalSupply = 21_000_000 ether;
        p.virtualEthReserve = 3 ether;
        (PolydashLaunch l2, PolydashToken t2) = _launchWith(p);
        assertEq(t2.totalSupply(), 21_000_000 ether);
        assertEq(l2.curveSupply(), 16_800_000 ether);
        assertEq(l2.virtualEth(), 3 ether);
    }
}
