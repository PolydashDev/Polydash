// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseV2Test} from "./BaseV2.t.sol";
import {PolydashStakingPoolV2} from "../../src/v2/PolydashStakingPoolV2.sol";
import {PolydashStakingFactory} from "../../src/PolydashStakingFactory.sol";
import {PolydashStakingPool} from "../../src/PolydashStakingPool.sol";
import {MockERC20Decimals} from "../mocks/MockERC20Decimals.sol";

/// 6-decimal reward token (USDC-like) streamed to a very large 18-decimal stake supply, with
/// an update every hour. Per update the reward per staked unit is far below 1e-18 of a token unit.
contract PrecisionV2Test is BaseV2Test {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant REWARDS = 10_000 * USDC;
    uint256 internal constant STAKE = 500_000_000 * E; // 5e26 per staker, 1e27 total
    uint256 internal constant DURATION = 30 * DAY;

    MockERC20Decimals internal usdc;

    function setUp() public override {
        super.setUp();
        usdc = _newToken("USDC", 6);
    }

    function test_v2_sixDecimalReward_largeStake_noLoss() public {
        PolydashStakingPoolV2 p = _createPool(stakeTok, usdc, REWARDS, DURATION, 0, 100);
        vm.prank(alice);
        p.stake(STAKE);
        vm.prank(bob);
        p.stake(STAKE);

        uint256 aliceStart = usdc.balanceOf(alice);
        uint256 bobStart = usdc.balanceOf(bob);
        // hourly updates via claims (the case that rounds to zero in v1)
        for (uint256 t = 1 hours; t <= DURATION; t += 1 hours) {
            vm.warp(p.startTime() + t);
            vm.prank(alice);
            p.claim();
        }
        vm.prank(alice);
        p.claim();
        vm.prank(bob);
        p.claim();
        p.collectPlatformFees();
        p.collectCreatorFees();
        vm.prank(creator);
        try p.recoverUnallocated() {} catch {}

        uint256 paidGross = p.totalRewardsPaid();
        // Each staker owns half; gross paid to stakers loses at most a few base units to rounding.
        assertGe(paidGross, REWARDS - 2, "rewards lost to rounding");
        uint256 aliceNet = usdc.balanceOf(alice) - aliceStart;
        uint256 bobNet = usdc.balanceOf(bob) - bobStart;
        // Bob claimed once; Alice claimed 721 times. Alice's net may exceed Bob's only by claim-fee
        // rounding (at most one base unit per claim, in the staker's favour); nothing is lost.
        assertApproxEqAbs(bobNet, (REWARDS / 2) * 99 / 100, 2, "single claimer");
        assertGe(aliceNet + 2, bobNet, "frequent claimer not penalised");
        assertLe(aliceNet, bobNet + 722, "difference bounded by fee rounding");
        // Everything that entered the pool left it (to stakers, fee recipients or the creator).
        assertLe(usdc.balanceOf(address(p)), 2);
    }

    /// Contrast with the legacy v1 pool under identical conditions: the reward accumulator
    /// rounds to zero on every update, so stakers receive nothing.
    function test_v1_sixDecimalReward_largeStake_losesRewards() public {
        vm.prank(owner);
        PolydashStakingFactory v1 = new PolydashStakingFactory(treasury, 100);
        vm.prank(creator);
        usdc.approve(address(v1), type(uint256).max);
        vm.prank(creator);
        PolydashStakingPool p =
            PolydashStakingPool(v1.createPool(address(stakeTok), address(usdc), REWARDS, 0, DURATION, 0, "v1", ""));
        vm.prank(alice);
        stakeTok.approve(address(p), type(uint256).max);
        vm.prank(alice);
        p.stake(2 * STAKE);
        uint256 start = usdc.balanceOf(alice);
        for (uint256 t = 1 hours; t <= DURATION; t += 1 hours) {
            vm.warp(p.startTime() + t);
            vm.prank(alice);
            p.claim();
        }
        assertEq(usdc.balanceOf(alice) - start, 0, "v1 pays nothing in this configuration");
    }
}
