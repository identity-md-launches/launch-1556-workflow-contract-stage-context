// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MoonTestBase} from "./helpers/MoonTestBase.sol";
import {ShopReceiver} from "./helpers/Mocks.sol";
import {MoonRewards} from "src/MoonRewards.sol";
import {MoonShop} from "src/MoonShop.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ApprovalFaultToken is ERC20 {
    address public shop;
    bool public failInitial;
    bool public failCleanup;

    constructor() ERC20("Approval fault fixture", "FAULT") {
        _mint(msg.sender, 1_000 ether);
    }

    function configure(address shop_, bool initial_, bool cleanup_) external {
        shop = shop_;
        failInitial = initial_;
        failCleanup = cleanup_;
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (msg.sender == shop && ((value != 0 && failInitial) || (value == 0 && failCleanup))) return false;
        return super.approve(spender, value);
    }
}

/// @dev Models a contract creator receiving its own purchase and forwarding the NFT in the callback.
contract ForwardingCreator is ERC1155Holder {
    MoonShop public shop;
    address public recipient;
    bool public reject;
    bool public nestedSucceeded;
    bytes public nestedResult;
    bytes public nestedCall;

    function setup(MoonShop shop_, address recipient_) external {
        shop = shop_;
        recipient = recipient_;
    }

    function configureItem(uint256 price) external {
        shop.configureItem(1, price, 10, 2, true, "ipfs://callback-item");
    }

    function setCallback(bytes calldata data, bool reject_) external {
        nestedCall = data;
        reject = reject_;
    }

    function purchase() external {
        shop.token().approve(address(shop), 100 ether);
        shop.buy(1, 1, 100 ether);
    }

    function onERC1155Received(address, address, uint256 id, uint256 quantity, bytes memory)
        public
        override
        returns (bytes4)
    {
        if (nestedCall.length != 0) (nestedSucceeded, nestedResult) = address(shop).call(nestedCall);
        shop.safeTransferFrom(address(this), recipient, id, quantity, "");
        return reject ? bytes4(0) : this.onERC1155Received.selector;
    }
}

contract MoonShopAtomicityTest is MoonTestBase {
    event ItemPurchased(
        address indexed buyer,
        uint256 indexed id,
        uint256 quantity,
        uint256 totalPrice,
        uint256 burned,
        uint256 recycled
    );

    function test_rejectedMintRollsBackActivationAndCanRetryTheSamePurchase() public {
        token.approve(address(rewards), INITIAL_FUNDING - 50 ether);
        rewards.fund(INITIAL_FUNDING - 50 ether);
        ShopReceiver receiver = new ShopReceiver(shop);
        assertTrue(token.transfer(address(receiver), 100 ether));
        receiver.configure(true, false);

        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(receiver)));
        receiver.purchase(1, 1, 100 ether);
        assertFalse(rewards.activated());
        assertFalse(rewards.isFunded());
        assertEq(rewards.totalFunded(), INITIAL_FUNDING - 50 ether);
        assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING - 50 ether);
        assertEq(token.balanceOf(address(receiver)), 100 ether);
        assertEq(token.balanceOf(shop.BURN_ADDRESS()), 0);
        assertEq(shop.purchased(address(receiver), 1), 0);
        assertEq(shop.totalBurned(), 0);
        assertEq(shop.totalRecycled(), 0);
        assertEq(token.allowance(address(shop), address(rewards)), 0);

        receiver.configure(false, false);
        receiver.purchase(1, 1, 100 ether);
        assertTrue(rewards.activated());
        assertEq(rewards.totalFunded(), INITIAL_FUNDING);
        assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING);
        assertEq(shop.balanceOf(address(receiver), 1), 1);
        _claim(alice, 500 ether, 1);
        assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING - 500 ether);
    }

    function test_approvalCreationAndCleanupFailureRevertAllPaymentsAndInventory() public {
        ApprovalFaultToken bad = new ApprovalFaultToken();
        MoonRewards targetRewards = new MoonRewards(address(bad), owner);
        MoonShop targetShop = new MoonShop(address(bad), address(targetRewards), owner);
        vm.prank(owner);
        targetShop.configureItem(1, 100 ether, 10, 2, true, "ipfs://fault-item");
        assertTrue(bad.transfer(alice, 100 ether));
        vm.prank(alice);
        bad.approve(address(targetShop), 100 ether);

        for (uint256 i; i < 2; ++i) {
            bad.configure(address(targetShop), i == 0, i == 1);
            vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
            vm.prank(alice);
            targetShop.buy(1, 1, 100 ether);
            assertEq(bad.balanceOf(alice), 100 ether);
            assertEq(bad.balanceOf(address(targetShop)), 0);
            assertEq(bad.balanceOf(address(targetRewards)), 0);
            assertEq(bad.balanceOf(targetShop.BURN_ADDRESS()), 0);
            assertEq(bad.allowance(alice, address(targetShop)), 100 ether);
            assertEq(bad.allowance(address(targetShop), address(targetRewards)), 0);
            assertEq(targetRewards.totalFunded(), 0);
            assertEq(targetShop.totalBurned(), 0);
            assertEq(targetShop.totalRecycled(), 0);
            assertEq(targetShop.purchased(alice, 1), 0);
            assertEq(targetShop.balanceOf(alice, 1), 0);
            (,,, uint256 minted,,) = targetShop.items(1);
            assertEq(minted, 0);
        }
        bad.configure(address(targetShop), false, false);
        vm.prank(alice);
        targetShop.buy(1, 1, 100 ether);
        assertEq(targetShop.balanceOf(alice, 1), 1);
        assertEq(targetRewards.totalFunded(), 50 ether);
        assertEq(bad.balanceOf(targetShop.BURN_ADDRESS()), 50 ether);
    }

    function test_creatorReceiverCannotReenterCatalogEditOrPermitPurchase() public {
        ForwardingCreator creator = new ForwardingCreator();
        MoonShop target = new MoonShop(address(token), address(rewards), address(creator));
        creator.setup(target, bob);
        creator.configureItem(100 ether);
        assertTrue(token.transfer(address(creator), 200 ether));
        creator.setCallback(abi.encodeCall(target.configureItem, (1, 1, 0, 0, true, "ipfs://attack")), false);
        creator.purchase();
        assertFalse(creator.nestedSucceeded());
        assertEq(bytes4(creator.nestedResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(target.uri(1), "ipfs://callback-item");
        assertEq(target.balanceOf(bob, 1), 1);
        assertEq(target.balanceOf(address(creator), 1), 0);
        assertEq(target.purchased(address(creator), 1), 1);
        assertEq(target.purchased(bob, 1), 0);

        creator.setCallback(
            abi.encodeCall(target.buyWithPermit, (1, 1, 100 ether, vm.getBlockTimestamp(), 27, bytes32(0), bytes32(0))),
            false
        );
        creator.purchase();
        assertFalse(creator.nestedSucceeded());
        assertEq(bytes4(creator.nestedResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(target.balanceOf(bob, 1), 2);
        assertEq(target.purchased(address(creator), 1), 2);
        assertEq(target.totalBurned(), 100 ether);
        assertEq(target.totalRecycled(), 100 ether);
    }

    function test_receiverForwardThenRejectRollsBackNestedTransferToo() public {
        ForwardingCreator receiver = new ForwardingCreator();
        receiver.setup(shop, bob);
        receiver.setCallback("", true);
        assertTrue(token.transfer(address(receiver), 100 ether));
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, address(receiver)));
        receiver.purchase();
        assertEq(shop.balanceOf(bob, 1), 0);
        assertEq(shop.balanceOf(address(receiver), 1), 0);
        assertEq(shop.purchased(address(receiver), 1), 0);
        assertEq(token.balanceOf(address(receiver)), 100 ether);
        assertEq(rewards.totalFunded(), 0);
        assertEq(shop.totalBurned(), 0);
        assertEq(shop.totalRecycled(), 0);
    }

    function test_secondBatchElementFailureRestoresFirstItemAndPurchaseHistory() public {
        vm.prank(owner);
        shop.configureItem(2, 1, 0, 0, true, "ipfs://second");
        vm.startPrank(alice);
        token.approve(address(shop), 500 ether + 2);
        shop.buy(1, 5, 500 ether);
        shop.buy(2, 2, 2);
        shop.setApprovalForAll(bob, true);
        vm.stopPrank();
        uint256[] memory ids = new uint256[](2);
        uint256[] memory quantities = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        quantities[0] = 5;
        quantities[1] = 3;
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155InsufficientBalance.selector, alice, 2, 3, 2));
        vm.prank(bob);
        shop.safeBatchTransferFrom(alice, bob, ids, quantities, "");
        assertEq(shop.balanceOf(alice, 1), 5);
        assertEq(shop.balanceOf(alice, 2), 2);
        assertEq(shop.balanceOf(bob, 1), 0);
        assertEq(shop.balanceOf(bob, 2), 0);
        assertEq(shop.purchased(alice, 1), 5);
        assertEq(shop.purchased(alice, 2), 2);
        assertEq(shop.purchased(bob, 1), 0);
        assertEq(rewards.totalFunded(), 250 ether + 1);
    }

    function test_revokedOperatorCannotTransferEvenAfterCreatorEdit() public {
        vm.startPrank(alice);
        token.approve(address(shop), 100 ether);
        shop.buy(1, 1, 100 ether);
        shop.setApprovalForAll(bob, true);
        shop.setApprovalForAll(bob, false);
        vm.stopPrank();
        vm.prank(owner);
        shop.configureItem(1, 1, 1, 1, false, "ipfs://edited");
        vm.expectRevert(abi.encodeWithSelector(IERC1155Errors.ERC1155MissingApprovalForAll.selector, bob, alice));
        vm.prank(bob);
        shop.safeTransferFrom(alice, bob, 1, 1, "");
        assertEq(shop.balanceOf(alice, 1), 1);
        assertEq(shop.purchased(alice, 1), 1);
        assertEq(shop.balanceOf(bob, 1), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splittingOrdersCannotReduceTotalPriceOrDivertRoundingToBuyer(uint256 price, uint8 countSeed)
        public
    {
        price = bound(price, 1, 1_000 ether);
        uint256 count = bound(countSeed, 1, 20);
        vm.prank(owner);
        shop.configureItem(type(uint256).max, price, 0, 0, true, "ipfs://rounding");
        uint256 cost = price * count;
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(alice);
        token.approve(address(shop), cost);
        vm.prank(bob);
        token.approve(address(shop), cost);
        vm.prank(alice);
        shop.buy(type(uint256).max, count, cost);
        uint256 batchBurn = shop.totalBurned();
        uint256 batchRecycle = shop.totalRecycled();
        for (uint256 i; i < count; ++i) {
            vm.prank(bob);
            shop.buy(type(uint256).max, 1, price);
        }
        uint256 singleBurn = shop.totalBurned() - batchBurn;
        uint256 singleRecycle = shop.totalRecycled() - batchRecycle;
        assertEq(aliceBefore - token.balanceOf(alice), cost);
        assertEq(bobBefore - token.balanceOf(bob), cost);
        assertEq(singleBurn + singleRecycle, cost);
        assertLe(singleBurn, batchBurn);
        assertGe(singleRecycle, batchRecycle);
        assertEq(singleRecycle - batchRecycle, (price % 2) * (count / 2));
        assertEq(token.balanceOf(address(shop)), 0);
        assertEq(token.balanceOf(owner), 0);
        assertEq(shop.balanceOf(alice, type(uint256).max), count);
        assertEq(shop.balanceOf(bob, type(uint256).max), count);
    }

    function test_itemZeroOddPriceEventMatchesFundsAndLifetimeInventory() public {
        vm.prank(owner);
        shop.configureItem(0, 3, 0, 0, true, "ipfs://zero-id");
        vm.prank(alice);
        token.approve(address(shop), 3);
        vm.expectEmit(true, true, false, true, address(shop));
        emit ItemPurchased(alice, 0, 1, 3, 1, 2);
        vm.prank(alice);
        shop.buy(0, 1, 3);
        assertEq(shop.purchased(alice, 0), 1);
        assertEq(shop.balanceOf(alice, 0), 1);
        assertEq(token.balanceOf(shop.BURN_ADDRESS()), 1);
        assertEq(token.balanceOf(address(rewards)), 2);
    }
}
