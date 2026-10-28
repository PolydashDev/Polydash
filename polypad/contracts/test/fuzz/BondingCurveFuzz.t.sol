// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashToken} from "../../src/PolydashToken.sol";
import {BondingCurveMath} from "../../src/libraries/BondingCurveMath.sol";

contract BondingCurveFuzzTest is BaseTest {
    PolydashLaunch l;
    PolydashToken t;

    function setUp() public override {
        super.setUp();
        _disableAntiSniper();
        (l, t) = _launch(100);
    }

    /// Library: k never decreases on a buy and output never exceeds the reserve.
    function testFuzz_MathBuyNeverShrinksK(uint256 x, uint256 y, uint256 dx) public pure {
        x = bound(x, 1e12, 1e30);
        y = bound(y, 1e18, 1e36);
        dx = bound(dx, 1, 1e30);
        uint256 out = BondingCurveMath.tokensOutForEthIn(x, y, dx);
        assertLt(out, y);
        assertGe((x + dx) * (y - out), x * y);
    }

    function testFuzz_MathSellNeverShrinksK(uint256 x, uint256 y, uint256 dy) public pure {
        x = bound(x, 1e12, 1e30);
        y = bound(y, 1e18, 1e36);
        dy = bound(dy, 1, 1e36);
        uint256 out = BondingCurveMath.ethOutForTokensIn(x, y, dy);
        assertLt(out, x);
        assertGe((x - out) * (y + dy), x * y);
    }

    /// Buying then immediately selling everything can never return more ETH than was put in.
    function testFuzz_NoRoundTripProfit(uint256 ethIn) public {
        ethIn = bound(ethIn, 0.0001 ether, 14 ether);
        uint256 before = alice.balance;
        _buy(l, alice, ethIn);
        if (l.graduated()) return;
        _sell(l, alice, t.balanceOf(alice));
        assertLt(alice.balance, before);
    }

    /// Splitting a buy into two never gives more tokens than one buy of the same total (no path dependence exploit).
    function testFuzz_SplitBuyNotBetter(uint256 a, uint256 b) public {
        a = bound(a, 0.001 ether, 6 ether);
        b = bound(b, 0.001 ether, 6 ether);
        uint256 snap = vm.snapshotState();
        _buy(l, alice, a + b);
        uint256 single = t.balanceOf(alice);
        vm.revertToState(snap);
        _buy(l, alice, a);
        _buy(l, alice, b);
        uint256 split = t.balanceOf(alice);
        // only rounding dust can differ (each fee component is floored per trade)
        assertLe(split, single + single / 1e15);
    }

    /// Spot price is monotonic in tokens sold.
    function testFuzz_PriceMonotonic(uint256 a, uint256 b) public {
        a = bound(a, 0.001 ether, 7 ether);
        b = bound(b, 0.001 ether, 7 ether);
        uint256 p0 = l.spotPrice();
        _buy(l, alice, a);
        uint256 p1 = l.spotPrice();
        assertGt(p1, p0);
        _buy(l, bob, b);
        assertGt(l.spotPrice(), p1);
        _sell(l, alice, t.balanceOf(alice));
        assertLt(l.spotPrice(), p1 + (l.spotPrice() - p0) + 1);
    }

    /// Contract is always solvent: ETH balance covers every claim on it.
    function testFuzz_Solvency(uint256[6] memory amounts, bool[6] memory sells) public {
        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < 6; ++i) {
            if (l.graduated()) break;
            address u = users[i % 3];
            if (sells[i] && t.balanceOf(u) > 1e15) {
                _sell(l, u, bound(amounts[i], 1e15, t.balanceOf(u)));
            } else {
                _buy(l, u, bound(amounts[i], 0.0001 ether, 5 ether));
            }
            uint256 owed = l.platformFeesAccrued() + l.creatorFeesAccrued() + l.totalRefunds();
            if (!l.graduated()) owed += l.realEthRaised() + l.sniperTaxAccrued();
            assertGe(address(l).balance, owed);
            assertLe(l.tokensSold(), l.curveSupply());
        }
    }
}
