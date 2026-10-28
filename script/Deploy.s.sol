// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {PolydashStakingFactory} from "../src/PolydashStakingFactory.sol";

/// @notice Deploys PolydashStakingFactory.
/// @dev Env: PRIVATE_KEY, FEE_RECIPIENT, UNSTAKE_FEE_BPS (optional, default 100 = 1%, max 500).
///      forge script script/Deploy.s.sol --rpc-url robinhood --broadcast
contract Deploy is Script {
    function run() external returns (PolydashStakingFactory factory) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        uint256 feeBps = vm.envOr("UNSTAKE_FEE_BPS", uint256(100));

        vm.startBroadcast(pk);
        factory = new PolydashStakingFactory(feeRecipient, feeBps);
        vm.stopBroadcast();

        console2.log("PolydashStakingFactory:", address(factory));
        console2.log("owner:", factory.owner());
        console2.log("feeRecipient:", feeRecipient);
        console2.log("unstakeFeeBps:", feeBps);
    }
}
