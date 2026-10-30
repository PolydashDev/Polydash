// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseV2Test} from "./BaseV2.t.sol";
import {PolydashStakingPoolV2} from "../../src/v2/PolydashStakingPoolV2.sol";
import {MockERC20Decimals} from "../mocks/MockERC20Decimals.sol";

contract FuzzV2Test is BaseV2Test {
    /// Principal always comes back in full and rewards are conserved: paid + fees + recovered
    /// equals what the creator deposited, up to a few base units of rounding dust.
    function testFuzz_stakeUnstakeClaim_conservation(
        uint256 rewards,
        uint8 rewardDec,
        uint256 a,
        uint256 b,
        uint256 t1,
        uint256 t2,
        uint256 w,
        uint256 feeBps
    ) public {
        rewardDec = uint8(bound(rewardDec, 6, 18));
        MockERC20Decimals r = _newToken("R", rewardDec);
        rewards = bound(rewards, 1, 1_000_000 * 10 ** rewardDec);
        a = bound(a, 1, 1_000_000_000 * E);
        b = bound(b, 1, 1_000_000_000 * E);
        feeBps = bound(feeBps, 100, 500);
        uint256 duration = 30 * DAY;
        PolydashStakingPoolV2 p = _createPool(stakeTok, r, rewards, duration, 0, feeBps);
        t1 = bound(t1, 0, duration - 1);
        t2 = bound(t2, 0, duration);
        w = bound(w, 1, a);

        uint256 aStake = stakeTok.balanceOf(alice);
        uint256 bStake = stakeTok.balanceOf(bob);
        vm.prank(alice);
        p.stake(a);
        vm.warp(block.timestamp + t1);
        vm.prank(bob);
        p.stake(b);
        vm.prank(alice);
        p.claim();
        vm.prank(alice);
        p.withdraw(w);
        vm.warp(p.endTime() + t2);
        if (p.balanceOf(alice) > 0) {
            vm.prank(alice);
            p.exit();
        } else {
            vm.prank(alice);
            p.claim();
        }
        vm.prank(bob);
        p.exit();

        assertEq(stakeTok.balanceOf(alice), aStake, "alice principal");
        assertEq(stakeTok.balanceOf(bob), bStake, "bob principal");
        assertEq(p.totalStaked(), 0);

        if (p.platformFeesAccrued() > 0) p.collectPlatformFees();
        if (p.creatorFeesAccrued() > 0) p.collectCreatorFees();
        if (p.pendingUnallocated() > 0) {
            vm.prank(creator);
            p.recoverUnallocated();
        }
        // only sub-unit dust may remain
        assertLe(r.balanceOf(address(p)), 3, "reward dust");
        assertLe(p.totalRewardsPaid(), rewards);
    }

    function testFuzz_claimFrequencyDoesNotChangeEarnings(uint256 amount, uint256 steps) public {
        amount = bound(amount, 1e6, 1_000_000_000 * E);
        steps = bound(steps, 1, 48);
        PolydashStakingPoolV2 p = _pool();
        vm.prank(alice);
        p.stake(amount);
        vm.prank(bob);
        p.stake(amount);
        uint256 a0 = rewardTok.balanceOf(alice);
        uint256 b0 = rewardTok.balanceOf(bob);
        uint256 dt = (10 * DAY) / steps;
        for (uint256 i = 1; i <= steps; i++) {
            vm.warp(p.startTime() + i * dt);
            vm.prank(alice);
            p.claim();
        }
        vm.warp(p.endTime());
        vm.prank(alice);
        p.claim();
        vm.prank(bob);
        p.claim();
        // Gross rewards are identical; the net can differ by at most one base unit per claim because
        // the claim fee rounds down on each payout (in the staker's favour).
        uint256 aNet = rewardTok.balanceOf(alice) - a0;
        uint256 bNet = rewardTok.balanceOf(bob) - b0;
        assertGe(aNet + 2, bNet);
        assertLe(aNet, bNet + steps + 3);
    }

    function testFuzz_stakeAmountsAndCap(uint256 a, uint256 cap) public {
        cap = bound(cap, 1, 1_000_000_000 * E);
        a = bound(a, 1, 1_000_000_000 * E);
        PolydashStakingPoolV2 p = _createPool(stakeTok, rewardTok, 1000 * E, 10 * DAY, cap, 100);
        vm.prank(alice);
        if (a > cap) vm.expectRevert(PolydashStakingPoolV2.CapExceeded.selector);
        p.stake(a);
        if (a <= cap) assertEq(p.balanceOf(alice), a);
    }
}
