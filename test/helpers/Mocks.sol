// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MoonShop} from "../../src/MoonShop.sol";

contract PostOfficeMock {
    mapping(address => bool) public offices;

    function setOffice(address player, bool open) external {
        offices[player] = open;
    }
}

/// @dev Test-only token for exercising atomic rollback and callbacks absent from LaunchToken.
contract AdversarialToken is ERC20 {
    address public blockedRecipient;
    bool public failTransfers;
    bool public taxTransfers;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bytes public callbackResult;
    bool private _inCallback;

    constructor() ERC20("Test token", "TEST") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function setFailure(bool fail, address recipient, bool tax) external {
        failTransfers = fail;
        blockedRecipient = recipient;
        taxTransfers = tax;
    }

    function setCallback(address target, bytes calldata data) external {
        callbackTarget = target;
        callbackData = data;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfers || (blockedRecipient != address(0) && to == blockedRecipient)) return false;
        bool ok = super.transfer(to, amount);
        _callback();
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (failTransfers || (blockedRecipient != address(0) && to == blockedRecipient)) return false;
        bool ok = super.transferFrom(from, to, amount);
        _callback();
        return ok;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (taxTransfers && from != address(0) && value != 0) {
            super._update(from, address(0), 1);
            super._update(from, to, value - 1);
        } else {
            super._update(from, to, value);
        }
    }

    function _callback() private {
        if (callbackTarget != address(0) && !_inCallback) {
            _inCallback = true;
            (callbackSucceeded, callbackResult) = callbackTarget.call(callbackData);
            _inCallback = false;
        }
    }
}

contract ShopReceiver is ERC1155Holder {
    MoonShop public immutable shop;
    bool public reject;
    bool public attemptReentry;
    bool public reentrySucceeded;
    bytes public reentryResult;

    constructor(MoonShop shop_) {
        shop = shop_;
    }

    function configure(bool reject_, bool reenter_) external {
        reject = reject_;
        attemptReentry = reenter_;
    }

    function purchase(uint256 id, uint256 quantity, uint256 maxPrice) external {
        IERC20(address(shop.token())).approve(address(shop), maxPrice * 2);
        shop.buy(id, quantity, maxPrice);
    }

    function onERC1155Received(address, address, uint256 id, uint256, bytes memory) public override returns (bytes4) {
        if (reject) return bytes4(0);
        if (attemptReentry) {
            (reentrySucceeded, reentryResult) = address(shop).call(abi.encodeCall(shop.buy, (id, 1, 100 ether)));
        }
        return this.onERC1155Received.selector;
    }
}
