// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "../utils/BaseTest.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashToken} from "../../src/PolydashToken.sol";

/// @dev Trader whose receive() tries to re-enter buy / sell / claimRefund / uncommit.
contract ReentrantTrader {
    PolydashLaunch public immutable launch;
    bool public armed;
    uint256 public reentrySucceeded;
    uint256 public reentryAttempted;

    constructor(PolydashLaunch l) {
        launch = l;
    }

    function arm() external {
        armed = true;
    }

    function doBuy() external payable {
        launch.buy{value: msg.value}(0);
    }

    function doSell(uint256 amount) external {
        PolydashToken(launch.token()).approve(address(launch), type(uint256).max);
        launch.sell(amount, 0);
    }

    function doCommit() external payable {
        launch.commit{value: msg.value}();
    }

    function doUncommit() external {
        launch.uncommit();
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        reentryAttempted++;
        (bool a,) = address(launch).call{value: 0.01 ether}(abi.encodeCall(PolydashLaunch.buy, (0)));
        (bool b,) = address(launch).call(abi.encodeCall(PolydashLaunch.sell, (1e18, 0)));
        (bool c,) = address(launch).call(abi.encodeCall(PolydashLaunch.claimRefund, ()));
        (bool d,) = address(launch).call(abi.encodeCall(PolydashLaunch.claimCreatorFees, ()));
        if (a || b || c || d) reentrySucceeded++;
    }
}

contract ReentrancyTest is BaseTest {
    PolydashLaunch l;
    ReentrantTrader trader;

    function setUp() public override {
        super.setUp();
        _disableAntiSniper();
        (l,) = _launch(100);
        trader = new ReentrantTrader(l);
        vm.deal(address(trader), 100 ether);
    }

    function test_ReentrancyOnSellBlocked() public {
        trader.doBuy{value: 1 ether}();
        trader.arm();
        uint256 bal = PolydashToken(l.token()).balanceOf(address(trader));
        trader.doSell(bal / 2);
        assertEq(trader.reentryAttempted(), 1);
        assertEq(trader.reentrySucceeded(), 0);
    }

    function test_ReentrancyOnBuyRefundBlocked() public {
        trader.arm();
        trader.doBuy{value: 40 ether}(); // over threshold -> refund triggers receive()
        assertTrue(l.graduated());
        assertEq(trader.reentryAttempted(), 1);
        assertEq(trader.reentrySucceeded(), 0);
    }

    function test_ReentrancyOnUncommitBlocked() public {
        (PolydashLaunch l2,) = _launchWith(_params(100, 0, 1 hours));
        ReentrantTrader tr = new ReentrantTrader(l2);
        vm.deal(address(tr), 10 ether);
        tr.doCommit{value: 1 ether}();
        tr.arm();
        tr.doUncommit();
        assertEq(tr.reentryAttempted(), 1);
        assertEq(tr.reentrySucceeded(), 0);
        assertEq(l2.totalCommitted(), 0);
    }
}
