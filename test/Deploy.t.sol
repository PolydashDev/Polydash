// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {PolydashStakingFactory} from "../src/PolydashStakingFactory.sol";

contract DeployScriptTest is Test {
    function test_deployScript() public {
        (address deployer, uint256 pk) = makeAddrAndKey("deployer"); // throwaway test key
        vm.setEnv("PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("FEE_RECIPIENT", vm.toString(address(0xBEEF)));
        vm.setEnv("UNSTAKE_FEE_BPS", "100");
        PolydashStakingFactory f = new Deploy().run();
        assertEq(f.owner(), deployer);
        assertEq(f.feeRecipient(), address(0xBEEF));
        assertEq(f.unstakeFeeBps(), 100);
    }
}
