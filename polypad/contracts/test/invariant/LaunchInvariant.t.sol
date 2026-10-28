// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashToken} from "../../src/PolydashToken.sol";
import {PolydashFactory} from "../../src/PolydashFactory.sol";

/// @dev Drives random buys / sells / claims / time travel against a single launch.
contract LaunchHandler is Test {
    PolydashLaunch public immutable l;
    PolydashToken public immutable t;
    PolydashFactory public immutable factory;
    address[] internal actors;

    uint256 public lastK;
    bool public kDecreased;
    uint256 public payoutReceived;
    uint256 public creatorFeesEverAccrued;
    uint256 public ghostBuys;
    uint256 public ghostSells;

    constructor(PolydashLaunch _l, PolydashFactory _f) {
        l = _l;
        t = PolydashToken(_l.token());
        factory = _f;
        for (uint256 i; i < 4; ++i) {
            address a = address(uint160(0xA11CE + i));
            actors.push(a);
            vm.deal(a, 10_000 ether);
        }
        lastK = l.ethReserve() * l.tokenReserve();
    }

    function _trackK() internal {
        if (l.graduated()) return;
        uint256 k = l.ethReserve() * l.tokenReserve();
        if (k < lastK) kDecreased = true;
        lastK = k;
    }

    function buy(uint256 actorSeed, uint256 amount) external {
        if (l.graduated()) return;
        address a = actors[actorSeed % actors.length];
        amount = bound(amount, 0.0001 ether, 3 ether);
        vm.prank(a);
        try l.buy{value: amount}(0) {
            ghostBuys++;
        } catch {}
        _trackK();
    }

    function sell(uint256 actorSeed, uint256 amount) external {
        if (l.graduated()) return;
        address a = actors[actorSeed % actors.length];
        uint256 bal = t.balanceOf(a);
        if (bal < 1e15) return;
        amount = bound(amount, 1e15, bal);
        vm.startPrank(a);
        t.approve(address(l), amount);
        try l.sell(amount, 0) {
            ghostSells++;
        } catch {}
        vm.stopPrank();
        _trackK();
    }

    function claimCreator(uint256 callerSeed) external {
        address caller = actors[callerSeed % actors.length];
        address wallet = l.creatorPayoutWallet();
        uint256 before = wallet.balance;
        vm.prank(caller);
        try l.claimCreatorFees() {
            payoutReceived += wallet.balance - before;
        } catch {}
    }

    function collectPlatform() external {
        try factory.collectPlatformFees(address(l)) {} catch {}
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 1, 10 minutes);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
    }
}

contract LaunchInvariantTest is BaseTest {
    PolydashLaunch l;
    PolydashToken t;
    LaunchHandler handler;

    function setUp() public override {
        super.setUp();
        (l, t) = _launch(150); // anti-sniper defaults left ON
        handler = new LaunchHandler(l, factory);
        targetContract(address(handler));
    }

    function invariant_PlatformFeeAlways20() public view {
        assertEq(l.PLATFORM_FEE_BPS(), 20);
        assertEq(factory.PLATFORM_FEE_BPS(), 20);
        assertEq(hook.PLATFORM_FEE_BPS(), 20);
    }

    function invariant_CreatorFeeBounded() public view {
        assertLe(l.creatorFeeBps(), 200);
        assertEq(l.creatorFeeBps(), 150);
    }

    function invariant_RaisedNeverExceedsThresholdBeforeGraduation() public view {
        if (!l.graduated()) assertLt(l.realEthRaised(), l.graduationThreshold());
    }

    function invariant_TokensSoldWithinCurveSupply() public view {
        assertLe(l.tokensSold(), l.curveSupply());
    }

    function invariant_Solvent() public view {
        uint256 owed = l.platformFeesAccrued() + l.creatorFeesAccrued() + l.totalRefunds();
        if (!l.graduated()) owed += l.realEthRaised() + l.sniperTaxAccrued();
        assertGe(address(l).balance, owed);
    }

    function invariant_KNeverDecreases() public view {
        assertFalse(handler.kDecreased());
    }

    function invariant_CreatorFeesOnlyToPayoutWallet() public view {
        // The payout wallet is never changed by the handler, so all claims landed there.
        assertEq(l.creatorPayoutWallet(), payout);
        assertEq(payout.balance, handler.payoutReceived());
    }

    function invariant_GraduatedLiquidityLocked() public view {
        if (l.graduated()) {
            uint128 locked = hook.lockedLiquidity(l.poolId());
            assertGt(locked, 0);
            assertEq(hook.positionLiquidity(l.poolId()), locked);
        }
    }
}
