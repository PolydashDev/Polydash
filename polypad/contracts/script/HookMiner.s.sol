// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PolydashHook} from "../src/PolydashHook.sol";
import {HookPermissions} from "../src/libraries/HookPermissions.sol";

/// @title HookMiner
/// @notice Finds a CREATE2 salt such that the deployed hook address has exactly the required permission bits
///         in its lowest 14 bits (Uniswap V4 encodes hook permissions in the address).
library HookMiner {
    uint160 internal constant FLAG_MASK = 0x3FFF; // Hooks.ALL_HOOK_MASK (14 bits)
    uint256 internal constant MAX_LOOP = 500_000;

    error SaltNotFound();

    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        flags = flags & FLAG_MASK;
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        for (uint256 i; i < MAX_LOOP; ++i) {
            hookAddress = computeAddress(deployer, i, initCodeHash);
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(i));
            }
        }
        revert SaltNotFound();
    }

    function computeAddress(address deployer, uint256 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, initCodeHash)))));
    }
}

/// @notice `forge script script/HookMiner.s.sol --sig "run(address,address)" <poolManager> <factory>`
///         prints the salt and hook address for the canonical CREATE2 deployer.
contract HookMinerScript is Script {
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run(address poolManager, address factory) external view returns (address hook, bytes32 salt) {
        (hook, salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            HookPermissions.FLAGS,
            type(PolydashHook).creationCode,
            abi.encode(IPoolManager(poolManager), factory)
        );
        console2.log("hook address:", hook);
        console2.logBytes32(salt);
    }
}
