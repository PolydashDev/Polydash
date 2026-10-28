// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    uint256 public taxBps;

    constructor(string memory n, string memory s, uint256 _taxBps) ERC20(n, s) {
        taxBps = _taxBps;
        _mint(msg.sender, 1e30);
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (taxBps > 0 && from != address(0) && to != address(0)) {
            uint256 tax = (value * taxBps) / 10_000;
            super._update(from, address(0xdead), tax);
            super._update(from, to, value - tax);
        } else {
            super._update(from, to, value);
        }
    }
}
