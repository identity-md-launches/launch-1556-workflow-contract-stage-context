// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MoonTestBase} from "./helpers/MoonTestBase.sol";
import {MoonRewards} from "../src/MoonRewards.sol";
import {MoonShop} from "../src/MoonShop.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {AdversarialToken, ShopReceiver} from "./helpers/Mocks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MoonShopTest is MoonTestBase {
    function setUp() public override {
        super.setUp();
        vm.prank(alice);
        token.approve(address(shop), 100_000 ether);
        vm.prank(bob);
        token.approve(address(shop), 100_000 ether);
    }

    function test_constructorUsesExplicitRolesAndDoesNotCallDependencies() public {
        address noToken = makeAddr("absent token");
        address noRewards = makeAddr("absent rewards");
        MoonShop fresh = new MoonShop(noToken, noRewards, owner);
        assertEq(fresh.owner(), owner);
        assertEq(fresh.creator(), owner);
        assertEq(address(fresh.token()), noToken);
        assertEq(address(fresh.rewards()), noRewards);
        vm.prank(owner);
        fresh.configureItem(1, 100, 0, 0, true, "ipfs://item");
        vm.expectRevert(MoonShop.DependencyNotDeployed.selector);
        fresh.buy(1, 1, 100);
        vm.expectRevert();
        new MoonShop(address(token), address(rewards), address(0));
        vm.expectRevert(MoonShop.InvalidAddress.selector);
        new MoonShop(address(0), address(rewards), owner);
        vm.expectRevert(MoonShop.InvalidAddress.selector);
        new MoonShop(address(token), address(0), owner);
    }

    function test_onlyOwnerCanConfigureAndInvalidItemsFail() public {
        vm.expectRevert(MoonShop.Unauthorized.selector);
        vm.prank(alice);
        shop.configureItem(2, 1, 0, 0, true, "ipfs://item");
        vm.expectRevert(MoonShop.Unauthorized.selector);
        shop.configureItem(2, 1, 0, 0, true, "ipfs://item");
        vm.expectRevert(MoonShop.InvalidPrice.selector);
        vm.prank(owner);
        shop.configureItem(2, 0, 0, 0, true, "ipfs://item");
        vm.expectRevert(MoonShop.EmptyURI.selector);
        vm.prank(owner);
        shop.configureItem(2, 1, 0, 0, true, "");
    }

    function test_purchaseSplitsPaymentAndMintsWithoutOwnerRevenue() public {
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        shop.buy(1, 2, 200 ether);
        assertEq(shop.balanceOf(alice, 1), 2);
        assertEq(shop.purchased(alice, 1), 2);
        assertEq(_minted(1), 2);
        assertEq(token.balanceOf(alice), beforeBalance - 200 ether);
        assertEq(token.balanceOf(shop.BURN_ADDRESS()), 100 ether);
        assertEq(token.balanceOf(address(rewards)), 100 ether);
        assertEq(rewards.totalFunded(), 100 ether);
        assertEq(token.balanceOf(address(shop)), 0);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.allowance(address(shop), address(rewards)), 0);
        assertEq(shop.totalBurned(), 100 ether);
        assertEq(shop.totalRecycled(), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitToTheWeiAndNoDust(uint256 price, uint256 quantity) public {
        price = bound(price, 1, 1_000 ether);
        quantity = bound(quantity, 1, 50);
        vm.prank(owner);
        shop.configureItem(2, price, 0, 0, true, "ipfs://item");
        uint256 cost = price * quantity;
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        shop.buy(2, quantity, cost);
        assertEq(token.balanceOf(alice), beforeBalance - cost);
        assertEq(token.balanceOf(shop.BURN_ADDRESS()), cost / 2);
        assertEq(token.balanceOf(address(rewards)), cost - cost / 2);
        assertEq(shop.totalBurned() + shop.totalRecycled(), cost);
        assertEq(token.balanceOf(address(shop)), 0);
        assertEq(shop.balanceOf(alice, 2), quantity);
    }

    function test_oneWeiAndOddWeiPriceFavorRewards() public {
        vm.prank(owner);
        shop.configureItem(2, 1, 0, 0, true, "ipfs://item");
        vm.prank(alice);
        shop.buy(2, 1, 1);
        assertEq(shop.totalBurned(), 0);
        assertEq(shop.totalRecycled(), 1);
        vm.prank(owner);
        shop.configureItem(2, 5, 0, 0, true, "ipfs://item");
        vm.prank(alice);
        shop.buy(2, 1, 5);
        assertEq(shop.totalBurned(), 2);
        assertEq(shop.totalRecycled(), 4);
    }

    function test_quoteUsesMaximumTotalOrderPriceAndOwnerEditsCannotOverspend() public {
        vm.expectRevert(MoonShop.MaxPriceExceeded.selector);
        vm.prank(alice);
        shop.buy(1, 2, 100 ether);
        vm.prank(owner);
        shop.configureItem(1, 101 ether, 100, 10, true, "ipfs://changed");
        vm.expectRevert(MoonShop.MaxPriceExceeded.selector);
        vm.prank(alice);
        shop.buy(1, 1, 100 ether);
        assertEq(shop.purchased(alice, 1), 0);
        assertEq(shop.totalBurned(), 0);
        vm.prank(owner);
        shop.configureItem(1, 99 ether, 100, 10, true, "ipfs://changed");
        vm.prank(alice);
        shop.buy(1, 1, 100 ether);
        assertEq(shop.totalBurned() + shop.totalRecycled(), 99 ether);
    }

    function test_unknownDisabledAndZeroQuantityFail() public {
        vm.expectRevert(MoonShop.UnknownItem.selector);
        vm.prank(alice);
        shop.buy(2, 1, 100 ether);
        vm.expectRevert(MoonShop.ZeroQuantity.selector);
        vm.prank(alice);
        shop.buy(1, 0, 100 ether);
        vm.prank(owner);
        shop.configureItem(1, 100 ether, 100, 10, false, "ipfs://item");
        vm.expectRevert(MoonShop.ItemDisabled.selector);
        vm.prank(alice);
        shop.buy(1, 1, 100 ether);
        vm.prank(owner);
        shop.configureItem(1, 100 ether, 100, 10, true, "ipfs://item");
        vm.prank(alice);
        shop.buy(1, 1, 100 ether);
    }

    function test_supplyCapExactBoundaryAndEditsPreserveMintedCount() public {
        vm.prank(owner);
        shop.configureItem(1, 100 ether, 3, 0, true, "ipfs://item");
        vm.prank(alice);
        shop.buy(1, 3, 300 ether);
        vm.expectRevert(MoonShop.SupplyLimitExceeded.selector);
        vm.prank(bob);
        shop.buy(1, 1, 100 ether);
        vm.expectRevert(MoonShop.SupplyBelowMinted.selector);
        vm.prank(owner);
        shop.configureItem(1, 50 ether, 2, 0, true, "ipfs://item");
        vm.prank(owner);
        shop.configureItem(1, 50 ether, 4, 0, true, "ipfs://edited");
        assertEq(_minted(1), 3);
        vm.prank(bob);
        shop.buy(1, 1, 50 ether);
        assertEq(_minted(1), 4);
        assertEq(shop.uri(1), "ipfs://edited");
    }

    function test_walletLimitCountsLifetimePurchasesDespiteTransfers() public {
        vm.prank(alice);
        shop.buy(1, 10, 1_000 ether);
        vm.prank(alice);
        shop.safeTransferFrom(alice, bob, 1, 10, "");
        assertEq(shop.balanceOf(alice, 1), 0);
        vm.expectRevert(MoonShop.WalletLimitExceeded.selector);
        vm.prank(alice);
        shop.buy(1, 1, 100 ether);
        vm.prank(bob);
        shop.buy(1, 10, 1_000 ether);
        assertEq(shop.balanceOf(bob, 1), 20);
        assertEq(shop.purchased(bob, 1), 10);
        assertEq(shop.purchased(alice, 1), 10);
    }

    function test_loweringWalletLimitDoesNotConfiscateAndRaisingReopensPurchases() public {
        vm.prank(alice);
        shop.buy(1, 3, 300 ether);
        vm.prank(owner);
        shop.configureItem(1, 100 ether, 100, 2, true, "ipfs://item");
        vm.expectRevert(MoonShop.WalletLimitExceeded.selector);
        vm.prank(alice);
        shop.buy(1, 1, 100 ether);
        assertEq(shop.balanceOf(alice, 1), 3);
        vm.prank(owner);
        shop.configureItem(1, 100 ether, 100, 4, true, "ipfs://item");
        vm.prank(alice);
        shop.buy(1, 1, 100 ether);
    }

    function test_zeroLimitsAreUnlimited() public {
        vm.prank(owner);
        shop.configureItem(1, 1, 0, 0, true, "ipfs://item");
        vm.prank(alice);
        shop.buy(1, 10_000, 10_000);
        assertEq(_minted(1), 10_000);
        assertEq(shop.balanceOf(alice, 1), 10_000);
    }

    function test_permitBuyWorksWithoutPriorApproval() public {
        vm.prank(alice);
        token.approve(address(shop), 0);
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _permit(alice, address(shop), 200 ether, deadline, aliceKey);
        vm.prank(alice);
        shop.buyWithPermit(1, 2, 200 ether, deadline, v, r, s);
        assertEq(shop.balanceOf(alice, 1), 2);
        assertEq(token.allowance(alice, address(shop)), 0);
        assertEq(token.nonces(alice), 1);
    }

    function test_permitBuyChargesActualPriceAndLeavesOnlyUnspentApproval() public {
        vm.prank(alice);
        token.approve(address(shop), 0);
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _permit(alice, address(shop), 150 ether, deadline, aliceKey);
        uint256 beforeBalance = token.balanceOf(alice);
        vm.prank(alice);
        shop.buyWithPermit(1, 1, 150 ether, deadline, v, r, s);
        assertEq(token.balanceOf(alice), beforeBalance - 100 ether);
        assertEq(token.allowance(alice, address(shop)), 50 ether);
    }

    function test_preSubmittedPermitDoesNotBlockBuyAndCannotRedirectPurchase() public {
        vm.prank(alice);
        token.approve(address(shop), 0);
        vm.prank(bob);
        token.approve(address(shop), 0);
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _permit(alice, address(shop), 100 ether, deadline, aliceKey);
        vm.prank(bob);
        token.permit(alice, address(shop), 100 ether, deadline, v, r, s);
        vm.expectRevert();
        vm.prank(bob);
        shop.buyWithPermit(1, 1, 100 ether, deadline, v, r, s);
        vm.prank(alice);
        shop.buyWithPermit(1, 1, 100 ether, deadline, v, r, s);
        assertEq(shop.balanceOf(alice, 1), 1);
        assertEq(shop.balanceOf(bob, 1), 0);
        assertEq(token.nonces(alice), 1);
    }

    function test_permitReplayExpiredWrongSignerAndWrongSpenderCannotBuyWithoutAllowance() public {
        vm.prank(alice);
        token.approve(address(shop), 0);
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _permit(alice, address(shop), 100 ether, deadline, aliceKey);
        vm.prank(alice);
        shop.buyWithPermit(1, 1, 100 ether, deadline, v, r, s);
        vm.expectRevert();
        vm.prank(alice);
        shop.buyWithPermit(1, 1, 100 ether, deadline, v, r, s);
        (v, r, s) = _permit(alice, address(shop), 100 ether, deadline, bobKey);
        vm.expectRevert();
        vm.prank(alice);
        shop.buyWithPermit(1, 1, 100 ether, deadline, v, r, s);
        (v, r, s) = _permit(alice, bob, 100 ether, deadline, aliceKey);
        vm.expectRevert();
        vm.prank(alice);
        shop.buyWithPermit(1, 1, 100 ether, deadline, v, r, s);
        (v, r, s) = _permit(alice, address(shop), 100 ether, deadline, aliceKey);
        vm.warp(deadline + 1);
        vm.expectRevert();
        vm.prank(alice);
        shop.buyWithPermit(1, 1, 100 ether, deadline, v, r, s);
        assertEq(shop.balanceOf(alice, 1), 1);
        assertEq(token.nonces(alice), 1);
    }

    function test_failedPermitPurchaseRollsBackPermitNonceAndAllowance() public {
        vm.prank(alice);
        token.approve(address(shop), 0);
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _permit(alice, address(shop), 99 ether, deadline, aliceKey);
        vm.expectRevert(MoonShop.MaxPriceExceeded.selector);
        vm.prank(alice);
        shop.buyWithPermit(1, 1, 99 ether, deadline, v, r, s);
        assertEq(token.nonces(alice), 0);
        assertEq(token.allowance(alice, address(shop)), 0);
    }

    function test_insufficientBalanceAndAllowanceRollBackAllCounters() public {
        vm.prank(alice);
        token.approve(address(shop), 99 ether);
        vm.expectRevert();
        vm.prank(alice);
        shop.buy(1, 1, 100 ether);
        vm.startPrank(alice);
        token.approve(address(shop), 100 ether);
        token.transfer(bob, token.balanceOf(alice));
        vm.stopPrank();
        vm.expectRevert();
        vm.prank(alice);
        shop.buy(1, 1, 100 ether);
        assertEq(_minted(1), 0);
        assertEq(shop.purchased(alice, 1), 0);
        assertEq(shop.totalBurned(), 0);
        assertEq(shop.totalRecycled(), 0);
        assertEq(rewards.totalFunded(), 0);
    }

    function test_receiverRejectionRollsBackPaymentRecyclingAndMint() public {
        ShopReceiver receiver = new ShopReceiver(shop);
        token.transfer(address(receiver), 1_000 ether);
        receiver.configure(true, false);
        vm.expectRevert();
        receiver.purchase(1, 1, 100 ether);
        assertEq(token.balanceOf(address(receiver)), 1_000 ether);
        assertEq(shop.balanceOf(address(receiver), 1), 0);
        assertEq(shop.purchased(address(receiver), 1), 0);
        assertEq(_minted(1), 0);
        assertEq(shop.totalBurned(), 0);
        assertEq(shop.totalRecycled(), 0);
        assertEq(rewards.totalFunded(), 0);
        assertEq(token.balanceOf(shop.BURN_ADDRESS()), 0);
        assertEq(token.balanceOf(address(rewards)), 0);
    }

    function test_receiverCannotReenterPurchase() public {
        ShopReceiver receiver = new ShopReceiver(shop);
        token.transfer(address(receiver), 1_000 ether);
        receiver.configure(false, true);
        receiver.purchase(1, 1, 100 ether);
        assertFalse(receiver.reentrySucceeded());
        assertEq(bytes4(receiver.reentryResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(shop.balanceOf(address(receiver), 1), 1);
        assertEq(shop.purchased(address(receiver), 1), 1);
        assertEq(shop.totalBurned() + shop.totalRecycled(), 100 ether);
    }

    function test_transfersOperatorsAndBatchTransfers() public {
        vm.prank(alice);
        shop.buy(1, 5, 500 ether);
        vm.expectRevert();
        vm.prank(bob);
        shop.safeTransferFrom(alice, bob, 1, 1, "");
        vm.prank(alice);
        shop.setApprovalForAll(bob, true);
        vm.prank(bob);
        shop.safeTransferFrom(alice, bob, 1, 1, "");
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        ids[0] = 1;
        ids[1] = 1;
        amounts[0] = 1;
        amounts[1] = 2;
        vm.prank(bob);
        shop.safeBatchTransferFrom(alice, bob, ids, amounts, "");
        assertEq(shop.balanceOf(alice, 1), 1);
        assertEq(shop.balanceOf(bob, 1), 4);
        assertEq(shop.purchased(alice, 1), 5);
        assertEq(shop.purchased(bob, 1), 0);
    }

    function test_disabledItemAndPausedRewardsDoNotFreezeTransfersOrShopRecycling() public {
        vm.prank(owner);
        rewards.pause();
        vm.prank(alice);
        shop.buy(1, 1, 100 ether);
        vm.prank(owner);
        shop.configureItem(1, 100 ether, 100, 10, false, "ipfs://edited");
        vm.prank(alice);
        shop.safeTransferFrom(alice, bob, 1, 1, "");
        assertEq(shop.balanceOf(bob, 1), 1);
        assertEq(rewards.totalFunded(), 50 ether);
    }

    function test_interfacesMetadataAndFixedRoyalty() public view {
        assertEq(shop.name(), "Courier Companions");
        assertEq(shop.symbol(), "COURIER");
        assertEq(shop.uri(1), "ipfs://courier-companions/1.json");
        assertEq(shop.uri(999), "");
        assertTrue(shop.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(shop.supportsInterface(0xd9b67a26)); // ERC-1155
        assertTrue(shop.supportsInterface(0x0e89341c)); // ERC-1155 metadata
        assertTrue(shop.supportsInterface(0x2a55205a)); // ERC-2981
        assertFalse(shop.supportsInterface(0xffffffff));
        (address recipient, uint256 amount) = shop.royaltyInfo(1, 100 ether);
        assertEq(recipient, owner);
        assertEq(amount, 5 ether);
    }

    function testFuzz_royaltyIsFivePercent(uint128 salePrice) public view {
        (address recipient, uint256 amount) = shop.royaltyInfo(1, salePrice);
        assertEq(recipient, owner);
        assertEq(amount, uint256(salePrice) * 5 / 100);
    }

    function test_noFreeMintRedirectWithdrawOrRoyaltyChanges() public {
        bytes[7] memory calls = [
            abi.encodeWithSignature("mint(address,uint256,uint256,bytes)", alice, 1, 1, ""),
            abi.encodeWithSignature("setRewards(address)", owner),
            abi.encodeWithSignature("setToken(address)", owner),
            abi.encodeWithSignature("withdraw(address,uint256)", owner, 1),
            abi.encodeWithSignature("setDefaultRoyalty(address,uint96)", alice, 1),
            abi.encodeWithSignature("transferOwnership(address)", alice),
            abi.encodeWithSignature("upgradeTo(address)", alice)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(shop).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(shop.balanceOf(alice, 1), 0);
        assertEq(shop.creator(), owner);
    }

    function test_mismatchedRewardsTokenFailsOnUse() public {
        LaunchToken different = new LaunchToken();
        MoonShop mismatched = new MoonShop(address(different), address(rewards), owner);
        vm.prank(owner);
        mismatched.configureItem(1, 100, 0, 0, true, "ipfs://item");
        vm.expectRevert(MoonShop.RewardsTokenMismatch.selector);
        mismatched.buy(1, 1, 100);
    }

    function test_tokenCallbackCannotReenterShop() public {
        (AdversarialToken bad, MoonRewards targetRewards, MoonShop targetShop) = _adversarialShop();
        bad.setCallback(address(targetShop), abi.encodeCall(targetShop.buy, (1, 1, 100 ether)));
        vm.prank(alice);
        targetShop.buy(1, 1, 100 ether);
        assertFalse(bad.callbackSucceeded());
        assertEq(bytes4(bad.callbackResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(targetShop.balanceOf(alice, 1), 1);
        assertEq(targetRewards.totalFunded(), 50 ether);
    }

    function test_failedPullBurnOrRecycleRollsBackEntirePurchase() public {
        (AdversarialToken bad, MoonRewards targetRewards, MoonShop targetShop) = _adversarialShop();
        address[3] memory recipients = [address(targetShop), targetShop.BURN_ADDRESS(), address(targetRewards)];
        for (uint256 i; i < recipients.length; ++i) {
            bad.setFailure(false, recipients[i], false);
            vm.expectRevert();
            vm.prank(alice);
            targetShop.buy(1, 1, 100 ether);
            assertEq(bad.balanceOf(alice), 1_000 ether);
            assertEq(bad.balanceOf(address(targetShop)), 0);
            assertEq(bad.balanceOf(address(targetRewards)), 0);
            assertEq(bad.balanceOf(targetShop.BURN_ADDRESS()), 0);
            assertEq(targetShop.balanceOf(alice, 1), 0);
            assertEq(targetShop.purchased(alice, 1), 0);
            assertEq(targetShop.totalBurned(), 0);
            assertEq(targetShop.totalRecycled(), 0);
            assertEq(targetRewards.totalFunded(), 0);
            assertEq(bad.allowance(address(targetShop), address(targetRewards)), 0);
        }
        bad.setFailure(false, address(0), false);
        vm.prank(alice);
        targetShop.buy(1, 1, 100 ether);
        assertEq(targetShop.balanceOf(alice, 1), 1);
    }

    function test_taxedPaymentRejectedAndDirectShopDonationNotSpent() public {
        (AdversarialToken bad,, MoonShop targetShop) = _adversarialShop();
        bad.setFailure(false, address(0), true);
        vm.expectRevert(MoonShop.InexactPayment.selector);
        vm.prank(alice);
        targetShop.buy(1, 1, 100 ether);
        assertEq(bad.balanceOf(alice), 1_000 ether);
        token.transfer(address(shop), 123);
        vm.prank(alice);
        shop.buy(1, 1, 100 ether);
        assertEq(token.balanceOf(address(shop)), 123);
        assertEq(shop.totalBurned() + shop.totalRecycled(), 100 ether);
    }

    function test_overflowCannotCreateFreeItems() public {
        vm.prank(owner);
        shop.configureItem(1, type(uint256).max, 0, 0, true, "ipfs://item");
        vm.expectRevert();
        vm.prank(alice);
        shop.buy(1, 2, type(uint256).max);
        assertEq(shop.balanceOf(alice, 1), 0);
    }

    function _minted(uint256 id) internal view returns (uint256 amount) {
        (,,, amount,,) = shop.items(id);
    }

    function _adversarialShop()
        internal
        returns (AdversarialToken bad, MoonRewards targetRewards, MoonShop targetShop)
    {
        bad = new AdversarialToken();
        targetRewards = new MoonRewards(address(bad), owner);
        targetShop = new MoonShop(address(bad), address(targetRewards), owner);
        vm.prank(owner);
        targetShop.configureItem(1, 100 ether, 100, 10, true, "ipfs://item");
        bad.transfer(alice, 1_000 ether);
        vm.prank(alice);
        bad.approve(address(targetShop), 1_000 ether);
    }
}
