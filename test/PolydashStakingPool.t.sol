// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./Base.t.sol";
import {PolydashStakingPool} from "../src/PolydashStakingPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PolydashStakingPoolTest is BaseTest {
    PolydashStakingPool internal pool;
    uint256 internal constant REWARDS = 100_000 * E;
    uint256 internal constant DURATION = 10 * DAY;

    function setUp() public override {
        super.setUp();
        pool = _createPool(token, token, REWARDS, DURATION, 0);
    }

    // ---------- access / init ----------

    function test_initializeRewards_onlyFactoryOnce() public {
        vm.expectRevert(PolydashStakingPool.NotFactory.selector);
        pool.initializeRewards();
        vm.prank(address(factory));
        vm.expectRevert(PolydashStakingPool.AlreadyFunded.selector);
        pool.initializeRewards();
    }

    function test_initializeRewards_zeroBalanceReverts() public {
        PolydashStakingPool p = new PolydashStakingPool(
            creator, address(token), address(token), block.timestamp, block.timestamp + DAY, 0, 0, "n", ""
        );
        vm.expectRevert(PolydashStakingPool.ZeroAmount.selector);
        p.initializeRewards();
        vm.expectRevert(PolydashStakingPool.NotFunded.selector);
        p.stake(1);
    }

    // ---------- stake ----------

    function test_stake() public {
        vm.prank(alice);
        pool.stake(1000 * E);
        assertEq(pool.balanceOf(alice), 1000 * E);
        assertEq(pool.totalStaked(), 1000 * E);
        assertEq(pool.stakerCount(), 1);
        vm.prank(alice);
        pool.stake(1000 * E);
        assertEq(pool.stakerCount(), 1);
    }

    function test_stake_reverts() public {
        vm.prank(alice);
        vm.expectRevert(PolydashStakingPool.ZeroAmount.selector);
        pool.stake(0);
        vm.warp(pool.endTime());
        vm.prank(alice);
        vm.expectRevert(PolydashStakingPool.PoolEnded.selector);
        pool.stake(1 * E);
        assertFalse(pool.isActive());
    }

    function test_stake_capEnforced() public {
        PolydashStakingPool capped = _createPool(token, token, 1000 * E, DAY, 500 * E);
        vm.prank(alice);
        vm.expectRevert(PolydashStakingPool.CapExceeded.selector);
        capped.stake(600 * E);
        vm.prank(alice);
        capped.stake(500 * E);
        vm.prank(bob);
        vm.expectRevert(PolydashStakingPool.CapExceeded.selector);
        capped.stake(1);
    }

    function test_stake_feeOnTransferCreditsReceived() public {
        MockERC20 taxed = _newToken(300);
        PolydashStakingPool p = _createPool(taxed, taxed, 100_000 * E, DURATION, 0);
        vm.prank(alice);
        p.stake(1000 * E);
        assertEq(p.balanceOf(alice), 970 * E);
    }

    function test_stake_beforeStartAccruesNothing() public {
        uint256 start = block.timestamp + 2 days;
        vm.prank(creator);
        PolydashStakingPool p =
            PolydashStakingPool(factory.createPool(address(token), address(token), 1000 * E, start, DAY, 0, "F", ""));
        vm.startPrank(alice);
        token.approve(address(p), type(uint256).max);
        p.stake(10 * E);
        vm.warp(start);
        assertEq(p.earned(alice), 0);
        vm.warp(start + DAY);
        assertApproxEqAbs(p.earned(alice), 1000 * E, 1e6);
        vm.stopPrank();
    }

    // ---------- reward accounting ----------

    function test_rewards_proRata() public {
        vm.warp(block.timestamp + DAY); // 1 day with no stakers -> unallocated
        vm.prank(alice);
        pool.stake(1000 * E);
        vm.prank(bob);
        pool.stake(3000 * E);
        vm.warp(block.timestamp + 4 * DAY);
        uint256 ea = pool.earned(alice);
        uint256 eb = pool.earned(bob);
        assertApproxEqRel(eb, ea * 3, 1e14);
        assertApproxEqAbs(ea + eb, (REWARDS * 4) / 10, 1e6);
        assertApproxEqAbs(pool.pendingUnallocated(), REWARDS / 10, 1e6);
    }

    function test_fullLifecycle_paidPlusRecoveredEqualsTotal() public {
        vm.warp(block.timestamp + DAY);
        vm.prank(alice);
        pool.stake(1000 * E);
        vm.prank(bob);
        pool.stake(3000 * E);
        vm.warp(block.timestamp + 4 * DAY);

        // withdraw with 1% fee to treasury
        uint256 tb = token.balanceOf(treasury);
        uint256 ab = token.balanceOf(alice);
        vm.prank(alice);
        pool.withdraw(1000 * E);
        assertEq(token.balanceOf(treasury) - tb, 10 * E);
        assertEq(token.balanceOf(alice) - ab, 990 * E);
        assertEq(pool.stakerCount(), 1);
        vm.prank(alice);
        pool.claim();

        vm.prank(creator);
        vm.expectRevert(PolydashStakingPool.PoolNotEnded.selector);
        pool.recoverUnallocated();

        vm.warp(block.timestamp + 10 * DAY);
        vm.prank(bob);
        pool.exit();
        assertEq(pool.totalStaked(), 0);
        assertEq(pool.stakerCount(), 0);

        uint256 cb = token.balanceOf(creator);
        vm.prank(creator);
        pool.recoverUnallocated();
        uint256 recovered = token.balanceOf(creator) - cb;
        assertApproxEqAbs(recovered, REWARDS / 10, 1e6);
        assertApproxEqAbs(pool.totalRewardsPaid() + recovered, REWARDS, 1e6);
        assertLt(token.balanceOf(address(pool)), 1e8); // dust only

        vm.prank(creator);
        vm.expectRevert(PolydashStakingPool.ZeroAmount.selector);
        pool.recoverUnallocated();
    }

    function test_recoverUnallocated_onlyCreator() public {
        vm.warp(pool.endTime());
        vm.prank(alice);
        vm.expectRevert(PolydashStakingPool.NotCreator.selector);
        pool.recoverUnallocated();
        vm.prank(creator);
        pool.recoverUnallocated(); // nobody staked -> everything back (minus rounding dust)
        assertApproxEqAbs(token.balanceOf(creator), 1_000_000 * E, 1e6);
    }

    function test_claim_noRewardIsNoop() public {
        vm.prank(alice);
        pool.claim();
        assertEq(pool.totalRewardsPaid(), 0);
    }

    // ---------- withdraw ----------

    function test_withdraw_reverts() public {
        vm.startPrank(alice);
        vm.expectRevert(PolydashStakingPool.ZeroAmount.selector);
        pool.withdraw(0);
        pool.stake(10 * E);
        vm.expectRevert(PolydashStakingPool.InsufficientBalance.selector);
        pool.withdraw(11 * E);
        vm.stopPrank();
    }

    function test_withdraw_partialKeepsStakerCount() public {
        vm.startPrank(alice);
        pool.stake(10 * E);
        pool.withdraw(5 * E);
        vm.stopPrank();
        assertEq(pool.stakerCount(), 1);
        assertEq(pool.balanceOf(alice), 5 * E);
    }

    function test_withdraw_zeroFeePool() public {
        vm.prank(owner);
        factory.setUnstakeFeeBps(0);
        PolydashStakingPool p = _createPool(token, token, 1000 * E, DAY, 0);
        uint256 tb = token.balanceOf(treasury);
        vm.startPrank(alice);
        p.stake(100 * E);
        p.withdraw(100 * E);
        vm.stopPrank();
        assertEq(token.balanceOf(treasury), tb);
        assertEq(token.balanceOf(alice), 1_000_000 * E);
    }

    function test_withdraw_feeGoesToCurrentRecipient() public {
        vm.prank(alice);
        pool.stake(100 * E);
        vm.prank(owner);
        factory.setFeeRecipient(bob);
        uint256 bb = token.balanceOf(bob);
        vm.prank(alice);
        pool.withdraw(100 * E);
        assertEq(token.balanceOf(bob) - bb, 1 * E);
    }

    // ---------- emergencyWithdraw ----------

    function test_emergencyWithdraw_forfeitsToCreator() public {
        MockERC20 rew = new MockERC20("R", "R", 0);
        rew.mint(creator, 1000 * E);
        vm.prank(creator);
        rew.approve(address(factory), type(uint256).max);
        PolydashStakingPool p = _createPool(token, rew, 1000 * E, DAY, 500 * E);

        vm.prank(alice);
        p.stake(500 * E);
        vm.warp(block.timestamp + 3600);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        p.emergencyWithdraw();
        assertEq(token.balanceOf(alice) - before, 495 * E); // 1% fee still applies
        assertEq(rew.balanceOf(alice), 0);
        assertEq(p.balanceOf(alice), 0);
        assertEq(p.stakerCount(), 0);
        assertEq(p.rewards(alice), 0);

        vm.prank(alice);
        vm.expectRevert(PolydashStakingPool.ZeroAmount.selector);
        p.emergencyWithdraw();

        vm.warp(block.timestamp + DAY);
        vm.prank(creator);
        p.recoverUnallocated();
        assertGe(rew.balanceOf(creator), 1000 * E - 1e6);
    }

    function test_emergencyWithdraw_afterAccruedRewardsStored() public {
        vm.startPrank(alice);
        pool.stake(100 * E);
        vm.warp(block.timestamp + DAY);
        pool.stake(100 * E); // stores rewards[alice]
        assertGt(pool.rewards(alice), 0);
        vm.warp(block.timestamp + DAY);
        pool.emergencyWithdraw();
        vm.stopPrank();
        vm.warp(pool.endTime());
        vm.prank(creator);
        pool.recoverUnallocated();
        assertApproxEqAbs(token.balanceOf(creator), 1_000_000 * E, 1e6);
    }

    // ---------- fuzz ----------

    /// Two stakers, random amounts and timings: total paid + recoverable never exceeds rewards.
    function testFuzz_conservation(uint256 a, uint256 b, uint256 t1, uint256 t2) public {
        a = bound(a, 1, 500_000 * E);
        b = bound(b, 1, 500_000 * E);
        t1 = bound(t1, 0, DURATION);
        t2 = bound(t2, 0, DURATION);
        vm.prank(alice);
        pool.stake(a);
        vm.warp(block.timestamp + t1);
        if (block.timestamp < pool.endTime()) {
            vm.prank(bob);
            pool.stake(b);
        }
        vm.warp(block.timestamp + t2);
        vm.prank(alice);
        pool.exit();
        if (pool.balanceOf(bob) > 0) {
            vm.prank(bob);
            pool.exit();
        }
        uint256 paid = pool.totalRewardsPaid();
        uint256 unalloc = pool.pendingUnallocated();
        assertLe(paid, REWARDS);
        uint256 remaining = REWARDS
            - ((block.timestamp >= pool.endTime() ? DURATION : block.timestamp - pool.startTime()) * pool.rewardRate())
            / 1e18;
        assertApproxEqAbs(paid + unalloc + remaining, REWARDS, 1e7);
        assertEq(pool.totalStaked(), 0);
        assertEq(pool.stakerCount(), 0);
    }

    function testFuzz_unstakeFee(uint256 amount, uint256 bps) public {
        bps = bound(bps, 0, 500);
        amount = bound(amount, 1, 1_000_000 * E);
        vm.prank(owner);
        factory.setUnstakeFeeBps(bps);
        PolydashStakingPool p = _createPool(token, token, 1000 * E, DAY, 0);
        uint256 tb = token.balanceOf(treasury);
        vm.startPrank(alice);
        p.stake(amount);
        p.withdraw(amount);
        vm.stopPrank();
        uint256 fee = token.balanceOf(treasury) - tb;
        assertEq(fee, (amount * bps) / 10_000);
        assertLe(fee, amount / 20);
        assertEq(token.balanceOf(alice), 1_000_000 * E - fee);
    }
}
