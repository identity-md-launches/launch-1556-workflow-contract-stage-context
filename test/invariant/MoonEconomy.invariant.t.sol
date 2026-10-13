// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {MoonTestBase} from "../helpers/MoonTestBase.sol";
import {PostOfficeMock} from "../helpers/Mocks.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MoonRewards} from "../../src/MoonRewards.sol";
import {MoonShop} from "../../src/MoonShop.sol";

/// @dev Independent accounting model. No environment, RPC, real keys or balance mutation during sequences.
contract EconomyHandler is Test {
    LaunchToken public immutable token;
    MoonRewards public immutable rewards;
    MoonShop public immutable shop;
    PostOfficeMock public immutable postOffice;
    address public immutable owner;
    uint256 private immutable _primaryKey;
    uint256 private immutable _backupKey;
    uint256 private _activeKey;
    address[8] public players;
    mapping(address => bool) public officeOpen;
    bool public paused;

    uint256 public nextNonce;
    uint256 public lastPaidNonce;
    uint256 public funded;
    uint256 public claimed;
    uint256 public burned;
    uint256 public recycled;
    uint256 public minted;
    uint256 public claimsSucceeded;
    uint256 public claimsRejected;
    uint256 public purchasesSucceeded;
    uint256 public purchasesRejected;
    mapping(uint256 => bool) public paidNonce;
    mapping(uint256 => uint256) public paidPerDay;
    mapping(address => mapping(uint256 => uint256)) public paidPerWalletDay;
    mapping(address => uint256) public bought;

    uint256 private constant PRICE = 101 ether + 1;
    uint256 private constant LIMIT = 200;
    uint256 private constant SUPPLY_LIMIT = 1_000;
    bytes32 private constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant VOUCHER_TYPEHASH =
        keccak256("MissionVoucher(address player,uint256 amount,uint256 day,uint256 nonce,uint256 deadline)");

    constructor(LaunchToken token_, MoonRewards rewards_, MoonShop shop_, address owner_, uint256 signerKey_) {
        token = token_;
        rewards = rewards_;
        shop = shop_;
        owner = owner_;
        postOffice = PostOfficeMock(rewards_.POST_OFFICE());
        _primaryKey = signerKey_;
        _activeKey = signerKey_;
        (, uint256 key) = makeAddrAndKey("invariant backup server");
        _backupKey = key;
        vm.prank(owner);
        shop.configureItem(2, PRICE, SUPPLY_LIMIT, LIMIT, true, "ipfs://invariant-item");
        for (uint256 i; i < players.length; ++i) {
            address player = address(uint160(uint256(keccak256(abi.encode("invariant player", i)))));
            players[i] = player;
            postOffice.setOffice(player, true);
            officeOpen[player] = true;
        }
    }

    function fund(uint8 actorSeed, uint256 amountSeed) external {
        address player = players[actorSeed % players.length];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(player));
        uint256 beforeBalance = token.balanceOf(address(rewards));
        vm.prank(player);
        token.approve(address(rewards), amount);
        vm.prank(player);
        (bool ok,) = address(rewards).call(abi.encodeCall(rewards.fund, (amount)));
        assertEq(ok, amount > 0, "fund model disagrees");
        if (ok) funded += amount;
        assertEq(token.balanceOf(address(rewards)), beforeBalance + (ok ? amount : 0));
    }

    function claim(uint8 actorSeed, uint256 amountSeed, uint8 modeSeed) external {
        address player = players[actorSeed % players.length];
        uint256 amount = bound(amountSeed, 500 ether, 2_000 ether);
        uint256 mode = modeSeed % 8;
        MoonRewards.MissionVoucher memory voucher = MoonRewards.MissionVoucher({
            player: player,
            amount: amount,
            day: vm.getBlockTimestamp() / 1 days,
            nonce: ++nextNonce,
            deadline: vm.getBlockTimestamp() + 60
        });
        address caller = player;
        uint256 key = _activeKey;
        if (mode == 1 && claimsSucceeded != 0) voucher.nonce = lastPaidNonce;
        if (mode == 2) key = _activeKey == _primaryKey ? _backupKey : _primaryKey;
        if (mode == 3) voucher.day += 1;
        if (mode == 4) voucher.deadline = vm.getBlockTimestamp() - 1;
        if (mode == 5) caller = players[(uint256(actorSeed) + 1) % players.length];
        uint256 beforeBalance = token.balanceOf(address(rewards));
        uint256 playerBefore = token.balanceOf(player);
        bool expected = !paused && officeOpen[player] && caller == player && key == _activeKey
            && voucher.day == vm.getBlockTimestamp() / 1 days && voucher.deadline >= vm.getBlockTimestamp()
            && !paidNonce[voucher.nonce] && paidPerDay[voucher.day] + amount <= 1_000_000 ether
            && paidPerWalletDay[player][voucher.day] + amount <= 20_000 ether && beforeBalance >= amount;
        bytes memory signature = _sign(voucher, key);
        vm.prank(caller);
        (bool ok,) = address(rewards).call(abi.encodeCall(rewards.claim, (voucher, signature)));
        assertEq(ok, expected, "claim model disagrees");
        if (ok) {
            claimed += amount;
            paidNonce[voucher.nonce] = true;
            paidPerDay[voucher.day] += amount;
            paidPerWalletDay[player][voucher.day] += amount;
            lastPaidNonce = voucher.nonce;
            ++claimsSucceeded;
        } else {
            ++claimsRejected;
        }
        assertEq(token.balanceOf(address(rewards)), beforeBalance - (ok ? amount : 0));
        assertEq(token.balanceOf(player), playerBefore + (ok ? amount : 0));
        assertEq(rewards.usedNonces(voucher.nonce), paidNonce[voucher.nonce]);
        assertEq(rewards.walletDailyPaid(player, voucher.day), paidPerWalletDay[player][voucher.day]);
        assertEq(rewards.dailyPaid(voucher.day), paidPerDay[voucher.day]);
    }

    function buy(uint8 actorSeed, uint256 quantitySeed, bool underquote) external {
        address player = players[actorSeed % players.length];
        uint256 quantity = bound(quantitySeed, 0, 250);
        uint256 cost = quantity * PRICE;
        uint256 maxPrice = underquote && cost > 0 ? cost - 1 : cost;
        uint256 beforeBalance = token.balanceOf(player);
        bool expected = quantity > 0 && maxPrice >= cost && cost <= beforeBalance && bought[player] + quantity <= LIMIT
            && minted + quantity <= SUPPLY_LIMIT;
        vm.prank(player);
        token.approve(address(shop), cost);
        vm.prank(player);
        (bool ok,) = address(shop).call(abi.encodeCall(shop.buy, (2, quantity, maxPrice)));
        assertEq(ok, expected, "purchase model disagrees");
        if (ok) {
            burned += cost / 2;
            recycled += cost - cost / 2;
            bought[player] += quantity;
            minted += quantity;
            ++purchasesSucceeded;
        } else {
            ++purchasesRejected;
        }
        assertEq(token.balanceOf(player), beforeBalance - (ok ? cost : 0));
        assertEq(shop.purchased(player, 2), bought[player]);
    }

    function transferCompanions(uint8 fromSeed, uint8 toSeed, uint256 amountSeed) external {
        address from = players[fromSeed % players.length];
        address to = players[toSeed % players.length];
        uint256 amount = bound(amountSeed, 0, shop.balanceOf(from, 2));
        vm.prank(from);
        shop.safeTransferFrom(from, to, 2, amount, "");
        assertEq(shop.purchased(from, 2), bought[from]);
        assertEq(shop.purchased(to, 2), bought[to]);
    }

    function advanceTime(uint32 timeSeed) external {
        // Both small advances and leaps across multiple UTC boundaries are explored.
        vm.warp(vm.getBlockTimestamp() + bound(timeSeed, 1, 3 days));
    }

    function setOffice(uint8 actorSeed, bool open) external {
        address player = players[actorSeed % players.length];
        postOffice.setOffice(player, open);
        officeOpen[player] = open;
    }

    function setPaused(bool pause_) external {
        if (paused == pause_) return;
        vm.prank(owner);
        if (pause_) rewards.pause();
        else rewards.unpause();
        paused = pause_;
    }

    function rotateSigner(bool useBackup) external {
        _activeKey = useBackup ? _backupKey : _primaryKey;
        vm.prank(owner);
        rewards.setVoucherSigner(vm.addr(_activeKey));
    }

    function _sign(MoonRewards.MissionVoucher memory voucher, uint256 key) private view returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("MOON Rewards"), keccak256("1"), block.chainid, address(rewards))
        );
        bytes32 message = keccak256(
            abi.encode(VOUCHER_TYPEHASH, voucher.player, voucher.amount, voucher.day, voucher.nonce, voucher.deadline)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, message)));
        return abi.encodePacked(r, s, v);
    }
}

contract MoonEconomyInvariantTest is StdInvariant, MoonTestBase {
    EconomyHandler internal handler;
    uint256 internal startingOutsideBalance;

    function setUp() public override {
        super.setUp();
        _fundInitial();
        handler = new EconomyHandler(token, rewards, shop, owner, signerKey);
        for (uint256 i; i < 8; ++i) {
            token.transfer(handler.players(i), 1_000_000 ether);
        }
        startingOutsideBalance = token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.claim.selector;
        selectors[2] = handler.buy.selector;
        selectors[3] = handler.transferCompanions.selector;
        selectors[4] = handler.advanceTime.selector;
        selectors[5] = handler.setOffice.selector;
        selectors[6] = handler.setPaused.selector;
        selectors[7] = handler.rotateSigner.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_poolSolventAndEveryWeiExplainedByDepositsClaimsAndRecycling() public view {
        assertEq(
            token.balanceOf(address(rewards)) + handler.claimed(),
            INITIAL_FUNDING + handler.funded() + handler.recycled()
        );
        assertEq(rewards.totalFunded(), INITIAL_FUNDING + handler.funded() + handler.recycled());
        assertEq(rewards.totalPaid(), handler.claimed());
        assertLe(handler.claimed(), INITIAL_FUNDING + handler.funded() + handler.recycled());
        assertTrue(rewards.activated());
    }

    function invariant_supplyConservedAndNoOwnerOrShopRevenue() public view {
        uint256 balances =
            startingOutsideBalance + token.balanceOf(address(rewards)) + token.balanceOf(shop.BURN_ADDRESS());
        for (uint256 i; i < 8; ++i) {
            balances += token.balanceOf(handler.players(i));
        }
        assertEq(balances, SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(owner), 0);
        assertEq(token.balanceOf(address(shop)), 0);
        assertEq(token.allowance(address(shop), address(rewards)), 0);
        assertEq(token.allowance(address(rewards), owner), 0);
    }

    function invariant_purchaseSplitAndCollectionSupplyMatchIndependentModel() public view {
        assertEq(shop.totalBurned(), handler.burned());
        assertEq(shop.totalRecycled(), handler.recycled());
        assertEq(token.balanceOf(shop.BURN_ADDRESS()), handler.burned());
        (,,, uint256 issued,,) = shop.items(2);
        assertEq(issued, handler.minted());
        uint256 balances;
        for (uint256 i; i < 8; ++i) {
            balances += shop.balanceOf(handler.players(i), 2);
        }
        assertEq(balances, issued);
        assertLe(issued, 1_000);
    }

    function invariant_currentDayCapsMatchModel() public view {
        uint256 day = vm.getBlockTimestamp() / 1 days;
        assertEq(rewards.dailyPaid(day), handler.paidPerDay(day));
        assertLe(rewards.dailyPaid(day), 1_000_000 ether);
        for (uint256 i; i < 8; ++i) {
            address player = handler.players(i);
            assertEq(rewards.walletDailyPaid(player, day), handler.paidPerWalletDay(player, day));
            assertLe(rewards.walletDailyPaid(player, day), 20_000 ether);
        }
    }

    function test_multiDaySequenceExercisesBothSuccessAndFailure() public {
        // Guarantees substantive activity even if a random invariant campaign chooses many disabled claims.
        for (uint256 i; i < 40; ++i) {
            handler.setPaused(false);
            handler.setOffice(uint8(i % 8), true);
            handler.claim(uint8(i % 8), 1_000 ether, 0);
            handler.claim(uint8(i % 8), 1_000 ether, 1);
            handler.buy(uint8(i % 8), 1, false);
            handler.buy(uint8(i % 8), 1, true);
            handler.fund(uint8(i % 8), 10 ether);
            handler.advanceTime(1 days);
            handler.rotateSigner(i % 2 == 0);
        }
        assertEq(handler.claimsSucceeded(), 40);
        assertEq(handler.claimsRejected(), 40);
        assertEq(handler.purchasesSucceeded(), 40);
        assertEq(handler.purchasesRejected(), 40);
        invariant_poolSolventAndEveryWeiExplainedByDepositsClaimsAndRecycling();
        invariant_supplyConservedAndNoOwnerOrShopRevenue();
        invariant_purchaseSplitAndCollectionSupplyMatchIndependentModel();
        invariant_currentDayCapsMatchModel();
    }
}
