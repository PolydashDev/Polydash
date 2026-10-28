// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ISwapRouter02} from "../../src/BuybackRouter.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Mock SwapRouter02: pays out `rate` POLYDASH per 1 ETH (1e18 scale) minus `haircutBps`.
contract MockSwapRouter {
    MockERC20 public immutable out;
    uint256 public rate; // tokens per 1e18 wei
    uint256 public haircutBps;
    bool public shouldRevert;
    ISwapRouter02.ExactInputSingleParams public lastParams;

    constructor(MockERC20 _out, uint256 _rate) {
        out = _out;
        rate = _rate;
    }

    function setHaircut(uint256 bps) external {
        haircutBps = bps;
    }

    function setRevert(bool r) external {
        shouldRevert = r;
    }

    function exactInputSingle(ISwapRouter02.ExactInputSingleParams calldata p) external payable returns (uint256 amountOut) {
        require(!shouldRevert, "router down");
        require(msg.value == p.amountIn, "value");
        lastParams = p;
        amountOut = (p.amountIn * rate / 1e18) * (10_000 - haircutBps) / 10_000;
        require(amountOut >= p.amountOutMinimum, "Too little received");
        out.mint(p.recipient, amountOut);
    }
}

/// @notice Mock V3 pool exposing `observe` with a constant tick.
contract MockV3Pool {
    int24 public tick;

    constructor(int24 _tick) {
        tick = _tick;
    }

    function setTick(int24 t) external {
        tick = t;
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory c, uint160[] memory l) {
        c = new int56[](secondsAgos.length);
        l = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            c[i] = int56(tick) * (int56(1_000_000) - int56(uint56(secondsAgos[i])));
        }
    }
}
