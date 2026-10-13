// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @notice MOON: the fixed-supply launch currency. The factory alone receives the initial supply.
/// @dev Permit changes allowances only. There is no post-construction mint, admin, tax or upgrade path.
contract LaunchToken is ERC20, ERC20Permit {
    constructor() ERC20("MOON", "MOON") ERC20Permit("MOON") {
        _mint(msg.sender, 1_000_000_000 ether);
    }
}
