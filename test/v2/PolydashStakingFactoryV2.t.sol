// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseV2Test} from "./BaseV2.t.sol";
import {PolydashStakingFactoryV2} from "../../src/v2/PolydashStakingFactoryV2.sol";
import {PolydashStakingPoolV2} from "../../src/v2/PolydashStakingPoolV2.sol";

contract PolydashStakingFactoryV2Test is BaseV2Test {
    function test_constructor() public view {
        assertEq(factory.owner(), owner);
        assertEq(factory.feeRecipient(), treasury);
    }

    function test_constructor_zeroRecipientReverts() public {
        vm.expectRevert(PolydashStakingFactoryV2.InvalidParams.selector);
        new PolydashStakingFactoryV2(address(0));
    }

    function test_createPool_registersAndFunds() public {
        PolydashStakingPoolV2 pool = _pool();
        assertTrue(factory.isPool(address(pool)));
        assertEq(factory.poolsLength(), 1);
        assertEq(factory.poolsByCreator(creator)[0], address(pool));
        assertEq(rewardTok.balanceOf(address(pool)), 100_000 * E);
        assertTrue(pool.funded());
        assertEq(pool.totalRewards(), 100_000 * E);
        PolydashStakingFactoryV2.PoolInfo memory info = factory.getPoolInfo(address(pool));
        assertEq(info.creator, creator);
        assertEq(info.claimFeeBps, 100);
        assertEq(info.endTime - info.startTime, 10 * DAY);
        address[] memory list = factory.getPoolAddresses(0, 10);
        assertEq(list.length, 1);
        assertEq(factory.getPoolAddresses(5, 10).length, 0);
    }

    function test_createPool_claimFeeCappedAtFivePercent() public {
        vm.startPrank(creator);
        vm.expectRevert(PolydashStakingFactoryV2.InvalidParams.selector);
        factory.createPool(address(stakeTok), address(rewardTok), E, 0, DAY, 0, 501, "n", "");
        vm.expectRevert(PolydashStakingFactoryV2.InvalidParams.selector);
        factory.createPool(address(stakeTok), address(rewardTok), E, 0, DAY, 0, 99, "n", "");
        factory.createPool(address(stakeTok), address(rewardTok), E, 0, DAY, 0, 500, "n", "");
        vm.stopPrank();
    }

    function test_createPool_invalidParams() public {
        vm.startPrank(creator);
        vm.expectRevert(PolydashStakingFactoryV2.InvalidParams.selector);
        factory.createPool(address(0), address(rewardTok), E, 0, DAY, 0, 100, "n", "");
        vm.expectRevert(PolydashStakingFactoryV2.InvalidParams.selector);
        factory.createPool(address(stakeTok), address(rewardTok), 0, 0, DAY, 0, 100, "n", "");
        vm.expectRevert(PolydashStakingFactoryV2.InvalidParams.selector);
        factory.createPool(address(stakeTok), address(rewardTok), E, 0, DAY - 1, 0, 100, "n", "");
        vm.expectRevert(PolydashStakingFactoryV2.InvalidParams.selector);
        factory.createPool(address(stakeTok), address(rewardTok), E, 0, DAY, 0, 100, "", "");
        vm.expectRevert(PolydashStakingFactoryV2.InvalidParams.selector);
        factory.createPool(address(stakeTok), address(rewardTok), E, block.timestamp + 366 days, DAY, 0, 100, "n", "");
        vm.stopPrank();
    }

    function test_admin_onlyOwner() public {
        PolydashStakingPoolV2 pool = _pool();
        vm.startPrank(alice);
        vm.expectRevert(PolydashStakingFactoryV2.NotOwner.selector);
        factory.setVerified(address(pool), true);
        vm.expectRevert(PolydashStakingFactoryV2.NotOwner.selector);
        factory.setFeeRecipient(alice);
        vm.expectRevert(PolydashStakingFactoryV2.NotOwner.selector);
        factory.transferOwnership(alice);
        vm.stopPrank();

        vm.prank(owner);
        factory.setVerified(address(pool), true);
        assertTrue(factory.verified(address(pool)));
        vm.prank(owner);
        vm.expectRevert(PolydashStakingFactoryV2.InvalidParams.selector);
        factory.setVerified(alice, true);
    }

    function test_twoStepOwnership() public {
        vm.prank(owner);
        factory.transferOwnership(alice);
        vm.prank(bob);
        vm.expectRevert(PolydashStakingFactoryV2.NotOwner.selector);
        factory.acceptOwnership();
        vm.prank(alice);
        factory.acceptOwnership();
        assertEq(factory.owner(), alice);
        assertEq(factory.pendingOwner(), address(0));
    }

    /// The factory owner has no path to pool funds: admin calls change only metadata, and
    /// creator-only / fee functions on the pool pay fixed recipients.
    function test_ownerCannotTouchPoolFunds() public {
        PolydashStakingPoolV2 pool = _pool();
        vm.prank(alice);
        pool.stake(1000 * E);
        uint256 stakeBal = stakeTok.balanceOf(address(pool));
        uint256 rewardBal = rewardTok.balanceOf(address(pool));

        vm.startPrank(owner);
        factory.setVerified(address(pool), true);
        factory.setFeeRecipient(owner);
        vm.expectRevert(PolydashStakingPoolV2.NotCreator.selector);
        pool.recoverUnallocated();
        vm.expectRevert(PolydashStakingPoolV2.NotFactory.selector);
        pool.initializeRewards();
        vm.expectRevert(PolydashStakingPoolV2.ZeroAmount.selector);
        pool.emergencyWithdraw();
        vm.stopPrank();

        assertEq(stakeTok.balanceOf(address(pool)), stakeBal);
        assertEq(rewardTok.balanceOf(address(pool)), rewardBal);
        assertEq(stakeTok.balanceOf(owner), 0);
        assertEq(rewardTok.balanceOf(owner), 0);
    }
}
