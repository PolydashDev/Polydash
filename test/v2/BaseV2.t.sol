// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PolydashStakingFactoryV2} from "../../src/v2/PolydashStakingFactoryV2.sol";
import {PolydashStakingPoolV2} from "../../src/v2/PolydashStakingPoolV2.sol";
import {MockERC20Decimals} from "../mocks/MockERC20Decimals.sol";

abstract contract BaseV2Test is Test {
    uint256 internal constant E = 1e18;
    uint256 internal constant DAY = 1 days;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    PolydashStakingFactoryV2 internal factory;
    MockERC20Decimals internal stakeTok;
    MockERC20Decimals internal rewardTok;

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        vm.prank(owner);
        factory = new PolydashStakingFactoryV2(treasury);
        stakeTok = _newToken("Stake", 18);
        rewardTok = _newToken("Reward", 18);
    }

    function _newToken(string memory sym, uint8 dec) internal returns (MockERC20Decimals t) {
        t = new MockERC20Decimals(sym, sym, dec);
        uint256 unit = 10 ** dec;
        t.mint(creator, 1_000_000_000 * unit);
        t.mint(alice, 1_000_000_000 * unit);
        t.mint(bob, 1_000_000_000 * unit);
        vm.prank(creator);
        t.approve(address(factory), type(uint256).max);
    }

    function _createPool(
        MockERC20Decimals s,
        MockERC20Decimals r,
        uint256 rewards,
        uint256 duration,
        uint256 cap,
        uint256 feeBps
    ) internal returns (PolydashStakingPoolV2 pool) {
        vm.prank(creator);
        pool = PolydashStakingPoolV2(
            factory.createPool(address(s), address(r), rewards, 0, duration, cap, feeBps, "Community Pool", "desc")
        );
        vm.prank(alice);
        s.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        s.approve(address(pool), type(uint256).max);
    }

    function _pool() internal returns (PolydashStakingPoolV2) {
        return _createPool(stakeTok, rewardTok, 100_000 * E, 10 * DAY, 0, 100);
    }
}
