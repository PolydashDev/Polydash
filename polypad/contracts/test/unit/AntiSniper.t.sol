// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashToken} from "../../src/PolydashToken.sol";
import {PolydashFactory} from "../../src/PolydashFactory.sol";

contract AntiSniperTest is BaseTest {
    PolydashLaunch l;
    PolydashToken t;

    function setUp() public override {
        super.setUp();
        // defaults: 10% high fee decaying over 5 minutes, 1% wallet cap for 5 blocks
        (l, t) = _launch(100);
    }

    function test_DefaultConfig() public view {
        assertEq(l.antiSniperFeeBps(), 1000);
        assertEq(l.antiSniperFeeDuration(), 5 minutes);
        assertEq(l.antiSniperCapBlocks(), 5);
        assertEq(l.antiSniperCapBps(), 100);
    }

    function test_HighFeeAtStartDecaysToNormal() public {
        assertEq(l.currentBuyFeeBps(), 20 + 1000, "platform + 10% at t=0");
        vm.warp(block.timestamp + 150);
        assertEq(l.currentBuyFeeBps(), 20 + 500);
        vm.warp(block.timestamp + 120); // 270s: high = 100 -> equal to creator fee -> surplus 0
        assertEq(l.currentBuyFeeBps(), 20 + 100);
        vm.warp(block.timestamp + 1 hours);
        assertEq(l.currentBuyFeeBps(), 120, "normal fee");
    }

    function test_FeeMonotonicallyDecreasing() public {
        uint256 prev = type(uint256).max;
        for (uint256 i; i <= 300; i += 10) {
            vm.warp(l.tradingStartTime() + i);
            uint256 f = l.currentBuyFeeBps();
            assertLe(f, prev);
            prev = f;
        }
    }

    function test_SurplusGoesToLpNotToAnyone() public {
        vm.roll(block.number + 10); // past wallet cap
        _buy(l, alice, 1 ether);
        uint256 tax = l.sniperTaxAccrued();
        assertEq(tax, 1 ether * 900 / 10_000);
        assertEq(l.platformFeesAccrued(), 1 ether * 20 / 10_000, "platform still exactly 20 bps");
        assertEq(l.creatorFeesAccrued(), 1 ether * 100 / 10_000);
        // graduate: surplus is included in LP ETH
        vm.warp(block.timestamp + 1 hours);
        uint256 raisedBefore = l.graduationThreshold();
        _graduate(l);
        assertEq(l.graduationEth(), raisedBefore + tax + (l.realEthRaised() - raisedBefore));
        assertEq(l.sniperTaxAccrued(), 0);
    }

    function test_SellsNotTaxed() public {
        vm.roll(block.number + 10);
        _buy(l, alice, 0.5 ether);
        uint256 taxBefore = l.sniperTaxAccrued();
        _sell(l, alice, t.balanceOf(alice) / 2);
        assertEq(l.sniperTaxAccrued(), taxBefore);
    }

    function test_WalletCapDuringFirstBlocks() public {
        vm.warp(block.timestamp + 1 hours); // remove fee to isolate cap
        // cap = 1% of 1B = 10M tokens. A 0.2 ETH buy at the start yields ~ 13M tokens -> exceeds
        vm.prank(alice);
        vm.expectRevert();
        l.buy{value: 0.2 ether}(0);

        _buy(l, alice, 0.01 ether);
        uint256 held = l.walletBought(alice);
        assertGt(held, 0);
        // repeated small buys accumulate against the cap
        vm.startPrank(alice);
        for (uint256 i; i < 20; ++i) {
            try l.buy{value: 0.01 ether}(0) {} catch (bytes memory err) {
                assertEq(bytes4(err), PolydashLaunch.WalletCapExceeded.selector);
                break;
            }
        }
        vm.stopPrank();
        assertLe(l.walletBought(alice), 10_000_000e18);
    }

    function test_CapLiftedAfterNBlocks() public {
        vm.warp(block.timestamp + 1 hours);
        vm.roll(l.tradingStartBlock() + 5);
        _buy(l, alice, 1 ether);
        assertGt(t.balanceOf(alice), 10_000_000e18);
    }

    function test_DevBuyAndCommitmentsExemptFromCap() public {
        PolydashFactory.LaunchParams memory p = _params(100, 2 ether, 0);
        (PolydashLaunch l2, PolydashToken t2) = _launchWith(p);
        assertGt(t2.balanceOf(creator), 10_000_000e18);
        assertEq(l2.sniperTaxAccrued(), 0);
    }

    function test_ConfigurableAndBounded() public {
        vm.startPrank(owner);
        factory.setAntiSniperConfig(2000, 10 minutes, 20, 50);
        vm.expectRevert(PolydashFactory.InvalidParams.selector);
        factory.setAntiSniperConfig(2001, 10 minutes, 20, 50);
        vm.expectRevert(PolydashFactory.InvalidParams.selector);
        factory.setAntiSniperConfig(1000, 1 hours + 1, 20, 50);
        vm.expectRevert(PolydashFactory.InvalidParams.selector);
        factory.setAntiSniperConfig(1000, 10 minutes, 101, 50);
        vm.expectRevert(PolydashFactory.InvalidParams.selector);
        factory.setAntiSniperConfig(1000, 10 minutes, 20, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        factory.setAntiSniperConfig(0, 0, 0, 10_000);

        (PolydashLaunch l2,) = _launch(100);
        assertEq(l2.antiSniperFeeBps(), 2000);
        assertEq(l2.antiSniperCapBlocks(), 20);
        // existing launches keep their config
        assertEq(l.antiSniperFeeBps(), 1000);
    }

    function test_OverThresholdBuyDuringSniperWindowRefundsExcess() public {
        vm.roll(block.number + 10);
        uint256 before = alice.balance;
        _buy(l, alice, 100 ether);
        assertTrue(l.graduated());
        uint256 spent = before - alice.balance;
        assertLt(spent, 20 ether);
    }
}
