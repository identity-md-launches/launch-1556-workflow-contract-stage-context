// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";

/// @notice ERC-1155 collection implemented by MoonShop at the shop's own address.
/// @dev Abstract: deploy MoonShop, not a second collection. Only the paid purchase path mints.
abstract contract CourierCompanions is ERC1155, ERC2981 {
    string public constant name = "Courier Companions";
    string public constant symbol = "COURIER";
    uint96 public constant ROYALTY_BPS = 500;
    address public immutable creator;
    mapping(uint256 id => string metadataURI) private _itemURIs;

    error InvalidCreator();

    constructor(address creator_) ERC1155("") {
        if (creator_ == address(0)) revert InvalidCreator();
        creator = creator_;
        _setDefaultRoyalty(creator_, ROYALTY_BPS);
    }

    function uri(uint256 id) public view override returns (string memory) {
        return _itemURIs[id];
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _setItemURI(uint256 id, string calldata metadataURI) internal {
        _itemURIs[id] = metadataURI;
        emit URI(metadataURI, id);
    }
}
