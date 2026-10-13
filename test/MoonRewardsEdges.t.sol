// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MoonTestBase} from "./helpers/MoonTestBase.sol";
import {Vm} from "forge-std/Vm.sol";
import {MoonRewards} from "src/MoonRewards.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev If offices were called with CALL instead of STATICCALL this would open an office.
contract WritingPostOffice {
    uint256 public writes;

    function offices(address) external returns (bool) {
        ++writes;
        return true;
    }
}

contract MoonRewardsEdgesTest is MoonTestBase {
    event Funded(address indexed funder, uint256 amount, uint256 poolBalance);
    event RewardPoolActivated(uint256 poolBalance);
    event MissionClaimed(address indexed player, uint256 indexed nonce, uint256 indexed day, uint256 amount);

    function test_fundingAndClaimEventsExposeExactPublicAccounting() public {
        token.approve(address(rewards), INITIAL_FUNDING + 1);
        vm.expectEmit(true, false, false, true, address(rewards));
        emit Funded(address(this), INITIAL_FUNDING - 1, INITIAL_FUNDING - 1);
        rewards.fund(INITIAL_FUNDING - 1);
        assertFalse(rewards.activated());

        vm.expectEmit(true, false, false, true, address(rewards));
        emit Funded(address(this), 1, INITIAL_FUNDING);
        vm.expectEmit(false, false, false, true, address(rewards));
        emit RewardPoolActivated(INITIAL_FUNDING);
        rewards.fund(1);

        vm.expectEmit(true, true, true, true, address(rewards));
        emit MissionClaimed(alice, type(uint256).max, rewards.currentDay(), 500 ether);
        _claim(alice, 500 ether, type(uint256).max);
        assertEq(rewards.totalFunded(), INITIAL_FUNDING);
        assertEq(rewards.totalPaid(), 500 ether);

        // Activation is emitted once even if a later deposit crosses the threshold again.
        token.approve(address(rewards), 500 ether);
        vm.recordLogs();
        rewards.fund(500 ether);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 activationTopic = keccak256("RewardPoolActivated(uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(rewards)) assertNotEq(logs[i].topics[0], activationTopic);
        }
    }

    function test_failedPermitFundingRestoresNonceAndPreviousAllowanceThenCanRetry() public {
        uint256 balance = token.balanceOf(alice);
        uint256 amount = balance + 1;
        uint256 deadline = vm.getBlockTimestamp();
        vm.prank(alice);
        token.approve(address(rewards), 17);
        (uint8 v, bytes32 r, bytes32 s) = _permit(alice, address(rewards), amount, deadline, aliceKey);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, amount));
        vm.prank(alice);
        rewards.fundWithPermit(amount, deadline, v, r, s);
        assertEq(token.nonces(alice), 0);
        assertEq(token.allowance(alice, address(rewards)), 17);
        assertEq(token.balanceOf(alice), balance);
        assertEq(rewards.totalFunded(), 0);
        assertEq(token.balanceOf(address(rewards)), 0);

        assertTrue(token.transfer(alice, 1));
        vm.prank(alice);
        rewards.fundWithPermit(amount, deadline, v, r, s);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.nonces(alice), 1);
        assertEq(token.allowance(alice, address(rewards)), 0);
        assertEq(rewards.totalFunded(), amount);
    }

    function test_zeroPermitFundingCannotConsumeNonceOrReplaceApproval() public {
        uint256 deadline = vm.getBlockTimestamp();
        vm.prank(alice);
        token.approve(address(rewards), 23);
        (uint8 v, bytes32 r, bytes32 s) = _permit(alice, address(rewards), 0, deadline, aliceKey);
        vm.expectRevert(MoonRewards.ZeroAmount.selector);
        vm.prank(alice);
        rewards.fundWithPermit(0, deadline, v, r, s);
        assertEq(token.nonces(alice), 0);
        assertEq(token.allowance(alice, address(rewards)), 23);
        assertEq(rewards.totalFunded(), 0);
    }

    function test_expiredPermitCanUseOnlyCallersExistingApprovalWhilePaused() public {
        uint256 deadline = vm.getBlockTimestamp() - 1;
        (uint8 v, bytes32 r, bytes32 s) = _permit(alice, address(rewards), 500 ether, deadline, aliceKey);
        vm.prank(alice);
        token.approve(address(rewards), 500 ether);
        vm.prank(owner);
        rewards.pause();
        vm.prank(alice);
        rewards.fundWithPermit(500 ether, deadline, v, r, s);
        assertEq(token.nonces(alice), 0, "expired signature was not consumed");
        assertEq(token.allowance(alice, address(rewards)), 0);
        assertEq(rewards.totalFunded(), 500 ether);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(rewards), 0, 1)
        );
        vm.prank(alice);
        rewards.fundWithPermit(1, deadline, v, r, s);
        assertEq(rewards.totalFunded(), 500 ether);
    }

    function test_maximumFundingInputCannotOverflowOrCreateCredit() public {
        vm.prank(alice);
        token.approve(address(rewards), type(uint256).max);
        uint256 balance = token.balanceOf(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, balance, type(uint256).max)
        );
        vm.prank(alice);
        rewards.fund(type(uint256).max);
        assertEq(token.allowance(alice, address(rewards)), type(uint256).max);
        assertEq(token.balanceOf(alice), balance);
        assertEq(rewards.totalFunded(), 0);
        assertFalse(rewards.activated());
    }

    function test_nonceZeroAndMaximumAreIndependentPermanentIdentifiers() public {
        _fundInitial();
        _claim(alice, 500 ether, 0);
        _claim(bob, 500 ether, type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(owner);
        rewards.setVoucherSigner(bob);
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, type(uint256).max);
        bytes memory sig = _signature(rewards, voucher, bobKey);
        vm.expectRevert(MoonRewards.NonceAlreadyUsed.selector);
        vm.prank(alice);
        rewards.claim(voucher, sig);
        assertTrue(rewards.usedNonces(0));
        assertTrue(rewards.usedNonces(type(uint256).max));
        assertEq(rewards.totalPaid(), 1_000 ether);
        assertEq(rewards.dailyPaid(rewards.currentDay()), 0);
    }

    function test_globalCapRejectsOneWeiOverWithoutSpendingTheVoucher() public {
        _fundInitial();
        for (uint256 i; i < 49; ++i) {
            address player = makeAddr(string.concat("global cap player ", vm.toString(i)));
            postOffice.setOffice(player, true);
            for (uint256 j; j < 10; ++j) {
                _claim(player, 2_000 ether, i * 10 + j);
            }
        }
        for (uint256 i; i < 9; ++i) {
            _claim(bob, 2_000 ether, 490 + i);
        }
        _claim(bob, 1_500 ether + 1, 499);
        uint256 day = rewards.currentDay();
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 500);
        bytes memory signature = _signature(rewards, voucher, signerKey);
        uint256 playerBefore = token.balanceOf(alice);
        vm.expectRevert(MoonRewards.GlobalDailyCapExceeded.selector);
        vm.prank(alice);
        rewards.claim(voucher, signature);
        assertFalse(rewards.usedNonces(500));
        assertEq(rewards.dailyPaid(day), 999_500 ether + 1);
        assertEq(rewards.walletDailyPaid(alice, day), 0);
        assertEq(rewards.totalPaid(), 999_500 ether + 1);
        assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING - (999_500 ether + 1));
        assertEq(token.balanceOf(alice), playerBefore);

        vm.warp((day + 1) * 1 days);
        _claim(alice, 500 ether, 500);
        assertTrue(rewards.usedNonces(500));
        assertEq(rewards.dailyPaid(day + 1), 500 ether);
        assertEq(rewards.dailyPaid(day), 999_500 ether + 1);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_postOfficeRejectsEveryNonCanonicalBoolean(uint256 response) public {
        response = bound(response, 2, type(uint256).max);
        _fundInitial();
        vm.mockCall(address(postOffice), abi.encodeWithSignature("offices(address)", alice), abi.encode(response));
        _assertOfficeFailure();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_postOfficeRejectsResponsesShorterThanOneWord(uint8 lengthSeed) public {
        // Every length from 0 through 31, with a would-be `true` in the last byte present.
        uint256 length = uint256(lengthSeed) % 32;
        bytes memory response = new bytes(length);
        if (length > 0) response[length - 1] = 0x01;
        _fundInitial();
        vm.mockCall(address(postOffice), abi.encodeWithSignature("offices(address)", alice), response);
        _assertOfficeFailure();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_postOfficeDecidesOnlyOnTheFirstWordWhateverFollows(
        uint8 extraLengthSeed,
        bytes32 trailing,
        uint256 firstWord
    ) public {
        // The live getter returns the nine-word Office struct; any length of at least one word is read
        // from its first word only, and trailing bytes (even partial words) must not change the decision.
        uint256 extra = uint256(extraLengthSeed) % 300;
        firstWord = bound(firstWord, 0, 4);
        if (firstWord == 3) firstWord = type(uint256).max;
        if (firstWord == 4) firstWord = 1 << 255;
        bytes memory response = new bytes(32 + extra);
        assembly {
            mstore(add(response, 32), firstWord)
        }
        for (uint256 i; i < extra; ++i) {
            response[32 + i] = trailing[i % 32];
        }
        _fundInitial();
        vm.mockCall(address(postOffice), abi.encodeWithSignature("offices(address)", alice), response);
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        bytes memory signature = _signature(rewards, voucher, signerKey);
        if (firstWord == 1) {
            uint256 before = token.balanceOf(alice);
            vm.prank(alice);
            rewards.claim(voucher, signature);
            assertTrue(rewards.usedNonces(1));
            assertEq(token.balanceOf(alice), before + 500 ether);
            assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING - 500 ether);
        } else if (firstWord == 0) {
            vm.expectRevert(MoonRewards.PostOfficeRequired.selector);
            vm.prank(alice);
            rewards.claim(voucher, signature);
            assertFalse(rewards.usedNonces(1));
            assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING);
        } else {
            _assertOfficeFailure();
        }
    }

    function test_postOfficeLiveStructWithOpenButOtherwiseEmptyFieldsIsAccepted() public {
        // Only `open` matters: zero tier, power and an unset referrer do not block the claim.
        _fundInitial();
        bytes memory response = abi.encode(true, uint8(0), uint8(0), uint16(0), uint64(0), address(0), 0, 0, 0);
        assertEq(response.length, 288);
        vm.mockCall(address(postOffice), abi.encodeWithSignature("offices(address)", alice), response);
        _claim(alice, 500 ether, 1);
        assertTrue(rewards.usedNonces(1));
    }

    function test_postOfficeCannotMutateDuringEligibilityCheck() public {
        _fundInitial();
        WritingPostOffice implementation = new WritingPostOffice();
        vm.etch(address(postOffice), address(implementation).code);
        _assertOfficeFailure();
        assertEq(WritingPostOffice(address(postOffice)).writes(), 0);
    }

    function test_failedClaimDoesNotLatchDirectDonationActivation() public {
        assertTrue(token.transfer(address(rewards), INITIAL_FUNDING));
        assertTrue(rewards.isFunded());
        assertFalse(rewards.activated());
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        bytes memory signature = _signature(rewards, voucher, signerKey);
        vm.prank(owner);
        rewards.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(alice);
        rewards.claim(voucher, signature);
        assertFalse(rewards.activated());
        assertFalse(rewards.usedNonces(1));
        assertEq(rewards.totalPaid(), 0);

        vm.prank(owner);
        rewards.unpause();
        vm.prank(alice);
        rewards.claim(voucher, signature);
        assertTrue(rewards.activated());
        assertTrue(rewards.usedNonces(1));
    }

    function _assertOfficeFailure() private {
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        bytes memory signature = _signature(rewards, voucher, signerKey);
        vm.expectRevert(MoonRewards.PostOfficeUnavailable.selector);
        vm.prank(alice);
        rewards.claim{gas: 500_000}(voucher, signature);
        assertFalse(rewards.usedNonces(1));
        assertEq(rewards.totalPaid(), 0);
        assertEq(rewards.walletDailyPaid(alice, voucher.day), 0);
        assertEq(rewards.dailyPaid(voucher.day), 0);
        assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING);
    }
}
