// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashToken} from "../../src/PolydashToken.sol";
import {PolydashFactory} from "../../src/PolydashFactory.sol";

contract CommitmentsTest is BaseTest {
    PolydashLaunch l;
    PolydashToken t;

    function setUp() public override {
        super.setUp();
        (l, t) = _launchWith(_params(100, 0, 1 hours));
    }

    function test_PendingPhaseAndTooEarly() public {
        assertEq(uint8(l.phase()), uint8(PolydashLaunch.Phase.Pending));
        vm.expectRevert(PolydashLaunch.TooEarly.selector);
        l.goLive();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PolydashLaunch.WrongPhase.selector, PolydashLaunch.Phase.Pending));
        l.buy{value: 1 ether}(0);
    }

    function test_CommitAndUncommit() public {
        vm.prank(alice);
        l.commit{value: 1 ether}();
        vm.prank(alice);
        l.commit{value: 0.5 ether}();
        assertEq(l.commitments(alice), 1.5 ether);
        assertEq(l.totalCommitted(), 1.5 ether);
        assertEq(l.committersLength(), 1);

        uint256 before = alice.balance;
        vm.prank(alice);
        l.uncommit();
        assertEq(alice.balance - before, 1.5 ether);
        assertEq(l.totalCommitted(), 0);

        vm.prank(alice);
        vm.expectRevert(PolydashLaunch.NothingToClaim.selector);
        l.uncommit();
    }

    function test_CommitMinimum() public {
        vm.prank(alice);
        vm.expectRevert(PolydashLaunch.ZeroAmount.selector);
        l.commit{value: 0.00009 ether}();
    }

    function test_CannotUncommitAfterGoLive() public {
        vm.prank(alice);
        l.commit{value: 1 ether}();
        vm.warp(block.timestamp + 1 hours);
        l.goLive();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PolydashLaunch.WrongPhase.selector, PolydashLaunch.Phase.Trading));
        l.uncommit();
    }

    function test_CommitmentsExecutedAsBuysAtLaunch() public {
        vm.prank(alice);
        l.commit{value: 1 ether}();
        vm.prank(bob);
        l.commit{value: 2 ether}();
        vm.warp(block.timestamp + 1 hours);
        vm.prank(carol); // anyone can trigger
        l.goLive();
        assertEq(uint8(l.phase()), uint8(PolydashLaunch.Phase.Trading));
        assertGt(t.balanceOf(alice), 0);
        assertGt(t.balanceOf(alice) * 2, t.balanceOf(bob), "processed in order: earlier committer gets a better price");
        assertEq(l.platformFeesAccrued(), 3 ether * 20 / 10_000);
        assertEq(l.creatorFeesAccrued(), 3 ether * 100 / 10_000);
        assertEq(l.sniperTaxAccrued(), 0, "commitments are not anti-sniper taxed");
        assertEq(l.totalCommitted(), 0);
        assertEq(l.tradingStartBlock(), block.number);
    }

    function test_BatchesOverTwoHundredCommitters() public {
        uint256 n = 450;
        for (uint256 i; i < n; ++i) {
            address u = address(uint160(0x10000 + i));
            vm.deal(u, 1 ether);
            vm.prank(u);
            l.commit{value: 0.001 ether}();
        }
        vm.warp(block.timestamp + 1 hours);
        l.goLive();
        assertEq(uint8(l.phase()), uint8(PolydashLaunch.Phase.ProcessingCommitments));
        assertEq(l.commitmentCursor(), 200);

        vm.expectRevert(PolydashLaunch.InvalidParams.selector);
        l.processCommitmentBatch(201);
        vm.expectRevert(PolydashLaunch.InvalidParams.selector);
        l.processCommitmentBatch(0);

        // trading closed while processing
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(PolydashLaunch.WrongPhase.selector, PolydashLaunch.Phase.ProcessingCommitments)
        );
        l.buy{value: 1 ether}(0);

        l.processCommitmentBatch(200);
        assertEq(l.commitmentCursor(), 400);
        l.processCommitmentBatch(200);
        assertEq(l.commitmentCursor(), 450);
        assertEq(uint8(l.phase()), uint8(PolydashLaunch.Phase.Trading));
        assertGt(t.balanceOf(address(uint160(0x10000 + 449))), 0);
    }

    /// @dev Regression: graduation inside the first batch must not strand commitments beyond MAX_BATCH.
    function test_GraduationMidBatchLeavesLaterCommittersRefundable() public {
        uint256 n = 260;
        for (uint256 i; i < n; ++i) {
            address u = address(uint160(0x20000 + i));
            vm.deal(u, 1 ether);
            vm.prank(u);
            l.commit{value: 0.1 ether}(); // 200 * 0.1 = 20 ETH > 15 ETH threshold
        }
        vm.warp(block.timestamp + 1 hours);
        l.goLive();
        assertTrue(l.graduated());
        assertEq(l.commitmentCursor(), 200);

        address last = address(uint160(0x20000 + n - 1));
        assertEq(l.commitments(last), 0.1 ether);
        l.processCommitmentBatch(200); // must work after graduation
        assertEq(l.commitmentCursor(), n);
        assertEq(l.commitments(last), 0);
        assertEq(l.refunds(last), 0.1 ether);
        vm.expectRevert(abi.encodeWithSelector(PolydashLaunch.WrongPhase.selector, PolydashLaunch.Phase.Graduated));
        l.processCommitmentBatch(1); // nothing left
    }

    function test_WithdrawUnprocessedCommitmentAfterGraduation() public {
        for (uint256 i; i < 230; ++i) {
            address u = address(uint160(0x30000 + i));
            vm.deal(u, 1 ether);
            vm.prank(u);
            l.commit{value: 0.1 ether}();
        }
        vm.warp(block.timestamp + 1 hours);
        l.goLive();
        address last = address(uint160(0x30000 + 229));
        uint256 before = last.balance;
        vm.prank(last);
        l.withdrawUnprocessedCommitment();
        assertEq(last.balance - before, 0.1 ether);
        vm.prank(last);
        vm.expectRevert(PolydashLaunch.NothingToClaim.selector);
        l.withdrawUnprocessedCommitment();
        // processing later simply skips the withdrawn entry
        l.processCommitmentBatch(200);
        assertEq(l.refunds(last), 0);
        assertEq(l.totalCommitted(), 0);
    }

    function test_WithdrawUnprocessedOnlyAfterGraduation() public {
        vm.prank(alice);
        l.commit{value: 1 ether}();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PolydashLaunch.WrongPhase.selector, PolydashLaunch.Phase.Pending));
        l.withdrawUnprocessedCommitment();
    }

    function test_ImplementationCannotBeInitialized() public {
        PolydashLaunch impl = PolydashLaunch(payable(factory.launchImplementation()));
        PolydashLaunch.InitParams memory ip;
        vm.expectRevert(PolydashLaunch.AlreadyInitialized.selector);
        impl.initialize(ip);
    }

    function test_UncommittedEntriesSkipped() public {
        vm.prank(alice);
        l.commit{value: 1 ether}();
        vm.prank(alice);
        l.uncommit();
        vm.prank(bob);
        l.commit{value: 1 ether}();
        vm.warp(block.timestamp + 1 hours);
        l.goLive();
        assertEq(t.balanceOf(alice), 0);
        assertGt(t.balanceOf(bob), 0);
    }

    function test_OverThresholdCommitmentsRefunded() public {
        vm.prank(alice);
        l.commit{value: 14 ether}();
        vm.prank(bob);
        l.commit{value: 5 ether}();
        vm.prank(carol);
        l.commit{value: 1 ether}();
        vm.warp(block.timestamp + 1 hours);
        l.goLive();
        assertTrue(l.graduated());
        assertGt(l.refunds(bob), 0);
        assertLt(l.refunds(bob), 5 ether);
        assertEq(l.refunds(carol), 1 ether, "fully refunded after graduation");
        assertEq(l.totalRefunds(), l.refunds(bob) + l.refunds(carol));

        uint256 before = carol.balance;
        vm.prank(carol);
        l.claimRefund();
        assertEq(carol.balance - before, 1 ether);
        vm.prank(carol);
        vm.expectRevert(PolydashLaunch.NothingToClaim.selector);
        l.claimRefund();
    }

    function test_DevBuyStoredAndEmitted() public {
        PolydashFactory.LaunchParams memory p = _params(100, 1 ether, 0);
        vm.expectEmit(false, true, false, false);
        emit PolydashLaunch.DevBuyExecuted(creator, 0, 0);
        (PolydashLaunch l2, PolydashToken t2) = _launchWith(p);
        assertEq(l2.devBuyEth(), 1 ether);
        assertGt(l2.devBuyTokens(), 0);
        assertEq(t2.balanceOf(creator), l2.devBuyTokens());
        assertEq(l2.sniperTaxAccrued(), 0, "dev buy exempt from anti-sniper tax");
    }

    function test_DevBuyRunsBeforeCommitments() public {
        PolydashFactory.LaunchParams memory p = _params(100, 1 ether, 1 hours);
        (PolydashLaunch l2, PolydashToken t2) = _launchWith(p);
        vm.prank(alice);
        l2.commit{value: 1 ether}();
        vm.warp(block.timestamp + 1 hours);
        l2.goLive();
        assertGt(t2.balanceOf(creator), t2.balanceOf(alice), "dev bought first at a lower price");
    }

    function test_DevBuyValueMismatchReverts() public {
        PolydashFactory.LaunchParams memory p = _params(100, 1 ether, 0);
        vm.prank(creator);
        vm.expectRevert();
        factory.createLaunch{value: 0.5 ether}(p);
    }
}
