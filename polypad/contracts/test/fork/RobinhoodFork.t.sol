// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {PolydashFactory} from "../../src/PolydashFactory.sol";
import {PolydashLaunch} from "../../src/PolydashLaunch.sol";
import {PolydashHook} from "../../src/PolydashHook.sol";
import {PolydashCommitVault} from "../../src/PolydashCommitVault.sol";
import {HookPermissions} from "../../src/libraries/HookPermissions.sol";
import {HookMiner} from "../../script/HookMiner.s.sol";

/// @notice End-to-end rehearsal against a fork of Robinhood Chain mainnet (chain 4663) using the REAL
///         Uniswap v4 PoolManager and the canonical CREATE2 deployer. Nothing is broadcast.
///         Run: FORK_TESTS=true forge test --match-path test/fork/*
contract RobinhoodForkTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    PolydashFactory factory;
    PolydashHook hook;
    PolydashCommitVault vault;
    PoolSwapTest router;
    address deployer = makeAddr("deployer");
    address feeWallet = makeAddr("feeWallet");
    address creator = makeAddr("creator");
    address payout = makeAddr("payout");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    bool enabled;

    function setUp() public {
        enabled = vm.envOr("FORK_TESTS", false);
        if (!enabled) return;
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
        assertEq(block.chainid, 4663);
        assertGt(POOL_MANAGER.code.length, 0, "PoolManager missing");

        vm.startPrank(deployer);
        PolydashLaunch impl = new PolydashLaunch();
        factory = new PolydashFactory(deployer, address(impl), feeWallet);
        bytes memory args = abi.encode(IPoolManager(POOL_MANAGER), address(factory));
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HookPermissions.FLAGS, type(PolydashHook).creationCode, args);
        (bool ok,) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, type(PolydashHook).creationCode, args));
        require(ok && expected.code.length > 0, "hook deploy failed");
        hook = PolydashHook(payable(expected));
        factory.setHook(expected);
        vault = new PolydashCommitVault(address(factory));
        vm.stopPrank();

        router = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        vm.deal(creator, 100 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _params(uint256 delay) internal view returns (PolydashFactory.LaunchParams memory p) {
        p.name = "Fork Token";
        p.symbol = "FORK";
        p.imageUri = "ipfs://x";
        p.description = "fork rehearsal";
        p.socialLinks = new string[](0);
        p.creatorFeeBps = 100;
        p.creatorPayoutWallet = payout;
        p.launchDelay = delay;
    }

    function test_Fork_FullLifecycle() public {
        if (!enabled) return;
        // 1. launch with a commitment window; commit directly and through the vault
        vm.prank(creator);
        (address la, address ta) = factory.createLaunch(_params(1 hours));
        PolydashLaunch l = PolydashLaunch(payable(la));
        vm.prank(alice);
        vault.deposit{value: 1 ether}(la);
        vm.prank(bob);
        vault.deposit{value: 1 ether}(la);

        // 2. go live, settle vault
        vm.warp(block.timestamp + 1 hours);
        l.goLive();
        vault.claimFor(la, alice);
        vault.claimFor(la, bob);
        assertGt(IERC20(ta).balanceOf(alice), 0);
        assertApproxEqAbs(IERC20(ta).balanceOf(alice), IERC20(ta).balanceOf(bob), 1);

        // 3. buy through graduation into the REAL v4 PoolManager
        vm.warp(block.timestamp + 10 minutes); // past anti-sniper window
        vm.roll(block.number + 10);
        vm.prank(alice);
        l.buy{value: 20 ether}(0);
        assertTrue(l.graduated());
        assertGt(hook.positionLiquidity(l.poolId()), 0, "liquidity locked in real PoolManager");

        // 4. swap on v4 both ways; fees accrue in ETH
        PoolKey memory key = hook.poolKeyOf(la);
        PoolSwapTest.TestSettings memory ts = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        vm.prank(bob);
        router.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            ts,
            ""
        );
        uint256 bobTokens = IERC20(ta).balanceOf(bob);
        vm.startPrank(bob);
        IERC20(ta).approve(address(router), type(uint256).max);
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(bobTokens / 2),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            ts,
            ""
        );
        vm.stopPrank();

        // 5. fees: creator claims (pull), platform collected permissionlessly
        uint256 p0 = payout.balance;
        l.claimCreatorFees();
        assertGt(payout.balance, p0);
        uint256 f0 = feeWallet.balance;
        factory.collectPlatformFees(la);
        assertGt(feeWallet.balance, f0);

        // 6. external pool initialisation with our hook is blocked on the real PoolManager
        PoolKey memory rogue = key;
        rogue.currency1 = key.currency1; // same pair, different fee
        rogue.fee = 3000;
        vm.expectRevert();
        IPoolManager(POOL_MANAGER).initialize(rogue, TickMath.getSqrtPriceAtTick(0));
    }
}
