// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseV2Test} from "./BaseV2.t.sol";
import {PolydashStakingPoolV2} from "../../src/v2/PolydashStakingPoolV2.sol";
import {MockERC20Decimals} from "../mocks/MockERC20Decimals.sol";

contract PolydashStakingPoolV2Test is BaseV2Test {
    PolydashStakingPoolV2 internal pool;

    function setUp() public override {
        super.setUp();
        pool = _pool();
    }

    function test_stake() public {
        vm.prank(alice);
        pool.stake(100 * E);
        assertEq(pool.balanceOf(alice), 100 * E);
        assertEq(pool.totalStaked(), 100 * E);
        assertEq(pool.stakerCount(), 1);
        assertTrue(pool.isActive());
    }

    function test_stake_zeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(PolydashStakingPoolV2.ZeroAmount.selector);
        pool.stake(0);
    }

    function test_stake_capEnforced() public {
        PolydashStakingPoolV2 capped = _createPool(stakeTok, rewardTok, 1000 * E, 10 * DAY, 50 * E, 100);
        vm.prank(alice);
        capped.stake(50 * E);
        vm.prank(bob);
        vm.expectRevert(PolydashStakingPoolV2.CapExceeded.selector);
        capped.stake(1);
    }

    function test_rewards_proRata() public {
        vm.prank(alice);
        pool.stake(100 * E);
        vm.prank(bob);
        pool.stake(300 * E);
        vm.warp(block.timestamp + 10 * DAY);
        assertApproxEqAbs(pool.earned(alice), 25_000 * E, 1e6);
        assertApproxEqAbs(pool.earned(bob), 75_000 * E, 1e6);
    }

    function test_claim_paysNetAndAccruesFees() public {
        PolydashStakingPoolV2 p = _createPool(stakeTok, rewardTok, 100_000 * E, 10 * DAY, 0, 500);
        vm.prank(alice);
        p.stake(100 * E);
        vm.warp(block.timestamp + 10 * DAY);
        uint256 gross = p.earned(alice);
        uint256 before = rewardTok.balanceOf(alice);
        vm.prank(alice);
        p.claim();
        uint256 net = rewardTok.balanceOf(alice) - before;
        // 5% claim fee, 30% of it to the platform
        assertEq(net, gross - (gross * 500) / 10_000);
        assertEq(p.platformFeesAccrued(), (gross * 150) / 10_000);
        assertEq(p.platformFeesAccrued() + p.creatorFeesAccrued(), gross - net);
        assertEq(p.earned(alice), 0);

        p.collectPlatformFees();
        p.collectCreatorFees();
        assertEq(rewardTok.balanceOf(treasury), (gross * 150) / 10_000);
        vm.expectRevert(PolydashStakingPoolV2.ZeroAmount.selector);
        p.collectPlatformFees();
    }

    function test_claim_noRewardIsNoop() public {
        vm.prank(alice);
        pool.claim();
        assertEq(pool.totalRewardsPaid(), 0);
    }

    function test_unstake_returnsFullPrincipal() public {
        vm.prank(alice);
        pool.stake(100 * E);
        uint256 before = stakeTok.balanceOf(alice);
        vm.warp(block.timestamp + DAY);
        vm.prank(alice);
        pool.withdraw(40 * E);
        assertEq(stakeTok.balanceOf(alice) - before, 40 * E);
        assertEq(pool.stakerCount(), 1);
        vm.prank(alice);
        pool.exit();
        assertEq(stakeTok.balanceOf(alice) - before, 100 * E);
        assertEq(pool.stakerCount(), 0);
        assertGt(rewardTok.balanceOf(alice), 1_000_000_000 * E);
    }

    function test_withdraw_reverts() public {
        vm.prank(alice);
        vm.expectRevert(PolydashStakingPoolV2.ZeroAmount.selector);
        pool.withdraw(0);
        vm.prank(alice);
        vm.expectRevert(PolydashStakingPoolV2.InsufficientBalance.selector);
        pool.withdraw(1);
    }

    function test_emergencyWithdraw_forfeitsToCreator() public {
        vm.prank(alice);
        pool.stake(100 * E);
        vm.warp(block.timestamp + 5 * DAY);
        uint256 before = stakeTok.balanceOf(alice);
        vm.prank(alice);
        pool.emergencyWithdraw();
        assertEq(stakeTok.balanceOf(alice) - before, 100 * E);
        assertEq(pool.earned(alice), 0);
        vm.warp(block.timestamp + 5 * DAY);
        uint256 cBefore = rewardTok.balanceOf(creator);
        vm.prank(creator);
        pool.recoverUnallocated();
        assertApproxEqAbs(rewardTok.balanceOf(creator) - cBefore, 100_000 * E, 1);
    }

    function test_rewardPeriodEnd() public {
        vm.prank(alice);
        pool.stake(100 * E);
        vm.warp(pool.endTime());
        uint256 atEnd = pool.earned(alice);
        assertFalse(pool.isActive());
        vm.warp(pool.endTime() + 30 * DAY);
        assertEq(pool.earned(alice), atEnd, "no accrual after end");
        vm.prank(bob);
        vm.expectRevert(PolydashStakingPoolV2.PoolEnded.selector);
        pool.stake(1);
        // withdrawals and claims still work after the end
        vm.prank(alice);
        pool.exit();
        assertEq(pool.totalStaked(), 0);
    }

    function test_recoverUnallocated_onlyCreatorAfterEnd() public {
        vm.prank(creator);
        vm.expectRevert(PolydashStakingPoolV2.PoolNotEnded.selector);
        pool.recoverUnallocated();
        vm.warp(pool.endTime());
        vm.prank(alice);
        vm.expectRevert(PolydashStakingPoolV2.NotCreator.selector);
        pool.recoverUnallocated();
        vm.prank(creator);
        pool.recoverUnallocated(); // nobody staked: everything returns to the creator
        assertEq(rewardTok.balanceOf(address(pool)), 0);
    }

    function test_sameTokenPool_principalNotUsedForRewards() public {
        PolydashStakingPoolV2 p = _createPool(stakeTok, stakeTok, 1000 * E, 10 * DAY, 0, 100);
        vm.prank(alice);
        p.stake(500 * E);
        assertEq(p.principalBacking(), 500 * E);
        assertEq(p.rewardAvailable(), 1000 * E);
        vm.warp(p.endTime());
        uint256 before = stakeTok.balanceOf(alice);
        vm.prank(alice);
        p.exit();
        assertApproxEqAbs(stakeTok.balanceOf(alice) - before, 500 * E + 990 * E, 1e6);
    }
}
