// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashToken} from "../../src/PolydashToken.sol";
import {PolydashFactory} from "../../src/PolydashFactory.sol";

/// @dev Payout wallet that tries to re-enter every Launch entry point when it receives ETH.
contract ReentrantPayout {
    PolydashLaunch public launch;
    uint256 public attempts;
    uint256 public successes;

    function setLaunch(PolydashLaunch l) external {
        launch = l;
    }

    receive() external payable {
        if (address(launch) == address(0) || attempts > 0) return;
        attempts++;
        (bool a,) = address(launch).call(abi.encodeCall(PolydashLaunch.claimCreatorFees, ()));
        (bool b,) = address(launch).call{value: 0}(abi.encodeCall(PolydashLaunch.sell, (1, 0)));
        (bool c,) = address(launch).call(abi.encodeCall(PolydashLaunch.claimRefund, ()));
        if (a || b || c) successes++;
    }
}

contract RejectingWallet {
    receive() external payable {
        revert("no");
    }
}

contract CreatorFeeTest is BaseTest {
    PolydashLaunch l;
    PolydashToken t;

    function setUp() public override {
        super.setUp();
        _disableAntiSniper();
        (l, t) = _launch(150);
    }

    function test_CreatorFeeBoundsAndImmutable() public {
        assertEq(l.creatorFeeBps(), 150);
        // 0 is allowed
        (PolydashLaunch l0,) = _launch(0);
        assertEq(l0.creatorFeeBps(), 0);
        (PolydashLaunch l200,) = _launch(200);
        assertEq(l200.creatorFeeBps(), 200);
        // no setter on the launch
        (bool ok,) = address(l).call(abi.encodeWithSignature("setCreatorFeeBps(uint256)", 10));
        assertFalse(ok);
    }

    function test_ClaimPaysPayoutWalletRegardlessOfCaller() public {
        _buy(l, alice, 2 ether);
        uint256 accrued = l.creatorFeesAccrued();
        assertEq(accrued, 2 ether * 150 / 10_000);
        address[4] memory callers = [alice, owner, creator, address(0xBEEF)];
        for (uint256 i; i < callers.length; ++i) {
            _buy(l, bob, 1 ether);
            uint256 owed = l.creatorFeesAccrued();
            uint256 before = payout.balance;
            uint256 callerBefore = callers[i].balance;
            vm.prank(callers[i]);
            l.claimCreatorFees();
            assertEq(payout.balance - before, owed);
            assertEq(callers[i].balance, callerBefore, "caller gets nothing");
            assertEq(l.creatorFeesAccrued(), 0);
        }
    }

    function test_ClaimWithNothingReverts() public {
        vm.expectRevert(PolydashLaunch.NothingToClaim.selector);
        l.claimCreatorFees();
    }

    function test_ClaimNeverTakesTokensOrApprovals() public {
        vm.deal(payout, 10 ether);
        _buy(l, payout, 1 ether);
        uint256 tokBal = t.balanceOf(payout);
        uint256 ethBefore = payout.balance;
        l.claimCreatorFees();
        assertEq(t.balanceOf(payout), tokBal, "claim never touches the wallet's tokens");
        assertGt(payout.balance, ethBefore, "wallet only ever gains ETH");
    }

    function test_PayoutWalletChangeTimelock48h() public {
        address newWallet = makeAddr("newWallet");
        vm.expectRevert(PolydashLaunch.OnlyCreator.selector);
        vm.prank(alice);
        l.initiatePayoutWalletChange(newWallet);

        vm.prank(creator);
        vm.expectEmit(address(l));
        emit PolydashLaunch.PayoutWalletChangeInitiated(payout, newWallet, block.timestamp + 48 hours);
        l.initiatePayoutWalletChange(newWallet);

        _buy(l, alice, 1 ether);
        uint256 owedToOld = l.creatorFeesAccrued();

        vm.warp(block.timestamp + 48 hours - 1);
        vm.expectRevert(PolydashLaunch.TooEarly.selector);
        l.executePayoutWalletChange();

        vm.warp(block.timestamp + 1);
        uint256 before = payout.balance;
        vm.prank(bob); // anyone can execute once matured
        l.executePayoutWalletChange();
        assertEq(l.creatorPayoutWallet(), newWallet);
        assertEq(payout.balance - before, owedToOld, "fees before switch go to old wallet");

        _buy(l, alice, 1 ether);
        uint256 nb = newWallet.balance;
        l.claimCreatorFees();
        assertGt(newWallet.balance, nb);
    }

    function test_PayoutWalletCanVetoChange() public {
        vm.prank(creator);
        l.initiatePayoutWalletChange(alice);
        vm.prank(payout);
        l.cancelPayoutWalletChange();
        assertEq(l.pendingPayoutWallet(), address(0));
        vm.warp(block.timestamp + 3 days);
        vm.expectRevert(PolydashLaunch.NoPendingChange.selector);
        l.executePayoutWalletChange();
        assertEq(l.creatorPayoutWallet(), payout);
    }

    function test_StrangersCannotCancelOrInitiate() public {
        vm.prank(creator);
        l.initiatePayoutWalletChange(alice);
        vm.prank(bob);
        vm.expectRevert(PolydashLaunch.OnlyCreator.selector);
        l.cancelPayoutWalletChange();
        vm.prank(owner);
        vm.expectRevert(PolydashLaunch.OnlyCreator.selector);
        l.initiatePayoutWalletChange(owner);
    }

    function test_ZeroAddressPayoutRejected() public {
        vm.prank(creator);
        vm.expectRevert(PolydashLaunch.InvalidParams.selector);
        l.initiatePayoutWalletChange(address(0));
    }

    function test_OwnerAndFactoryCannotRedirectOrSeizeCreatorFees() public {
        _buy(l, alice, 5 ether);
        uint256 owed = l.creatorFeesAccrued();
        // Factory-only entry point moves PLATFORM fees only
        vm.prank(owner);
        factory.collectPlatformFees(address(l));
        assertEq(l.creatorFeesAccrued(), owed, "creator fees untouched by platform collection");
        // owner cannot call launch admin functions
        vm.startPrank(owner);
        vm.expectRevert(PolydashLaunch.OnlyCreator.selector);
        l.initiatePayoutWalletChange(owner);
        vm.expectRevert(PolydashLaunch.OnlyFactory.selector);
        l.collectPlatformFees();
        vm.stopPrank();
        // even the factory address itself cannot change the payout wallet
        vm.prank(address(factory));
        vm.expectRevert(PolydashLaunch.OnlyCreator.selector);
        l.initiatePayoutWalletChange(address(factory));
        // re-initialisation is impossible
        PolydashLaunch.InitParams memory ip;
        vm.prank(address(factory));
        vm.expectRevert(PolydashLaunch.AlreadyInitialized.selector);
        l.initialize(ip);

        uint256 before = payout.balance;
        l.claimCreatorFees();
        assertEq(payout.balance - before, owed);
    }

    function test_DefaultPayoutIsCreator() public {
        PolydashFactory.LaunchParams memory p = _params(100, 0, 0);
        p.creatorPayoutWallet = address(0);
        (PolydashLaunch l2,) = _launchWith(p);
        assertEq(l2.creatorPayoutWallet(), creator);
    }

    function test_ReentrancyOnClaimBlocked() public {
        ReentrantPayout attacker = new ReentrantPayout();
        PolydashFactory.LaunchParams memory p = _params(200, 0, 0);
        p.creatorPayoutWallet = address(attacker);
        (PolydashLaunch l2,) = _launchWith(p);
        attacker.setLaunch(l2);
        _buy(l2, alice, 3 ether);
        uint256 owed = l2.creatorFeesAccrued();
        l2.claimCreatorFees();
        assertEq(address(attacker).balance, owed);
        assertEq(attacker.attempts(), 1);
        assertEq(attacker.successes(), 0, "all re-entrant calls reverted");
    }

    function test_RejectingOldWalletDoesNotBlockChange() public {
        RejectingWallet rej = new RejectingWallet();
        PolydashFactory.LaunchParams memory p = _params(100, 0, 0);
        p.creatorPayoutWallet = address(rej);
        (PolydashLaunch l2,) = _launchWith(p);
        _buy(l2, alice, 1 ether);
        uint256 owed = l2.creatorFeesAccrued();
        vm.prank(creator);
        l2.initiatePayoutWalletChange(payout);
        vm.warp(block.timestamp + 48 hours);
        l2.executePayoutWalletChange();
        assertEq(l2.creatorPayoutWallet(), payout);
        assertEq(l2.creatorFeesAccrued(), owed, "fees roll over to the new wallet");
    }

    function test_CurvePlusHookFeesClaimedTogetherAfterGraduation() public {
        _buy(l, bob, 1 ether);
        _graduate(l);
        uint256 curveOwed = l.creatorFeesAccrued();
        _v4Swap(l, bob, true, -1 ether);
        uint256 before = payout.balance;
        uint256 amt = l.claimCreatorFees();
        assertEq(amt, curveOwed + 1 ether * 150 / 10_000);
        assertEq(payout.balance - before, amt);
    }

    function test_ExecuteChangeAfterGraduationSweepsHookFeesToOldWallet() public {
        _graduate(l);
        l.claimCreatorFees();
        _v4Swap(l, bob, true, -1 ether);
        vm.prank(creator);
        l.initiatePayoutWalletChange(carol);
        vm.warp(block.timestamp + 48 hours);
        uint256 before = payout.balance;
        l.executePayoutWalletChange();
        assertEq(payout.balance - before, 1 ether * 150 / 10_000);
    }
}
