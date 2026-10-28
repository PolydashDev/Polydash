// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {PolydashFactory} from "../src/PolydashFactory.sol";
import {PolydashLaunch} from "../src/PolydashLaunch.sol";
import {PolydashHook} from "../src/PolydashHook.sol";
import {BuybackRouter} from "../src/BuybackRouter.sol";
import {PolydashCommitVault} from "../src/PolydashCommitVault.sol";
import {HookPermissions} from "../src/libraries/HookPermissions.sol";
import {HookMiner} from "./HookMiner.s.sol";

/// @title Deploy
/// @notice Deploys the Polydash Launchpad.
///
///   DEFAULT TARGET: Arbitrum Sepolia (chain id 421614).
///
///   forge script script/Deploy.s.sol --rpc-url arbitrum_sepolia --broadcast --private-key $PK
///
/// Environment:
///   PLATFORM_FEE_WALLET  (required)  receives platform fees
///   FINAL_OWNER          (optional)  multisig; ownership transfer is started (2-step, multisig must accept)
///   MAINNET              (optional)  "true" to target Robinhood Chain (4663). Requires the next flag too.
///   I_HAVE_WRITTEN_APPROVAL_AND_AUDIT (optional) must be "true" for mainnet. Do NOT set this without written
///                        approval from the project owner AND a completed external audit.
///   POOL_MANAGER         (optional, testnet only) override for local anvil rehearsals
///   BUYBACK_WETH, BUYBACK_V3_POOL, BUYBACK_POOL_FEE (optional) deploy BuybackRouter (stays disabled).
contract Deploy is Script {
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    uint256 internal constant ROBINHOOD_CHAIN = 4663;

    // Uniswap v4 (official deployments)
    address internal constant POOL_MANAGER_ARB_SEPOLIA = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;
    address internal constant POOL_MANAGER_ROBINHOOD = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant POSITION_MANAGER_ROBINHOOD = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant UNIVERSAL_ROUTER_ROBINHOOD = 0x8876789976dEcBfCbBbe364623C63652db8C0904;

    // Uniswap v3 (Robinhood Chain) - used only by the optional BuybackRouter
    address internal constant SWAP_ROUTER02_ROBINHOOD = 0xCaf681a66D020601342297493863E78C959E5cb2;
    // Arbitrum Sepolia SwapRouter02 (official Uniswap v3 deployment)
    address internal constant SWAP_ROUTER02_ARB_SEPOLIA = 0x101F443B4d1b059569D643917553c771E1b9663E;

    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    error MainnetNotApproved();
    error WrongChain(uint256 expected, uint256 actual);

    struct Deployed {
        address launchImpl;
        address factory;
        address hook;
        address commitVault;
        address buyback;
    }

    function run() external returns (Deployed memory d) {
        bool mainnet = vm.envOr("MAINNET", false);
        address poolManager;
        address swapRouter;
        if (mainnet) {
            // HARD STOP: mainnet requires written approval and an external audit.
            if (!vm.envOr("I_HAVE_WRITTEN_APPROVAL_AND_AUDIT", false)) revert MainnetNotApproved();
            if (block.chainid != ROBINHOOD_CHAIN) revert WrongChain(ROBINHOOD_CHAIN, block.chainid);
            poolManager = POOL_MANAGER_ROBINHOOD;
            swapRouter = SWAP_ROUTER02_ROBINHOOD;
        } else {
            if (block.chainid != ARBITRUM_SEPOLIA) revert WrongChain(ARBITRUM_SEPOLIA, block.chainid);
            // POOL_MANAGER override is for local anvil rehearsals only (ignored on mainnet).
            poolManager = vm.envOr("POOL_MANAGER", POOL_MANAGER_ARB_SEPOLIA);
            swapRouter = SWAP_ROUTER02_ARB_SEPOLIA;
        }

        address feeWallet = vm.envAddress("PLATFORM_FEE_WALLET");
        address finalOwner = vm.envOr("FINAL_OWNER", address(0));

        vm.startBroadcast();
        address deployer = msg.sender;

        d.launchImpl = address(new PolydashLaunch());
        d.factory = address(new PolydashFactory(deployer, d.launchImpl, feeWallet));

        // Mine a salt so the hook address encodes exactly the permission flags it implements.
        bytes memory args = abi.encode(IPoolManager(poolManager), d.factory);
        (address expected, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HookPermissions.FLAGS, type(PolydashHook).creationCode, args);
        PolydashHook hook = new PolydashHook{salt: salt}(IPoolManager(poolManager), d.factory);
        require(address(hook) == expected, "hook address mismatch");
        d.hook = address(hook);
        PolydashFactory(payable(d.factory)).setHook(d.hook);
        d.commitVault = address(new PolydashCommitVault(d.factory));

        address weth = vm.envOr("BUYBACK_WETH", address(0));
        address v3Pool = vm.envOr("BUYBACK_V3_POOL", address(0));
        if (weth != address(0) && v3Pool != address(0)) {
            uint24 fee = uint24(vm.envOr("BUYBACK_POOL_FEE", uint256(10_000)));
            address polydash = PolydashFactory(payable(d.factory)).POLYDASH_TOKEN();
            address bbOwner = finalOwner == address(0) ? deployer : finalOwner;
            d.buyback = address(new BuybackRouter(bbOwner, d.factory, swapRouter, weth, polydash, v3Pool, fee));
            // Buyback stays OFF: the owner enables it later with setBuybackConfig.
        }

        if (finalOwner != address(0) && finalOwner != deployer) {
            PolydashFactory(payable(d.factory)).transferOwnership(finalOwner); // multisig must acceptOwnership()
        }
        vm.stopBroadcast();

        console2.log("chain id          :", block.chainid);
        console2.log("PolydashLaunch impl:", d.launchImpl);
        console2.log("PolydashFactory    :", d.factory);
        console2.log("PolydashHook       :", d.hook);
        console2.log("PolydashCommitVault:", d.commitVault);
        console2.log("BuybackRouter      :", d.buyback);
        console2.log("PoolManager        :", poolManager);
    }
}
