// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashToken} from "../../src/PolydashToken.sol";
import {FeeMath} from "../../src/libraries/FeeMath.sol";

contract FeeFuzzTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _disableAntiSniper();
    }

    function testFuzz_SplitComponentsExact(uint256 gross, uint256 creatorBps, uint256 taxBps) public pure {
        gross = bound(gross, 0, 1e30);
        creatorBps = bound(creatorBps, 0, 200);
        taxBps = bound(taxBps, 0, 2000);
        FeeMath.Fees memory f = FeeMath.split(gross, creatorBps, taxBps);
        assertEq(f.platform, gross * 20 / 10_000);
        assertEq(f.creator, gross * creatorBps / 10_000);
        assertEq(f.tax, gross * taxBps / 10_000);
        assertEq(f.total, f.platform + f.creator + f.tax);
        assertLe(f.total, gross);
    }

    function testFuzz_GrossForNetCoversNet(uint256 net, uint256 bps) public pure {
        net = bound(net, 1, 1e30);
        bps = bound(bps, 0, 2220);
        uint256 gross = FeeMath.grossForNet(net, bps);
        FeeMath.Fees memory f = FeeMath.split(gross, 0, bps);
        assertGe(gross - f.tax, net);
    }

    function testFuzz_CurveBuyPlatformFeeExactly20Bps(uint256 ethIn, uint256 creatorBps) public {
        creatorBps = bound(creatorBps, 0, 200);
        ethIn = bound(ethIn, 0.0001 ether, 14 ether);
        (PolydashLaunch l,) = _launch(creatorBps);
        _buy(l, alice, ethIn);
        if (l.graduated()) return; // capped buy, covered by unit tests
        assertEq(l.platformFeesAccrued(), ethIn * 20 / 10_000);
        assertEq(l.creatorFeesAccrued(), ethIn * creatorBps / 10_000);
    }

    function testFuzz_CurveSellPlatformFeeExactly20Bps(uint256 ethIn, uint256 frac, uint256 creatorBps) public {
        creatorBps = bound(creatorBps, 0, 200);
        ethIn = bound(ethIn, 0.01 ether, 10 ether);
        frac = bound(frac, 1, 100);
        (PolydashLaunch l, PolydashToken t) = _launch(creatorBps);
        _buy(l, alice, ethIn);
        uint256 p0 = l.platformFeesAccrued();
        uint256 c0 = l.creatorFeesAccrued();
        uint256 amt = t.balanceOf(alice) * frac / 100;
        (uint256 out, FeeMath.Fees memory q) = l.quoteSell(amt);
        uint256 got = _sell(l, alice, amt);
        assertEq(got, out);
        uint256 gross = out + q.total;
        assertEq(l.platformFeesAccrued() - p0, gross * 20 / 10_000);
        assertEq(l.creatorFeesAccrued() - c0, gross * creatorBps / 10_000);
    }

    function testFuzz_CreatorFeeAbove200AlwaysReverts(uint256 creatorBps) public {
        creatorBps = bound(creatorBps, 201, type(uint128).max);
        vm.prank(creator);
        vm.expectRevert();
        factory.createLaunch(_params(creatorBps, 0, 0));
    }

    function testFuzz_V4BuyFeeExactly20BpsInEth(uint256 ethIn) public {
        ethIn = bound(ethIn, 1e9, 20 ether);
        (PolydashLaunch l, PolydashToken t) = _launch(100);
        _graduate(l);
        uint256 tokBefore = t.balanceOf(address(hook));
        _v4Swap(l, bob, true, -int256(ethIn));
        (,,,,,,, uint256 plat, uint256 cre,) = hook.pools(l.poolId());
        assertEq(plat, ethIn * 20 / 10_000);
        assertEq(cre, ethIn * 100 / 10_000);
        assertEq(t.balanceOf(address(hook)), tokBefore);
    }

    function testFuzz_V4SellFeeExactly20BpsInEth(uint256 frac) public {
        frac = bound(frac, 1, 50);
        (PolydashLaunch l, PolydashToken t) = _launch(100);
        _graduate(l);
        uint256 amt = t.balanceOf(alice) * frac / 100;
        uint256 before = alice.balance;
        _v4Swap(l, alice, false, -int256(amt));
        uint256 received = alice.balance - before;
        (,,,,,,, uint256 plat, uint256 cre,) = hook.pools(l.poolId());
        uint256 gross = received + plat + cre;
        assertEq(plat, gross * 20 / 10_000);
        assertEq(cre, gross * 100 / 10_000);
    }
}
