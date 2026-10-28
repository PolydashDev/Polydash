// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashToken} from "../../src/PolydashToken.sol";
import {PolydashCommitVault} from "../../src/PolydashCommitVault.sol";

contract ReenteringDepositor {
    PolydashCommitVault vault;
    address launch;
    bool attacked;

    constructor(PolydashCommitVault v, address l) {
        vault = v;
        launch = l;
    }

    function go() external payable {
        vault.deposit{value: msg.value}(launch);
        vault.withdraw(launch, msg.value);
    }

    receive() external payable {
        if (!attacked) {
            attacked = true;
            vault.withdraw(launch, 1); // must hit the reentrancy guard
        }
    }
}

contract RejectingDepositor {
    function dep(PolydashCommitVault v, address l) external payable {
        v.deposit{value: msg.value}(l);
    }
}

contract CommitVaultTest is BaseTest {
    PolydashCommitVault vault;
    PolydashLaunch l;
    PolydashToken t;

    function setUp() public override {
        super.setUp();
        vault = new PolydashCommitVault(address(factory));
        (l, t) = _launchWith(_params(100, 0, 1 hours));
    }

    function _dep(address who, uint256 amt) internal {
        vm.prank(who);
        vault.deposit{value: amt}(address(l));
    }

    function _goLive() internal {
        vm.warp(block.timestamp + 1 hours);
        l.goLive();
    }

    // ------------------------------------------------------------------ deposits / withdrawals

    function test_ConstructorRejectsZero() public {
        vm.expectRevert(PolydashCommitVault.InvalidParams.selector);
        new PolydashCommitVault(address(0));
    }

    function test_DepositForwardsToLaunch() public {
        _dep(alice, 1 ether);
        _dep(bob, 2 ether);
        _dep(alice, 0.5 ether);
        assertEq(l.commitments(address(vault)), 3.5 ether);
        assertEq(l.committersLength(), 1, "vault is a single committer");
        assertEq(vault.deposits(address(l), alice), 1.5 ether);
        (uint256 total,,,,,, uint256 depositors,) = vault.pools(address(l));
        assertEq(total, 3.5 ether);
        assertEq(depositors, 2);
        assertEq(address(vault).balance, 0, "vault holds no ETH");
    }

    function test_DepositRejectsNonLaunch() public {
        vm.prank(alice);
        vm.expectRevert(PolydashCommitVault.NotLaunch.selector);
        vault.deposit{value: 1 ether}(address(0xBEEF));
    }

    function test_DepositBelowMinimum() public {
        vm.prank(alice);
        vm.expectRevert(PolydashCommitVault.BelowMinimum.selector);
        vault.deposit{value: 0.00009 ether}(address(l));
    }

    function test_DepositOnlyWhilePending() public {
        _goLive();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PolydashCommitVault.WrongPhase.selector, uint8(3)));
        vault.deposit{value: 1 ether}(address(l));
    }

    function test_PartialAndFullWithdraw() public {
        _dep(alice, 1 ether);
        _dep(bob, 2 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        vault.withdraw(address(l), 0.4 ether);
        assertEq(alice.balance - before, 0.4 ether);
        assertEq(l.commitments(address(vault)), 2.6 ether, "rest recommitted");
        vm.prank(alice);
        vault.withdraw(address(l), 0.6 ether);
        assertEq(vault.deposits(address(l), alice), 0);
        (,,,,,, uint256 depositors,) = vault.pools(address(l));
        assertEq(depositors, 1);
        vm.prank(bob);
        vault.withdraw(address(l), 2 ether);
        assertEq(l.commitments(address(vault)), 0);
        assertEq(address(vault).balance, 0);
    }

    function test_WithdrawValidation() public {
        _dep(alice, 1 ether);
        vm.startPrank(alice);
        vm.expectRevert(PolydashCommitVault.InsufficientDeposit.selector);
        vault.withdraw(address(l), 0);
        vm.expectRevert(PolydashCommitVault.InsufficientDeposit.selector);
        vault.withdraw(address(l), 1 ether + 1);
        vm.expectRevert(PolydashCommitVault.BelowMinimum.selector);
        vault.withdraw(address(l), 1 ether - 1);
        vm.stopPrank();
    }

    function test_WithdrawAfterLiveReverts() public {
        _dep(alice, 1 ether);
        _goLive();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PolydashCommitVault.WrongPhase.selector, uint8(3)));
        vault.withdraw(address(l), 1 ether);
    }

    function test_RejectsStrayEth() public {
        vm.prank(alice);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_ReentrancyBlocked() public {
        ReenteringDepositor r = new ReenteringDepositor(vault, address(l));
        vm.deal(address(r), 0);
        vm.expectRevert(PolydashCommitVault.EthTransferFailed.selector);
        r.go{value: 1 ether}();
    }

    // ------------------------------------------------------------------ settlement / claims

    function test_FairPriceProRata() public {
        _dep(alice, 1 ether);
        _dep(bob, 3 ether);
        _goLive();
        assertEq(uint8(l.phase()), uint8(PolydashLaunch.Phase.Trading));

        uint256 received = t.balanceOf(address(vault));
        assertGt(received, 0);
        vault.settle(address(l));
        (uint256 aTok,) = vault.pendingClaim(address(l), alice);
        (, uint256 tokRecv,,,,,,) = vault.pools(address(l));
        assertEq(tokRecv, received);

        vm.prank(alice);
        (uint256 ta, uint256 ea) = vault.claim(address(l));
        assertEq(ta, aTok);
        assertEq(ea, 0);
        assertEq(ta, received / 4, "alice: exactly 1/4");
        vm.prank(carol); // anyone can push bob's share
        (uint256 tb,) = vault.claimFor(address(l), bob);
        assertEq(ta + tb, received, "no dust left");
        assertEq(t.balanceOf(address(vault)), 0);
        assertEq(t.balanceOf(bob), tb);
    }

    function test_PooledBeatsLateDirectCommitter() public {
        // direct committer commits before the vault -> gets the better price. Inside the vault, alice and bob
        // get the SAME price regardless of deposit order.
        vm.prank(carol);
        l.commit{value: 1 ether}();
        _dep(alice, 1 ether);
        _dep(bob, 1 ether);
        _goLive();
        vault.claimFor(address(l), alice);
        vault.claimFor(address(l), bob);
        uint256 diff = t.balanceOf(alice) > t.balanceOf(bob)
            ? t.balanceOf(alice) - t.balanceOf(bob)
            : t.balanceOf(bob) - t.balanceOf(alice);
        assertLe(diff, 1, "equal price inside the pool");
    }

    function test_SettleTooEarly() public {
        _dep(alice, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(PolydashCommitVault.WrongPhase.selector, uint8(1)));
        vault.settle(address(l));
        vm.expectRevert(PolydashCommitVault.NotLaunch.selector);
        vault.settle(address(0xBEEF));
    }

    function test_SettleTwiceAndDoubleClaim() public {
        _dep(alice, 1 ether);
        _goLive();
        vault.settle(address(l));
        vm.expectRevert(PolydashCommitVault.AlreadySettled.selector);
        vault.settle(address(l));
        vm.prank(alice);
        vault.claim(address(l));
        vm.prank(alice);
        vm.expectRevert(PolydashCommitVault.NothingToClaim.selector);
        vault.claim(address(l));
        vm.prank(bob);
        vm.expectRevert(PolydashCommitVault.NothingToClaim.selector);
        vault.claim(address(l));
        (uint256 a, uint256 b) = vault.pendingClaim(address(l), alice);
        assertEq(a + b, 0);
    }

    function test_PendingClaimBeforeSettleIsZero() public {
        _dep(alice, 1 ether);
        (uint256 a, uint256 b) = vault.pendingClaim(address(l), alice);
        assertEq(a + b, 0);
    }

    function test_OverThresholdRefundSplitProRata() public {
        _dep(alice, 10 ether);
        _dep(bob, 10 ether); // 20 ETH pooled vs 15 ETH threshold
        _goLive();
        assertTrue(l.graduated());
        uint256 refund = l.refunds(address(vault));
        assertGt(refund, 0);
        uint256 a0 = alice.balance;
        vm.prank(alice);
        (uint256 ta, uint256 ea) = vault.claim(address(l)); // settles + pulls refund
        assertEq(alice.balance - a0, ea);
        assertEq(ea, refund / 2);
        (uint256 tb, uint256 eb) = vault.claimFor(address(l), bob);
        assertEq(ea + eb, refund);
        assertEq(ta + tb, t.balanceOf(alice) + t.balanceOf(bob));
        assertEq(address(vault).balance, 0);
        assertEq(t.balanceOf(address(vault)), 0);
    }

    function test_UnprocessedAfterGraduationIsPulledBack() public {
        // 210 direct committers graduate the launch in the first batch; the vault is committer #211.
        for (uint256 i; i < 210; ++i) {
            address u = address(uint160(0x40000 + i));
            vm.deal(u, 1 ether);
            vm.prank(u);
            l.commit{value: 0.1 ether}();
        }
        _dep(alice, 1 ether);
        _dep(bob, 1 ether);
        _goLive();
        assertTrue(l.graduated());
        assertEq(l.commitments(address(vault)), 2 ether, "not processed yet");

        uint256 b0 = alice.balance;
        vm.prank(alice);
        (uint256 ta, uint256 ea) = vault.claim(address(l));
        assertEq(ta, 0);
        assertEq(ea, 1 ether);
        assertEq(alice.balance - b0, 1 ether);
        (, uint256 eb) = vault.claimFor(address(l), bob);
        assertEq(eb, 1 ether);
        assertEq(l.commitments(address(vault)), 0);
    }

    function test_NotProcessedWhileProcessing() public {
        for (uint256 i; i < 205; ++i) {
            address u = address(uint160(0x50000 + i));
            vm.deal(u, 1 ether);
            vm.prank(u);
            l.commit{value: 0.001 ether}();
        }
        _dep(alice, 1 ether);
        _goLive();
        assertEq(uint8(l.phase()), uint8(PolydashLaunch.Phase.ProcessingCommitments));
        vm.expectRevert(PolydashCommitVault.NotProcessed.selector);
        vault.settle(address(l));
        l.processCommitmentBatch(200);
        vault.settle(address(l));
        vm.prank(alice);
        (uint256 ta,) = vault.claim(address(l));
        assertGt(ta, 0);
    }

    function test_ClaimToRejectingContractReverts() public {
        RejectingDepositor r = new RejectingDepositor();
        vm.deal(address(r), 0);
        r.dep{value: 10 ether}(vault, address(l));
        _dep(bob, 10 ether);
        _goLive(); // over threshold -> ETH refunds owed
        vm.expectRevert(PolydashCommitVault.EthTransferFailed.selector);
        vault.claimFor(address(l), address(r));
        // other depositors are unaffected
        vault.claimFor(address(l), bob);
    }

    function test_EmptyPoolSettles() public {
        _goLive();
        vault.settle(address(l));
        (,,,,,,, bool settled) = vault.pools(address(l));
        assertTrue(settled);
    }

    function testFuzz_ProRataConservation(uint96 a, uint96 b, uint96 c) public {
        uint256 da = bound(a, 0.0001 ether, 6 ether);
        uint256 db = bound(b, 0.0001 ether, 6 ether);
        uint256 dc = bound(c, 0.0001 ether, 6 ether);
        _dep(alice, da);
        _dep(bob, db);
        _dep(carol, dc);
        _goLive();
        vault.settle(address(l));
        (, uint256 tokRecv, uint256 ethRef,,,,,) = vault.pools(address(l));
        (uint256 t1, uint256 e1) = vault.claimFor(address(l), alice);
        (uint256 t2, uint256 e2) = vault.claimFor(address(l), bob);
        (uint256 t3, uint256 e3) = vault.claimFor(address(l), carol);
        assertEq(t1 + t2 + t3, tokRecv);
        assertEq(e1 + e2 + e3, ethRef);
        assertEq(t.balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 0);
        // pro-rata within 1 wei of rounding
        assertApproxEqAbs(t1, tokRecv * da / (da + db + dc), 1);
    }
}
