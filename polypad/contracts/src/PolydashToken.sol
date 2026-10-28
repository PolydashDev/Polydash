// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title PolydashToken
/// @notice Fixed-supply ERC-20 created for every Polydash launch. The whole supply is minted once, at
///         construction, to the launch (bonding curve) contract. There is no mint function, no owner,
///         no pause, no blacklist and no transfer tax. Holders may burn their own tokens.
contract PolydashToken is ERC20Burnable {
    /// @notice Bonding-curve contract that received the full supply.
    address public immutable launch;
    string public imageUri;
    string public description;
    string[] internal _socialLinks;

    error ZeroLaunch();

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 totalSupply_,
        address launch_,
        string memory imageUri_,
        string memory description_,
        string[] memory socialLinks_
    ) ERC20(name_, symbol_) {
        if (launch_ == address(0)) revert ZeroLaunch();
        launch = launch_;
        imageUri = imageUri_;
        description = description_;
        _socialLinks = socialLinks_;
        _mint(launch_, totalSupply_);
    }

    function socialLinks() external view returns (string[] memory) {
        return _socialLinks;
    }
}
