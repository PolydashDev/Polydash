// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseV2Test} from "./BaseV2.t.sol";
import {PolydashStakingPoolV2} from "../../src/v2/PolydashStakingPoolV2.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC20Decimals} from "../mocks/MockERC20Decimals.sol";

contract EdgeCasesV2Test is BaseV2Test {
    function test_views() public {
        PolydashStakingPoolV2 p = _pool();
        vm.prank(alice);
        p.stake(100 * E);
        vm.warp(block.timestamp + DAY);
        uint256 gross = p.earned(alice);
        assertEq(p.claimable(alice), gross - (gross * 100) / 10_000);
        assertEq(p.earnedScaled(alice) / 1e36, gross);
        assertEq(p.sharesToAmount(10 * E), 10 * E);
        assertEq(p.pendingUnallocated(), 0);
        assertGt(p.rewardPerToken(), 0);
        assertEq(p.lastTimeRewardApplicable(), block.timestamp);
    }

    function test_futureStart_accruesNothingBeforeStart() public {
        vm.prank(creator);
        PolydashStakingPoolV2 p = PolydashStakingPoolV2(
            factory.createPool(
                address(stakeTok), address(rewardTok), 1000 * E, block.timestamp + DAY, DAY, 0, 100, "n", ""
            )
        );
        vm.startPrank(alice);
        stakeTok.approve(address(p), type(uint256).max);
        p.stake(E);
        vm.stopPrank();
        assertEq(p.lastTimeRewardApplicable(), p.startTime());
        vm.warp(p.startTime());
        assertEq(p.earned(alice), 0);
    }

    function test_feeOnTransferStakeToken_creditsReceived() public {
        MockERC20 taxed = new MockERC20("T", "T", 100); // 1% transfer tax
        taxed.mint(alice, 1000 * E);
        PolydashStakingPoolV2 p = _createPool(MockERC20Decimals(address(taxed)), rewardTok, 1000 * E, 10 * DAY, 0, 100);
        vm.startPrank(alice);
        taxed.approve(address(p), type(uint256).max);
        p.stake(100 * E);
        assertEq(p.balanceOf(alice), 99 * E);
        uint256 before = taxed.balanceOf(alice);
        p.withdraw(p.balanceOf(alice));
        vm.stopPrank();
        // the pool sends the full 99; the token's receiver-side tax is borne by the withdrawer
        assertEq(taxed.balanceOf(alice) - before, (99 * E * 99) / 100);
        assertEq(taxed.balanceOf(address(p)), 0);
        assertEq(p.totalStaked(), 0);
    }

    function test_initializeRewards_onlyFactory() public {
        PolydashStakingPoolV2 p = _pool();
        vm.expectRevert(PolydashStakingPoolV2.NotFactory.selector);
        p.initializeRewards();
        vm.prank(address(factory));
        vm.expectRevert(PolydashStakingPoolV2.AlreadyFunded.selector);
        p.initializeRewards();
    }

    function test_constructor_zeroAddressReverts() public {
        vm.expectRevert(PolydashStakingPoolV2.ZeroAddress.selector);
        new PolydashStakingPoolV2(address(0), address(stakeTok), address(rewardTok), 1, 2, 0, 100, "n", "");
    }

    function test_rewardShortfall_paysWhatExistsRestStaysOwed() public {
        PolydashStakingPoolV2 p = _pool();
        vm.prank(alice);
        p.stake(100 * E);
        vm.warp(p.endTime());
        // simulate a negative rebase on the reward token held by the pool
        uint256 bal = rewardTok.balanceOf(address(p));
        vm.prank(address(p));
        rewardTok.transfer(address(0xdead), bal / 2);
        vm.prank(alice);
        p.claim();
        assertGt(p.earned(alice), 0, "remainder stays owed");
        assertLe(p.totalRewardsPaid(), bal / 2);
    }
}
