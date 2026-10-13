// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MoonTestBase} from "./helpers/MoonTestBase.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is MoonTestBase {
    function test_fixedSupplyAndMetadataMintedOnlyToDeployer() public {
        LaunchToken fresh = new LaunchToken();
        assertEq(fresh.name(), "MOON");
        assertEq(fresh.symbol(), "MOON");
        assertEq(fresh.decimals(), 18);
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(address(this)), SUPPLY);
        assertEq(fresh.balanceOf(owner), 0);
    }

    function testFuzz_transferIsExact(uint256 amount) public {
        amount = bound(amount, 0, token.balanceOf(alice));
        uint256 fromBefore = token.balanceOf(alice);
        uint256 toBefore = token.balanceOf(bob);
        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(alice), fromBefore - amount);
        assertEq(token.balanceOf(bob), toBefore + amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferFromConsumesAllowanceAndRejectsOverspend() public {
        vm.prank(alice);
        token.approve(bob, 100 ether);
        vm.prank(bob);
        token.transferFrom(alice, bob, 100 ether);
        assertEq(token.allowance(alice, bob), 0);
        vm.expectRevert();
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
    }

    function test_noAdminOrMintEntrypointsEvenForFactory() public {
        bytes[9] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", alice, 1),
            abi.encodeWithSignature("mint(uint256)", 1),
            abi.encodeWithSignature("mint()"),
            abi.encodeWithSignature("setOwner(address)", alice),
            abi.encodeWithSignature("transferOwnership(address)", alice),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("upgradeTo(address)", alice),
            abi.encodeWithSignature("setMinter(address)", alice),
            abi.encodeWithSignature("initialize(address)", alice)
        ];
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
            vm.prank(alice);
            (ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_permitReplayAndExpiration() public {
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _permit(alice, bob, 42, deadline, aliceKey);
        token.permit(alice, bob, 42, deadline, v, r, s);
        assertEq(token.allowance(alice, bob), 42);
        assertEq(token.nonces(alice), 1);
        vm.expectRevert();
        token.permit(alice, bob, 42, deadline, v, r, s);
        (v, r, s) = _permit(alice, bob, 99, deadline, aliceKey);
        vm.warp(deadline + 1);
        vm.expectRevert();
        token.permit(alice, bob, 99, deadline, v, r, s);
        assertEq(token.nonces(alice), 1);
        assertEq(token.allowance(alice, bob), 42);
    }

    function test_permitRejectsWrongSignerAndChangedChain() public {
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _permit(alice, bob, 42, deadline, bobKey);
        vm.expectRevert();
        token.permit(alice, bob, 42, deadline, v, r, s);
        (v, r, s) = _permit(alice, bob, 42, deadline, aliceKey);
        vm.chainId(1);
        vm.expectRevert();
        token.permit(alice, bob, 42, deadline, v, r, s);
        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.nonces(alice), 0);
    }

    function test_zeroAddressAndInsufficientBalanceTransfersFail() public {
        vm.expectRevert();
        token.transfer(address(0), 1);
        vm.expectRevert();
        vm.prank(owner);
        token.transfer(alice, 1);
    }
}
