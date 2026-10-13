// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CourierCompanions} from "./CourierCompanions.sol";
import {MoonRewards} from "./MoonRewards.sol";

/// @notice MOON companion shop and ERC-1155 collection. All primary-sale revenue is burned or recycled.
contract MoonShop is CourierCompanions, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Item {
        uint256 price;
        uint256 maxSupply;
        uint256 perWalletLimit;
        uint256 minted;
        bool enabled;
        bool exists;
    }

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    IERC20 public immutable token;
    MoonRewards public immutable rewards;
    address public immutable owner;
    uint256 public totalBurned;
    uint256 public totalRecycled;
    mapping(uint256 id => Item item) public items;
    mapping(address buyer => mapping(uint256 id => uint256 quantity)) public purchased;

    error InvalidAddress();
    error Unauthorized();
    error InvalidPrice();
    error SupplyBelowMinted();
    error EmptyURI();
    error UnknownItem();
    error ItemDisabled();
    error ZeroQuantity();
    error MaxPriceExceeded();
    error SupplyLimitExceeded();
    error WalletLimitExceeded();
    error DependencyNotDeployed();
    error RewardsTokenMismatch();
    error InexactPayment();

    event ItemConfigured(
        uint256 indexed id, uint256 price, uint256 maxSupply, uint256 perWalletLimit, bool enabled, string metadataURI
    );
    event ItemPurchased(
        address indexed buyer,
        uint256 indexed id,
        uint256 quantity,
        uint256 totalPrice,
        uint256 burned,
        uint256 recycled
    );

    /// @param token_ $token. No dependency is called during construction.
    /// @param rewards_ $contract:MoonRewards, deployed earlier with the same token.
    /// @param owner_ $owner, also the immutable secondary-sale royalty recipient.
    constructor(address token_, address rewards_, address owner_) CourierCompanions(owner_) {
        if (token_ == address(0) || rewards_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        token = IERC20(token_);
        rewards = MoonRewards(rewards_);
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @notice Add or edit an item. Supply and wallet limits of zero mean unlimited.
    /// @dev Limits count lifetime mints/purchases, not balances. Transfers never reset a purchase limit.
    function configureItem(
        uint256 id,
        uint256 price,
        uint256 maxSupply,
        uint256 perWalletLimit,
        bool enabled,
        string calldata metadataURI
    ) external nonReentrant onlyOwner {
        if (price == 0) revert InvalidPrice();
        if (bytes(metadataURI).length == 0) revert EmptyURI();
        Item storage item = items[id];
        if (maxSupply != 0 && maxSupply < item.minted) revert SupplyBelowMinted();
        item.price = price;
        item.maxSupply = maxSupply;
        item.perWalletLimit = perWalletLimit;
        item.enabled = enabled;
        item.exists = true;
        _setItemURI(id, metadataURI);
        emit ItemConfigured(id, price, maxSupply, perWalletLimit, enabled, metadataURI);
    }

    /// @param maxTotalPrice Maximum MOON wei for the entire order (price times quantity).
    function buy(uint256 id, uint256 quantity, uint256 maxTotalPrice) external nonReentrant {
        _buy(id, quantity, maxTotalPrice);
    }

    /// @notice Permit grants maxTotalPrice to this shop; only the actual total price is spent.
    /// @dev Tolerates a permit already submitted by another party. Existing allowance is still required.
    function buyWithPermit(
        uint256 id,
        uint256 quantity,
        uint256 maxTotalPrice,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant {
        try IERC20Permit(address(token)).permit(msg.sender, address(this), maxTotalPrice, deadline, v, r, s) {} catch {}
        _buy(id, quantity, maxTotalPrice);
    }

    function _buy(uint256 id, uint256 quantity, uint256 maxTotalPrice) private {
        Item storage item = items[id];
        if (!item.exists) revert UnknownItem();
        if (!item.enabled) revert ItemDisabled();
        if (quantity == 0) revert ZeroQuantity();
        uint256 cost = item.price * quantity;
        if (cost > maxTotalPrice) revert MaxPriceExceeded();
        uint256 newMinted = item.minted + quantity;
        uint256 newPurchased = purchased[msg.sender][id] + quantity;
        if (item.maxSupply != 0 && newMinted > item.maxSupply) revert SupplyLimitExceeded();
        if (item.perWalletLimit != 0 && newPurchased > item.perWalletLimit) revert WalletLimitExceeded();
        if (address(token).code.length == 0 || address(rewards).code.length == 0) revert DependencyNotDeployed();
        if (address(rewards.token()) != address(token)) revert RewardsTokenMismatch();

        // Rounding is per order: the indivisible odd wei always benefits the reward pool.
        uint256 burned = cost / 2;
        uint256 recycled = cost - burned;
        item.minted = newMinted;
        purchased[msg.sender][id] = newPurchased;
        totalBurned += burned;
        totalRecycled += recycled;
        emit ItemPurchased(msg.sender, id, quantity, cost, burned, recycled);

        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), cost);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != cost) revert InexactPayment();
        if (burned != 0) token.safeTransfer(BURN_ADDRESS, burned);
        token.forceApprove(address(rewards), recycled);
        rewards.fund(recycled);
        // Leave no standing rewards allowance, including with nonstandard tokens.
        token.forceApprove(address(rewards), 0);
        _mint(msg.sender, id, quantity, "");
    }
}
