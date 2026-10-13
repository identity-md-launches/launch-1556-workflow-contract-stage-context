// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MoonTestBase} from "../helpers/MoonTestBase.sol";
import {PostOfficeMock} from "../helpers/Mocks.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {MoonRewards} from "src/MoonRewards.sol";
import {MoonShop} from "src/MoonShop.sol";

/// @dev Exercises activation, changing catalog terms, shared permit nonces and multiple item balances.
/// All ledger entries come from initial allocations and successful inputs, never contract counters.
contract MoonLifecycleHandler is Test {
    struct CatalogItem {
        uint256 price;
        uint256 cap;
        uint256 walletLimit;
        uint256 issued;
        bool enabled;
        string metadata;
    }

    struct Payment {
        uint256 mode;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    uint256 public constant THRESHOLD = 700_000_000 ether;
    uint256 public constant STARTING_POOL = THRESHOLD - 2_000 ether;
    uint256 public constant PLAYER_ALLOCATION = 1_000_000 ether;
    uint256 private constant FIRST_ITEM = 101;
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 private constant VOUCHER_TYPEHASH =
        keccak256("MissionVoucher(address player,uint256 amount,uint256 day,uint256 nonce,uint256 deadline)");

    LaunchToken public immutable token;
    MoonRewards public immutable rewards;
    MoonShop public immutable shop;
    address private immutable owner;
    uint256 private immutable signerKey;
    address[4] public players;
    uint256[4] private keys;
    CatalogItem[3] private catalog;

    uint256[4] private moonBalances;
    uint256[4] private permitNonces;
    uint256[3][4] private inventory;
    uint256[3][4] private purchases;
    uint256 public poolBalance = STARTING_POOL;
    uint256 public directPoolDonations;
    uint256 public directShopDonations;
    uint256 public deposits = STARTING_POOL;
    uint256 public paid;
    uint256 public spent;
    uint256 public burned;
    uint256 public recycled;
    bool public activated;
    bool private paused;
    uint256 public successfulClaims;
    uint256 public rejectedClaims;
    uint256 public successfulBuys;
    uint256 public rejectedBuys;
    uint256 public successfulFunds;
    uint256 public rejectedFunds;
    uint256 public successfulEdits;
    uint256 public rejectedEdits;
    uint256 public successfulTransfers;
    uint256 public rejectedTransfers;
    mapping(uint256 => bool) private noncePaid;
    mapping(uint256 => uint256) private dayPaid;
    mapping(uint256 => mapping(uint256 => uint256)) private playerDayPaid;
    uint256[] private paidDays;

    constructor(LaunchToken token_, MoonRewards rewards_, MoonShop shop_, address owner_, uint256 signerKey_) {
        token = token_;
        rewards = rewards_;
        shop = shop_;
        owner = owner_;
        signerKey = signerKey_;
        for (uint256 i; i < players.length; ++i) {
            (players[i], keys[i]) = makeAddrAndKey(string.concat("lifecycle player ", vm.toString(i)));
            moonBalances[i] = PLAYER_ALLOCATION;
            PostOfficeMock(rewards.POST_OFFICE()).setOffice(players[i], true);
        }
        for (uint256 i; i < catalog.length; ++i) {
            catalog[i] = CatalogItem((i + 1) * 100 ether + 1, 0, 0, 0, true, "ipfs://initial");
            vm.prank(owner);
            shop.configureItem(FIRST_ITEM + i, catalog[i].price, 0, 0, true, "ipfs://initial");
        }
    }

    // mode: 0 = approval, 1 = valid permit, 2 = expired permit/no approval, 3 = expired permit/approval.
    function fund(uint8 actorSeed, uint256 amountSeed, uint8 modeSeed) external {
        uint256 actor = actorSeed % players.length;
        uint256 amount = bound(amountSeed, 0, moonBalances[actor]);
        Payment memory p = _preparePayment(actor, address(rewards), amount, modeSeed);
        bytes memory callData = p.mode == 0
            ? abi.encodeCall(rewards.fund, (amount))
            : abi.encodeCall(rewards.fundWithPermit, (amount, p.deadline, p.v, p.r, p.s));
        bool expected = amount > 0 && p.mode != 2;
        vm.prank(players[actor]);
        (bool ok,) = address(rewards).call(callData);
        assertEq(ok, expected, "deposit must match amount and approval authorization");
        if (ok) {
            moonBalances[actor] -= amount;
            poolBalance += amount;
            deposits += amount;
            activated = activated || poolBalance >= THRESHOLD;
            if (p.mode == 1) ++permitNonces[actor];
            ++successfulFunds;
        } else {
            ++rejectedFunds;
        }
        _checkPayment(actor, address(rewards), p.mode, amount, ok ? amount : 0, ok);
    }

    function donate(uint8 actorSeed, uint256 amountSeed, bool toShop) external {
        uint256 actor = actorSeed % players.length;
        uint256 amount = bound(amountSeed, 0, moonBalances[actor]);
        vm.prank(players[actor]);
        assertTrue(token.transfer(toShop ? address(shop) : address(rewards), amount));
        moonBalances[actor] -= amount;
        if (toShop) {
            directShopDonations += amount;
        } else {
            directPoolDonations += amount;
            poolBalance += amount;
        }
        // Direct transfers do not invoke a rewards function or latch activation.
    }

    function buy(uint8 actorSeed, uint8 itemSeed, uint8 quantitySeed, uint8 modeSeed, bool underquote) external {
        uint256 actor = actorSeed % players.length;
        uint256 itemId = itemSeed % catalog.length;
        uint256 quantity = uint256(quantitySeed) % 9;
        CatalogItem storage item = catalog[itemId];
        uint256 cost = item.price * quantity;
        uint256 quote = underquote && cost != 0 ? cost - 1 : cost + 7;
        Payment memory p = _preparePayment(actor, address(shop), quote, modeSeed);
        bool expected = item.enabled && quantity != 0 && quote >= cost && cost <= moonBalances[actor] && p.mode != 2
            && (item.cap == 0 || item.issued + quantity <= item.cap)
            && (item.walletLimit == 0 || purchases[actor][itemId] + quantity <= item.walletLimit);
        bytes memory callData = p.mode == 0
            ? abi.encodeCall(shop.buy, (FIRST_ITEM + itemId, quantity, quote))
            : abi.encodeCall(shop.buyWithPermit, (FIRST_ITEM + itemId, quantity, quote, p.deadline, p.v, p.r, p.s));
        vm.prank(players[actor]);
        (bool ok,) = address(shop).call(callData);
        assertEq(ok, expected, "purchase must respect current terms and buyer authorization");
        if (ok) {
            uint256 poolShare = (cost + 1) / 2;
            moonBalances[actor] -= cost;
            poolBalance += poolShare;
            spent += cost;
            recycled += poolShare;
            burned += cost - poolShare;
            ++successfulBuys;
            inventory[actor][itemId] += quantity;
            purchases[actor][itemId] += quantity;
            item.issued += quantity;
            activated = activated || poolBalance >= THRESHOLD;
            if (p.mode == 1) ++permitNonces[actor];
        } else {
            ++rejectedBuys;
        }
        _checkPayment(actor, address(shop), p.mode, quote, ok ? cost : 0, ok);
    }

    function configure(
        uint8 itemSeed,
        uint256 priceSeed,
        uint8 capSeed,
        uint8 limitSeed,
        bool enabled,
        bool unauthorized
    ) external {
        uint256 itemId = itemSeed % catalog.length;
        CatalogItem memory proposed = CatalogItem({
            price: bound(priceSeed, 0, 1_000 ether),
            cap: uint256(capSeed) % 41,
            walletLimit: uint256(limitSeed) % 13,
            issued: catalog[itemId].issued,
            enabled: enabled,
            metadata: string.concat("ipfs://catalog/", vm.toString(priceSeed))
        });
        _configure(itemId, proposed, unauthorized);
    }

    function _configure(uint256 itemId, CatalogItem memory proposed, bool unauthorized) private {
        bool expected = !unauthorized && proposed.price > 0 && (proposed.cap == 0 || proposed.cap >= proposed.issued);
        vm.prank(unauthorized ? players[0] : owner);
        (bool ok,) = address(shop)
            .call(
                abi.encodeCall(
                    shop.configureItem,
                    (
                        FIRST_ITEM + itemId,
                        proposed.price,
                        proposed.cap,
                        proposed.walletLimit,
                        proposed.enabled,
                        proposed.metadata
                    )
                )
            );
        assertEq(ok, expected, "catalog edit must preserve previously sold supply");
        if (ok) {
            catalog[itemId] = proposed;
            ++successfulEdits;
        } else {
            ++rejectedEdits;
        }
    }

    function transferItem(uint8 fromSeed, uint8 toSeed, uint8 itemSeed, uint256 amountSeed, uint8 modeSeed) external {
        uint256 from = fromSeed % players.length;
        uint256 to = toSeed % players.length;
        uint256 itemId = itemSeed % catalog.length;
        uint256 amount = bound(amountSeed, 0, inventory[from][itemId] + 1);
        uint256 mode = modeSeed % 3;
        address operator = players[(from + 1) % players.length];
        vm.prank(players[from]);
        shop.setApprovalForAll(operator, mode == 1);
        bool expected = mode != 2 && amount <= inventory[from][itemId];
        vm.prank(mode == 0 ? players[from] : operator);
        (bool ok,) = address(shop)
            .call(abi.encodeCall(shop.safeTransferFrom, (players[from], players[to], FIRST_ITEM + itemId, amount, "")));
        assertEq(ok, expected, "transfer must require holdings and current operator approval");
        if (ok) {
            inventory[from][itemId] -= amount;
            inventory[to][itemId] += amount;
            ++successfulTransfers;
        } else {
            ++rejectedTransfers;
        }
    }

    function claim(uint8 actorSeed, uint256 amountSeed, uint8 nonceSeed) external {
        uint256 actor = actorSeed % players.length;
        uint256 amount = bound(amountSeed, 500 ether, 2_000 ether);
        uint256 day = vm.getBlockTimestamp() / 1 days;
        // Deliberately small nonce space creates collisions across players and days.
        uint256 nonce = nonceSeed % 32;
        MoonRewards.MissionVoucher memory voucher =
            MoonRewards.MissionVoucher(players[actor], amount, day, nonce, vm.getBlockTimestamp());
        bool expected = !paused && (activated || poolBalance >= THRESHOLD) && !noncePaid[nonce]
            && playerDayPaid[actor][day] + amount <= 20_000 ether && dayPaid[day] + amount <= 1_000_000 ether
            && poolBalance >= amount;
        bytes32 message = keccak256(abi.encode(VOUCHER_TYPEHASH, voucher));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest("MOON Rewards", address(rewards), message));
        vm.prank(players[actor]);
        (bool ok,) = address(rewards).call(abi.encodeCall(rewards.claim, (voucher, abi.encodePacked(r, s, v))));
        assertEq(ok, expected, "valid mission must pay iff funding, pause, nonce and caps permit");
        if (ok) {
            if (dayPaid[day] == 0) paidDays.push(day);
            playerDayPaid[actor][day] += amount;
            dayPaid[day] += amount;
            paid += amount;
            moonBalances[actor] += amount;
            poolBalance -= amount;
            activated = true;
            noncePaid[nonce] = true;
            ++successfulClaims;
        } else {
            ++rejectedClaims;
        }
        assertEq(rewards.usedNonces(nonce), noncePaid[nonce]);
        assertEq(rewards.dailyPaid(day), dayPaid[day]);
        assertEq(rewards.walletDailyPaid(players[actor], day), playerDayPaid[actor][day]);
    }

    function setPaused(bool value) external {
        if (value == paused) return;
        vm.prank(owner);
        if (value) rewards.pause();
        else rewards.unpause();
        paused = value;
    }

    function advanceTime(uint32 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 1, 2 days));
    }

    function assertAccounting() external view {
        assertEq(token.balanceOf(address(rewards)), poolBalance, "pool actual balance differs from ledger");
        assertEq(poolBalance + paid, deposits + directPoolDonations + recycled, "every reward wei explained");
        assertEq(rewards.totalPaid(), paid);
        assertEq(rewards.totalFunded(), deposits + recycled, "donations must not be miscounted as fund calls");
        assertEq(rewards.activated(), activated, "activation latch differs from successful history");
        assertEq(rewards.isFunded(), activated || poolBalance >= THRESHOLD);
        assertEq(rewards.paused(), paused);
        assertEq(shop.totalBurned(), burned);
        assertEq(shop.totalRecycled(), recycled);
        assertEq(spent, burned + recycled, "no purchase proceeds missing");
        assertEq(token.balanceOf(shop.BURN_ADDRESS()), burned);
        assertEq(token.balanceOf(address(shop)), directShopDonations, "shop cannot spend prior donations");
        assertEq(token.allowance(address(shop), address(rewards)), 0, "no residual recycler authority");
        assertEq(token.balanceOf(owner), 0, "no primary-sale owner revenue");
        assertEq(token.totalSupply(), 1_000_000_000 ether);

        for (uint256 actor; actor < players.length; ++actor) {
            assertEq(token.balanceOf(players[actor]), moonBalances[actor], "player MOON accounting");
            assertEq(token.nonces(players[actor]), permitNonces[actor], "shared permit nonce accounting");
            assertEq(token.allowance(address(rewards), players[actor]), 0);
        }
        for (uint256 i; i < catalog.length; ++i) {
            CatalogItem storage item = catalog[i];
            (uint256 price, uint256 cap, uint256 limit, uint256 issued, bool enabled, bool exists) =
                shop.items(FIRST_ITEM + i);
            assertTrue(exists);
            assertEq(price, item.price);
            assertEq(cap, item.cap);
            assertEq(limit, item.walletLimit);
            assertEq(issued, item.issued);
            assertEq(enabled, item.enabled);
            assertEq(shop.uri(FIRST_ITEM + i), item.metadata);
            uint256 held;
            uint256 bought;
            for (uint256 actor; actor < players.length; ++actor) {
                assertEq(shop.balanceOf(players[actor], FIRST_ITEM + i), inventory[actor][i], "item distribution");
                assertEq(shop.purchased(players[actor], FIRST_ITEM + i), purchases[actor][i], "lifetime purchases");
                held += inventory[actor][i];
                bought += purchases[actor][i];
            }
            assertEq(held, issued, "all minted inventory must be held");
            assertEq(bought, issued, "no unpurchased mint");
            if (cap != 0) assertLe(issued, cap);
        }
        uint256 historicalPaid;
        for (uint256 i; i < paidDays.length; ++i) {
            uint256 day = paidDays[i];
            uint256 walletSum;
            for (uint256 actor; actor < players.length; ++actor) {
                uint256 amount = rewards.walletDailyPaid(players[actor], day);
                assertEq(amount, playerDayPaid[actor][day], "historical wallet accounting");
                assertLe(amount, 20_000 ether);
                walletSum += amount;
            }
            assertEq(rewards.dailyPaid(day), walletSum);
            assertEq(walletSum, dayPaid[day]);
            assertLe(walletSum, 1_000_000 ether);
            historicalPaid += walletSum;
        }
        assertEq(historicalPaid, paid, "daily totals must sum to lifetime payouts");
        for (uint256 nonce; nonce < 32; ++nonce) {
            assertEq(rewards.usedNonces(nonce), noncePaid[nonce]);
        }
    }

    function _preparePayment(uint256 actor, address spender, uint256 amount, uint8 modeSeed)
        private
        returns (Payment memory p)
    {
        p.mode = modeSeed % 4;
        // Reset approvals so an expired permit never accidentally succeeds due to an earlier order's dust.
        vm.prank(players[actor]);
        token.approve(spender, p.mode == 0 || p.mode == 3 ? amount : 0);
        if (p.mode == 0) return p;
        p.deadline = p.mode == 1 ? vm.getBlockTimestamp() : vm.getBlockTimestamp() - 1;
        bytes32 message =
            keccak256(abi.encode(PERMIT_TYPEHASH, players[actor], spender, amount, permitNonces[actor], p.deadline));
        (p.v, p.r, p.s) = vm.sign(keys[actor], _digest("MOON", address(token), message));
    }

    function _checkPayment(uint256 actor, address spender, uint256 mode, uint256 approved, uint256 charged, bool ok)
        private
        view
    {
        uint256 expectedAllowance = mode == 0 || mode == 3 || (mode == 1 && ok) ? approved - charged : 0;
        assertEq(token.allowance(players[actor], spender), expectedAllowance, "allowance must roll back on failure");
        assertEq(token.nonces(players[actor]), permitNonces[actor], "permit nonce must roll back on failure");
    }

    function _digest(string memory name, address target, bytes32 message) private view returns (bytes32) {
        bytes32 domain =
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256("1"), block.chainid, target));
        return keccak256(abi.encodePacked("\x19\x01", domain, message));
    }
}

contract MoonLifecycleInvariantTest is StdInvariant, MoonTestBase {
    MoonLifecycleHandler private handler;
    uint256 private outsideBalance;

    function setUp() public override {
        super.setUp();
        token.approve(address(rewards), INITIAL_FUNDING - 2_000 ether);
        rewards.fund(INITIAL_FUNDING - 2_000 ether);
        handler = new MoonLifecycleHandler(token, rewards, shop, owner, signerKey);
        for (uint256 i; i < 4; ++i) {
            assertTrue(token.transfer(handler.players(i), handler.PLAYER_ALLOCATION()));
        }
        outsideBalance = token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.buy.selector;
        selectors[3] = handler.configure.selector;
        selectors[4] = handler.transferItem.selector;
        selectors[5] = handler.claim.selector;
        selectors[6] = handler.setPaused.selector;
        selectors[7] = handler.advanceTime.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allFundsInventoryAndHistoricalCapsMatchTheIndependentLedger() public view {
        handler.assertAccounting();
        uint256 balances = outsideBalance + token.balanceOf(address(rewards)) + token.balanceOf(address(shop))
            + token.balanceOf(shop.BURN_ADDRESS());
        for (uint256 i; i < 4; ++i) {
            balances += token.balanceOf(handler.players(i));
        }
        assertEq(balances, SUPPLY, "all fixed-supply MOON remains accounted for");
    }

    function test_sequenceCoversUnfundedClaimsActivationPermitsAndCatalogChanges() public {
        handler.claim(0, 500 ether, 0); // Unfunded; nonce remains reusable.
        handler.fund(0, 0, 1); // A valid zero-value permit must roll back too.
        handler.donate(1, 2_000 ether, false);
        assertFalse(rewards.activated());
        handler.claim(0, 500 ether, 0); // Direct donation allows first claim to activate.
        handler.claim(1, 500 ether, 0); // Global replay rejected for a different player.
        handler.fund(0, 1, 1); // Shares the ERC-2612 nonce stream with the next buy.
        handler.buy(0, 0, 2, 1, false);
        handler.buy(0, 0, 1, 2, false); // Expired permit without approval.
        handler.buy(0, 0, 1, 3, false); // Expired permit with explicit approval.
        handler.buy(0, 0, 1, 1, true); // Quote failure restores permit nonce.
        handler.transferItem(0, 1, 0, 2, 1);
        handler.transferItem(0, 1, 0, 1, 2); // Revoked operator.
        handler.configure(0, 1, 0, 3, true, false); // Lifetime limit remains reached after transfer.
        handler.buy(0, 0, 1, 0, false);
        handler.configure(0, 1, 2, 0, true, false); // Cannot lower supply below three minted.
        handler.configure(1, 1, 0, 0, true, true); // Non-owner cannot edit another item.
        handler.setPaused(true);
        handler.claim(1, 500 ether, 1);
        handler.buy(1, 1, 1, 0, false); // Recycling still works while paused.
        handler.fund(1, 1, 3);
        handler.setPaused(false);
        handler.advanceTime(1 days);
        handler.claim(1, 500 ether, 1);
        handler.donate(2, 17, true);
        handler.buy(2, 2, 1, 1, false); // Existing shop donations are preserved.

        assertEq(handler.successfulClaims(), 2);
        assertEq(handler.rejectedClaims(), 3);
        assertEq(handler.successfulFunds(), 2);
        assertEq(handler.rejectedFunds(), 1);
        assertEq(handler.successfulBuys(), 4);
        assertEq(handler.rejectedBuys(), 3);
        assertEq(handler.successfulEdits(), 1);
        assertEq(handler.rejectedEdits(), 2);
        assertEq(handler.successfulTransfers(), 1);
        assertEq(handler.rejectedTransfers(), 1);
        invariant_allFundsInventoryAndHistoricalCapsMatchTheIndependentLedger();
    }

    function test_sequenceShopRecyclingActivatesAndFundingRemainsPermanent() public {
        handler.configure(0, 1_000 ether, 0, 0, true, false);
        handler.buy(0, 0, 4, 1, false);
        assertTrue(rewards.activated());
        assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING);
        handler.claim(0, 2_000 ether, 0);
        handler.fund(1, 1, 1);
        handler.claim(1, 500 ether, 1);
        assertTrue(rewards.activated());
        assertLt(token.balanceOf(address(rewards)), INITIAL_FUNDING);
        invariant_allFundsInventoryAndHistoricalCapsMatchTheIndependentLedger();
    }
}
