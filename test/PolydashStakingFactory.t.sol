// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BaseTest} from "./Base.t.sol";
import {PolydashStakingFactory} from "../src/PolydashStakingFactory.sol";
import {PolydashStakingPool} from "../src/PolydashStakingPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract PolydashStakingFactoryTest is BaseTest {
    // ---------- constructor ----------

    function test_constructor_setsState() public view {
        assertEq(factory.owner(), owner);
        assertEq(factory.feeRecipient(), treasury);
        assertEq(factory.unstakeFeeBps(), FEE_BPS);
        assertEq(factory.MAX_UNSTAKE_FEE_BPS(), 500);
    }

    function test_constructor_revertsOnZeroRecipient() public {
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        new PolydashStakingFactory(address(0), 100);
    }

    function test_constructor_revertsOnFeeAboveCap() public {
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        new PolydashStakingFactory(treasury, 501);
    }

    // ---------- createPool ----------

    function test_createPool_registersAndFunds() public {
        PolydashStakingPool pool = _createPool(token, token, 100_000 * E, 10 * DAY, 0);
        assertEq(factory.poolsLength(), 1);
        assertEq(factory.allPools(0), address(pool));
        assertTrue(factory.isPool(address(pool)));
        assertEq(factory.poolsByCreator(creator)[0], address(pool));
        assertEq(pool.creator(), creator);
        assertEq(pool.factory(), address(factory));
        assertTrue(pool.funded());
        assertEq(pool.totalRewards(), 100_000 * E);
        assertEq(pool.startTime(), block.timestamp);
        assertEq(pool.endTime(), block.timestamp + 10 * DAY);
        assertEq(pool.unstakeFeeBps(), FEE_BPS);
        assertEq(pool.rewardRate(), (100_000 * E * 1e18) / (10 * DAY));
        assertEq(token.balanceOf(address(pool)), 100_000 * E);
        assertTrue(pool.isActive());
    }

    function test_createPool_feeOnTransferRewardUsesReceived() public {
        MockERC20 taxed = _newToken(300);
        PolydashStakingPool pool = _createPool(taxed, taxed, 100_000 * E, 10 * DAY, 0);
        assertEq(pool.totalRewards(), 97_000 * E);
    }

    function test_createPool_futureStart() public {
        uint256 start = block.timestamp + 7 days;
        vm.prank(creator);
        PolydashStakingPool pool =
            PolydashStakingPool(factory.createPool(address(token), address(token), 1000 * E, start, DAY, 0, "F", ""));
        assertEq(pool.startTime(), start);
        assertEq(pool.lastTimeRewardApplicable(), start);
    }

    function test_createPool_pastStartClampedToNow() public {
        vm.prank(creator);
        PolydashStakingPool pool =
            PolydashStakingPool(factory.createPool(address(token), address(token), 1000 * E, 1, DAY, 0, "P", ""));
        assertEq(pool.startTime(), block.timestamp);
    }

    function test_createPool_reverts_badParams() public {
        address t = address(token);
        vm.startPrank(creator);
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        factory.createPool(address(0), t, 1, 0, DAY, 0, "x", "");
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        factory.createPool(t, address(0), 1, 0, DAY, 0, "x", "");
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        factory.createPool(t, t, 0, 0, DAY, 0, "x", "");
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        factory.createPool(t, t, 1, 0, DAY - 1, 0, "x", ""); // < MIN_DURATION
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        factory.createPool(t, t, 1, 0, 3650 days + 1, 0, "x", ""); // > MAX_DURATION
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        factory.createPool(t, t, 1, 0, DAY, 0, "", ""); // empty name
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        factory.createPool(t, t, 1, 0, DAY, 0, string(new bytes(65)), "");
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        factory.createPool(t, t, 1, 0, DAY, 0, "x", string(new bytes(281)));
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        factory.createPool(t, t, 1, block.timestamp + 365 days + 1, DAY, 0, "x", "");
        vm.stopPrank();
    }

    function test_createPool_boundsInclusive() public {
        vm.startPrank(creator);
        factory.createPool(address(token), address(token), 1 * E, 0, 1 days, 0, string(new bytes(64)), "");
        factory.createPool(
            address(token), address(token), 1 * E, block.timestamp + 365 days, 3650 days, 0, "x", string(new bytes(280))
        );
        vm.stopPrank();
        assertEq(factory.poolsLength(), 2);
    }

    function testFuzz_createPool_validDuration(uint256 duration, uint256 amount) public {
        duration = bound(duration, 1 days, 3650 days);
        amount = bound(amount, 1, 1_000_000 * E);
        vm.prank(creator);
        PolydashStakingPool pool =
            PolydashStakingPool(factory.createPool(address(token), address(token), amount, 0, duration, 0, "fuzz", ""));
        assertEq(pool.endTime() - pool.startTime(), duration);
        assertEq(pool.totalRewards(), amount);
    }

    // ---------- views ----------

    function test_getPools_newestFirstAndPaging() public {
        PolydashStakingPool p0 = _createPool(token, token, 1000 * E, DAY, 0);
        PolydashStakingPool p1 = _createPool(token, token, 1000 * E, DAY, 0);
        PolydashStakingPool p2 = _createPool(token, token, 1000 * E, DAY, 0);
        PolydashStakingFactory.PoolInfo[] memory all = factory.getPools(0, 10);
        assertEq(all.length, 3);
        assertEq(all[0].pool, address(p2));
        assertEq(all[2].pool, address(p0));
        PolydashStakingFactory.PoolInfo[] memory page = factory.getPools(1, 1);
        assertEq(page.length, 1);
        assertEq(page[0].pool, address(p1));
        assertEq(factory.getPools(3, 10).length, 0);
        assertEq(all[0].stakeSymbol, "POLYDASH");
        assertEq(all[0].stakeDecimals, 18);
        assertEq(all[0].name, "Community Pool");
    }

    function test_getPoolInfo_nonMetadataTokenFallback() public {
        NoMeta nm = new NoMeta();
        nm.mint(creator, 100 * E);
        vm.startPrank(creator);
        nm.approve(address(factory), type(uint256).max);
        address pool = factory.createPool(address(nm), address(nm), 100 * E, 0, DAY, 0, "nm", "");
        vm.stopPrank();
        PolydashStakingFactory.PoolInfo memory info = factory.getPoolInfo(pool);
        assertEq(info.stakeSymbol, "???");
        assertEq(info.rewardDecimals, 18);
    }

    // ---------- admin ----------

    function test_setVerified() public {
        PolydashStakingPool pool = _createPool(token, token, 1000 * E, DAY, 0);
        vm.prank(owner);
        factory.setVerified(address(pool), true);
        assertTrue(factory.verified(address(pool)));
        assertTrue(factory.getPoolInfo(address(pool)).verified);
    }

    function test_setVerified_reverts() public {
        PolydashStakingPool pool = _createPool(token, token, 1000 * E, DAY, 0);
        vm.prank(alice);
        vm.expectRevert(PolydashStakingFactory.NotOwner.selector);
        factory.setVerified(address(pool), true);
        vm.prank(owner);
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        factory.setVerified(alice, true);
    }

    function test_setFeeRecipient() public {
        vm.prank(owner);
        factory.setFeeRecipient(bob);
        assertEq(factory.feeRecipient(), bob);
        vm.prank(owner);
        vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
        factory.setFeeRecipient(address(0));
        vm.prank(alice);
        vm.expectRevert(PolydashStakingFactory.NotOwner.selector);
        factory.setFeeRecipient(alice);
    }

    function testFuzz_setUnstakeFeeBps_cappedAt5Percent(uint256 bps) public {
        vm.prank(owner);
        if (bps > 500) {
            vm.expectRevert(PolydashStakingFactory.InvalidParams.selector);
            factory.setUnstakeFeeBps(bps);
        } else {
            factory.setUnstakeFeeBps(bps);
            assertEq(factory.unstakeFeeBps(), bps);
        }
    }

    function test_setUnstakeFeeBps_onlyAffectsFuturePools() public {
        PolydashStakingPool oldPool = _createPool(token, token, 1000 * E, DAY, 0);
        vm.prank(owner);
        factory.setUnstakeFeeBps(500);
        PolydashStakingPool newPool = _createPool(token, token, 1000 * E, DAY, 0);
        assertEq(oldPool.unstakeFeeBps(), FEE_BPS);
        assertEq(newPool.unstakeFeeBps(), 500);
        vm.prank(alice);
        vm.expectRevert(PolydashStakingFactory.NotOwner.selector);
        factory.setUnstakeFeeBps(0);
    }

    function test_ownership_twoStep() public {
        vm.prank(alice);
        vm.expectRevert(PolydashStakingFactory.NotOwner.selector);
        factory.transferOwnership(alice);

        vm.prank(owner);
        factory.transferOwnership(bob);
        assertEq(factory.pendingOwner(), bob);
        assertEq(factory.owner(), owner);

        vm.prank(alice);
        vm.expectRevert(PolydashStakingFactory.NotOwner.selector);
        factory.acceptOwnership();

        vm.prank(bob);
        factory.acceptOwnership();
        assertEq(factory.owner(), bob);
        assertEq(factory.pendingOwner(), address(0));

        vm.prank(owner);
        vm.expectRevert(PolydashStakingFactory.NotOwner.selector);
        factory.setUnstakeFeeBps(0);
    }
}

/// @dev ERC20 without symbol()/decimals() to exercise the metadata fallback.
contract NoMeta {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}
