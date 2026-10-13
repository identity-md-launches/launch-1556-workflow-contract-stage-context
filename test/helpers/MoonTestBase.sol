// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {MoonRewards} from "../../src/MoonRewards.sol";
import {MoonShop} from "../../src/MoonShop.sol";
import {PostOfficeMock} from "./Mocks.sol";

abstract contract MoonTestBase is Test {
    LaunchToken internal token;
    MoonRewards internal rewards;
    MoonShop internal shop;
    PostOfficeMock internal postOffice;
    address internal owner;
    address internal alice;
    address internal bob;
    address internal signer;
    uint256 internal signerKey;
    uint256 internal aliceKey;
    uint256 internal bobKey;
    uint256 internal constant INITIAL_FUNDING = 700_000_000 ether;
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    uint256 internal constant TEST_CHAIN_ID = 4663;
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant VOUCHER_TYPEHASH =
        keccak256("MissionVoucher(address player,uint256 amount,uint256 day,uint256 nonce,uint256 deadline)");
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public virtual {
        vm.chainId(TEST_CHAIN_ID);
        vm.warp(20_000 days + 12 hours);
        owner = makeAddr("creator");
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");
        (signer, signerKey) = makeAddrAndKey("test game server");
        token = new LaunchToken();
        rewards = new MoonRewards(address(token), owner);
        shop = new MoonShop(address(token), address(rewards), owner);
        PostOfficeMock implementation = new PostOfficeMock();
        vm.etch(rewards.POST_OFFICE(), address(implementation).code);
        postOffice = PostOfficeMock(rewards.POST_OFFICE());
        postOffice.setOffice(alice, true);
        postOffice.setOffice(bob, true);
        vm.prank(owner);
        rewards.setVoucherSigner(signer);
        vm.prank(owner);
        shop.configureItem(1, 100 ether, 100, 10, true, "ipfs://courier-companions/1.json");
        token.transfer(alice, 100_000 ether);
        token.transfer(bob, 100_000 ether);
    }

    function _fundInitial() internal {
        token.approve(address(rewards), INITIAL_FUNDING);
        rewards.fund(INITIAL_FUNDING);
    }

    function _voucher(address player, uint256 amount, uint256 nonce)
        internal
        view
        returns (MoonRewards.MissionVoucher memory)
    {
        return MoonRewards.MissionVoucher(
            player, amount, vm.getBlockTimestamp() / 1 days, nonce, vm.getBlockTimestamp() + 1 hours
        );
    }

    /// @dev Independent encoding, so tests do not simply trust the implementation's digest helper.
    function _digest(MoonRewards target, MoonRewards.MissionVoucher memory voucher) internal pure returns (bytes32) {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("MOON Rewards"), keccak256("1"), TEST_CHAIN_ID, address(target))
        );
        bytes32 message = keccak256(
            abi.encode(VOUCHER_TYPEHASH, voucher.player, voucher.amount, voucher.day, voucher.nonce, voucher.deadline)
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, message));
    }

    function _signature(MoonRewards target, MoonRewards.MissionVoucher memory voucher, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, _digest(target, voucher));
        return abi.encodePacked(r, s, v);
    }

    function _claim(address player, uint256 amount, uint256 nonce) internal {
        MoonRewards.MissionVoucher memory voucher = _voucher(player, amount, nonce);
        bytes memory signature = _signature(rewards, voucher, signerKey);
        vm.prank(player);
        rewards.claim(voucher, signature);
    }

    function _permit(address holder, address spender, uint256 value, uint256 deadline, uint256 key)
        internal
        view
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 domain = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256("MOON"), keccak256("1"), TEST_CHAIN_ID, address(token))
        );
        bytes32 message = keccak256(abi.encode(PERMIT_TYPEHASH, holder, spender, value, token.nonces(holder), deadline));
        return vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, message)));
    }
}
