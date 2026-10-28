// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PolydashFactory} from "../src/PolydashFactory.sol";

/// @title CreateLaunch
/// @notice Creates a token launch through an already deployed factory.
///
///   FACTORY=0x... TOKEN_NAME="My Token" TOKEN_SYMBOL=MYT \
///   forge script script/CreateLaunch.s.sol --rpc-url arbitrum_sepolia --broadcast --private-key $PK
///
/// Optional env: TOKEN_IMAGE, TOKEN_DESCRIPTION, CREATOR_FEE_BPS (default 100), PAYOUT_WALLET (default sender),
///               DEV_BUY_WEI (default 0), LAUNCH_DELAY (seconds, default 0 = live immediately),
///               SOCIAL_X, SOCIAL_TELEGRAM, SOCIAL_WEBSITE
contract CreateLaunch is Script {
    function run() external returns (address launch, address token) {
        PolydashFactory factory = PolydashFactory(payable(vm.envAddress("FACTORY")));
        require(block.chainid != 4663 || vm.envOr("I_HAVE_WRITTEN_APPROVAL_AND_AUDIT", false), "mainnet not approved");

        string[] memory socials = new string[](3);
        socials[0] = vm.envOr("SOCIAL_X", string(""));
        socials[1] = vm.envOr("SOCIAL_TELEGRAM", string(""));
        socials[2] = vm.envOr("SOCIAL_WEBSITE", string(""));

        uint256 devBuy = vm.envOr("DEV_BUY_WEI", uint256(0));
        PolydashFactory.LaunchParams memory p = PolydashFactory.LaunchParams({
            name: vm.envString("TOKEN_NAME"),
            symbol: vm.envString("TOKEN_SYMBOL"),
            imageUri: vm.envOr("TOKEN_IMAGE", string("")),
            description: vm.envOr("TOKEN_DESCRIPTION", string("")),
            socialLinks: socials,
            creatorFeeBps: vm.envOr("CREATOR_FEE_BPS", uint256(100)),
            creatorPayoutWallet: vm.envOr("PAYOUT_WALLET", address(0)),
            devBuyEth: devBuy,
            totalSupply: 0,
            virtualEthReserve: 0,
            launchDelay: vm.envOr("LAUNCH_DELAY", uint256(0))
        });

        vm.startBroadcast();
        (launch, token) = factory.createLaunch{value: devBuy}(p);
        vm.stopBroadcast();

        console2.log("launch:", launch);
        console2.log("token :", token);
    }
}
