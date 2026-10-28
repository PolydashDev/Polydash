// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {PolydashStakingFactory} from "../src/PolydashStakingFactory.sol";
import {PolydashStakingPool} from "../src/PolydashStakingPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

abstract contract BaseTest is Test {
    uint256 internal constant E = 1e18;
    uint256 internal constant DAY = 1 days;
    uint256 internal constant FEE_BPS = 100; // 1%

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    PolydashStakingFactory internal factory;
    MockERC20 internal token;

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        vm.prank(owner);
        factory = new PolydashStakingFactory(treasury, FEE_BPS);
        token = _newToken(0);
    }

    function _newToken(uint256 taxBps) internal returns (MockERC20 t) {
        t = new MockERC20("Polydash", "POLYDASH", taxBps);
        t.mint(creator, 1_000_000 * E);
        t.mint(alice, 1_000_000 * E);
        t.mint(bob, 1_000_000 * E);
        vm.prank(creator);
        t.approve(address(factory), type(uint256).max);
    }

    function _createPool(MockERC20 stakeTok, MockERC20 rewardTok, uint256 rewards, uint256 duration, uint256 cap)
        internal
        returns (PolydashStakingPool pool)
    {
        vm.prank(creator);
        pool = PolydashStakingPool(
            factory.createPool(
                address(stakeTok), address(rewardTok), rewards, 0, duration, cap, "Community Pool", "desc"
            )
        );
        vm.prank(alice);
        stakeTok.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        stakeTok.approve(address(pool), type(uint256).max);
    }
}
