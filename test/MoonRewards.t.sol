// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MoonTestBase} from "./helpers/MoonTestBase.sol";
import {MoonRewards} from "../src/MoonRewards.sol";
import {AdversarialToken} from "./helpers/Mocks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract MoonRewardsTest is MoonTestBase {
    function test_constructorUsesExplicitOwnerAndMakesNoDependencyCall() public {
        address absentToken = makeAddr("absent token");
        MoonRewards fresh = new MoonRewards(absentToken, owner);
        assertEq(fresh.owner(), owner);
        assertEq(address(fresh.token()), absentToken);
        assertEq(fresh.voucherSigner(), address(0));
        vm.expectRevert(MoonRewards.TokenNotDeployed.selector);
        fresh.fund(1);
        vm.expectRevert(MoonRewards.InvalidAddress.selector);
        new MoonRewards(address(0), owner);
        vm.expectRevert(MoonRewards.InvalidAddress.selector);
        new MoonRewards(address(token), address(0));
    }

    function test_signerStartsUnconfiguredAndOnlyOwnerCanSetIt() public {
        MoonRewards fresh = new MoonRewards(address(token), owner);
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        bytes memory signature = _signature(fresh, voucher, signerKey);
        vm.expectRevert(MoonRewards.VoucherSignerNotConfigured.selector);
        vm.prank(alice);
        fresh.claim(voucher, signature);
        vm.expectRevert(MoonRewards.Unauthorized.selector);
        fresh.setVoucherSigner(signer);
        vm.expectRevert(MoonRewards.InvalidAddress.selector);
        vm.prank(owner);
        fresh.setVoucherSigner(address(0));
        vm.prank(owner);
        fresh.setVoucherSigner(signer);
        token.approve(address(fresh), INITIAL_FUNDING);
        fresh.fund(INITIAL_FUNDING);
        vm.prank(alice);
        fresh.claim(voucher, signature);
        assertTrue(fresh.usedNonces(1));
    }

    function test_claimCannotSucceedBeforeThresholdAndVoucherRemainsUnused() public {
        token.approve(address(rewards), INITIAL_FUNDING);
        rewards.fund(INITIAL_FUNDING - 1);
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        _expectFailure(MoonRewards.NotFunded.selector, voucher, signerKey, alice);
        assertFalse(rewards.isFunded());
        rewards.fund(1);
        assertTrue(rewards.isFunded());
        _claim(alice, 500 ether, 1);
        assertTrue(rewards.activated());
        assertTrue(rewards.isFunded());
        assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING - 500 ether);
        _claim(alice, 500 ether, 2);
    }

    function test_directDonationCountsAndFirstSuccessfulClaimLatchesActivation() public {
        token.transfer(address(rewards), INITIAL_FUNDING);
        assertFalse(rewards.activated());
        assertTrue(rewards.isFunded());
        _claim(alice, 500 ether, 1);
        assertTrue(rewards.activated());
        assertTrue(rewards.isFunded());
        assertEq(rewards.totalFunded(), 0);
        assertEq(rewards.totalPaid(), 500 ether);
    }

    function test_fundIsPermissionlessPermanentAndWorksWhilePaused() public {
        vm.prank(owner);
        rewards.pause();
        vm.startPrank(alice);
        token.approve(address(rewards), 500 ether);
        rewards.fund(500 ether);
        vm.stopPrank();
        assertEq(rewards.totalFunded(), 500 ether);
        assertEq(token.balanceOf(address(rewards)), 500 ether);
        assertEq(token.allowance(alice, address(rewards)), 0);
        vm.expectRevert(MoonRewards.ZeroAmount.selector);
        rewards.fund(0);
    }

    function test_fundWithPermitDepositsWholeCreatorBalanceInOneTransaction() public {
        token.transfer(alice, INITIAL_FUNDING);
        uint256 balance = token.balanceOf(alice);
        uint256 deadline = vm.getBlockTimestamp();
        (uint8 v, bytes32 r, bytes32 s) = _permit(alice, address(rewards), balance, deadline, aliceKey);
        vm.prank(alice);
        rewards.fundWithPermit(balance, deadline, v, r, s);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(rewards)), balance);
        assertEq(token.allowance(alice, address(rewards)), 0);
        assertEq(rewards.totalFunded(), balance);
        assertTrue(rewards.activated());
    }

    function test_frontRunFundingPermitCannotBlockDepositOrStealTokens() public {
        uint256 amount = 500 ether;
        uint256 deadline = vm.getBlockTimestamp() + 100;
        (uint8 v, bytes32 r, bytes32 s) = _permit(alice, address(rewards), amount, deadline, aliceKey);
        vm.prank(bob);
        token.permit(alice, address(rewards), amount, deadline, v, r, s);
        vm.prank(alice);
        rewards.fundWithPermit(amount, deadline, v, r, s);
        assertEq(token.balanceOf(address(rewards)), amount);
        assertEq(token.nonces(alice), 1);
        vm.expectRevert();
        vm.prank(bob);
        rewards.fundWithPermit(amount, deadline, v, r, s);
    }

    function test_invalidFundingPermitWithoutAllowanceFails() public {
        vm.expectRevert();
        vm.prank(alice);
        rewards.fundWithPermit(500 ether, vm.getBlockTimestamp(), 27, bytes32(0), bytes32(0));
        assertEq(token.balanceOf(address(rewards)), 0);
        assertEq(rewards.totalFunded(), 0);
    }

    function test_claimPaysOnlyPlayerAndTracksAllCounters() public {
        _fundInitial();
        uint256 playerBefore = token.balanceOf(alice);
        uint256 ownerBefore = token.balanceOf(owner);
        _claim(alice, 1_250 ether, 91);
        assertEq(token.balanceOf(alice), playerBefore + 1_250 ether);
        assertEq(token.balanceOf(owner), ownerBefore);
        assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING - 1_250 ether);
        assertEq(rewards.totalPaid(), 1_250 ether);
        assertEq(rewards.dailyPaid(rewards.currentDay()), 1_250 ether);
        assertEq(rewards.walletDailyPaid(alice, rewards.currentDay()), 1_250 ether);
        assertTrue(rewards.usedNonces(91));
    }

    function test_eachNoncePaysOnceAcrossPlayersDaysAndSignerRotation() public {
        _fundInitial();
        _claim(alice, 500 ether, 1);
        MoonRewards.MissionVoucher memory voucher = _voucher(bob, 500 ether, 1);
        bytes memory signature = _signature(rewards, voucher, signerKey);
        vm.expectRevert(MoonRewards.NonceAlreadyUsed.selector);
        vm.prank(bob);
        rewards.claim(voucher, signature);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(owner);
        rewards.setVoucherSigner(bob);
        voucher = _voucher(alice, 500 ether, 1);
        signature = _signature(rewards, voucher, bobKey);
        vm.expectRevert(MoonRewards.NonceAlreadyUsed.selector);
        vm.prank(alice);
        rewards.claim(voucher, signature);
        assertEq(rewards.totalPaid(), 500 ether);
    }

    function test_expiredFutureDayOldDayAndWrongPlayerFail() public {
        _fundInitial();
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        _expectFailure(MoonRewards.NotVoucherPlayer.selector, voucher, signerKey, bob);
        voucher.deadline = vm.getBlockTimestamp() - 1;
        _expectFailure(MoonRewards.VoucherExpired.selector, voucher, signerKey, alice);
        voucher.deadline = vm.getBlockTimestamp() + 1 days;
        voucher.day += 1;
        _expectFailure(MoonRewards.WrongDay.selector, voucher, signerKey, alice);
        voucher.day -= 2;
        _expectFailure(MoonRewards.WrongDay.selector, voucher, signerKey, alice);
    }

    function test_exactDeadlineIsAccepted() public {
        _fundInitial();
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        voucher.deadline = vm.getBlockTimestamp();
        bytes memory signature = _signature(rewards, voucher, signerKey);
        vm.prank(alice);
        rewards.claim(voucher, signature);
        assertTrue(rewards.usedNonces(1));
    }

    function test_missionAmountBounds() public {
        _fundInitial();
        _expectFailure(MoonRewards.InvalidMissionAmount.selector, _voucher(alice, 0, 1), signerKey, alice);
        _expectFailure(MoonRewards.InvalidMissionAmount.selector, _voucher(alice, 500 ether - 1, 1), signerKey, alice);
        _expectFailure(MoonRewards.InvalidMissionAmount.selector, _voucher(alice, 2_000 ether + 1, 1), signerKey, alice);
        _claim(alice, 500 ether, 1);
        _claim(alice, 2_000 ether, 2);
    }

    function test_forgedSignatureAndEveryMutatedFieldFail() public {
        _fundInitial();
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        _expectFailure(MoonRewards.InvalidSignature.selector, voucher, bobKey, alice);
        bytes memory signature = _signature(rewards, voucher, signerKey);
        voucher.amount += 1;
        _expectBadSignature(voucher, signature, alice);
        voucher.amount -= 1;
        voucher.nonce += 1;
        _expectBadSignature(voucher, signature, alice);
        voucher.nonce -= 1;
        voucher.deadline += 1;
        _expectBadSignature(voucher, signature, alice);
        voucher.deadline -= 1;
        voucher.player = bob;
        _expectBadSignature(voucher, signature, bob);
        voucher.player = alice;
        voucher.day += 1;
        vm.warp(vm.getBlockTimestamp() + 1 days);
        voucher.deadline = vm.getBlockTimestamp() + 1 hours;
        _expectBadSignature(voucher, signature, alice);
    }

    function test_signaturesBindChainContractDomainAndRejectMalleability() public {
        _fundInitial();
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        assertEq(rewards.hashVoucher(voucher), _digest(rewards, voucher));
        bytes memory signature = _signature(rewards, voucher, signerKey);
        vm.chainId(1);
        _expectBadSignature(voucher, signature, alice);
        vm.chainId(4663);
        MoonRewards other = new MoonRewards(address(token), owner);
        _expectBadSignature(voucher, _signature(other, voucher, signerKey), alice);
        _expectBadSignature(voucher, hex"1234", alice);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, _digest(rewards, voucher));
        bytes32 highS = bytes32(0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141 - uint256(s));
        _expectBadSignature(voucher, abi.encodePacked(r, highS, uint8(v == 27 ? 28 : 27)), alice);
        _expectBadSignature(voucher, abi.encodePacked(r, s, uint8(0)), alice);
        bytes32 wrongDomain =
            keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256("MOON"), keccak256("1"), TEST_CHAIN_ID, address(rewards)));
        bytes32 message = keccak256(
            abi.encode(VOUCHER_TYPEHASH, alice, voucher.amount, voucher.day, voucher.nonce, voucher.deadline)
        );
        (v, r, s) = vm.sign(signerKey, keccak256(abi.encodePacked("\x19\x01", wrongDomain, message)));
        _expectBadSignature(voucher, abi.encodePacked(r, s, v), alice);
    }

    function test_postOfficeMustBeOpenAtClaimTime() public {
        _fundInitial();
        postOffice.setOffice(alice, false);
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        _expectFailure(MoonRewards.PostOfficeRequired.selector, voucher, signerKey, alice);
        postOffice.setOffice(alice, true);
        _claim(alice, 500 ether, 1);
        postOffice.setOffice(alice, false);
        _expectFailure(MoonRewards.PostOfficeRequired.selector, _voucher(alice, 500 ether, 2), signerKey, alice);
    }

    function test_postOfficeMissingRevertingOrMalformedFailsClosed() public {
        _fundInitial();
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        vm.etch(address(postOffice), "");
        _expectFailure(MoonRewards.PostOfficeUnavailable.selector, voucher, signerKey, alice);
        vm.mockCallRevert(address(postOffice), abi.encodeWithSignature("offices(address)", alice), hex"1234");
        _expectFailure(MoonRewards.PostOfficeUnavailable.selector, voucher, signerKey, alice);
        vm.clearMockedCalls();
        vm.mockCall(address(postOffice), abi.encodeWithSignature("offices(address)", alice), abi.encode(uint256(2)));
        _expectFailure(MoonRewards.PostOfficeUnavailable.selector, voucher, signerKey, alice);
        vm.clearMockedCalls();
        vm.mockCall(address(postOffice), abi.encodeWithSignature("offices(address)", alice), hex"01");
        _expectFailure(MoonRewards.PostOfficeUnavailable.selector, voucher, signerKey, alice);
    }

    function test_walletCapAtBoundaryRejectsOneWeiOverWithoutConsumingNonce() public {
        _fundInitial();
        for (uint256 i; i < 9; ++i) {
            _claim(alice, 2_000 ether, i);
        }
        _claim(alice, 1_500 ether + 1, 9);
        _expectFailure(MoonRewards.WalletDailyCapExceeded.selector, _voucher(alice, 500 ether, 10), signerKey, alice);
        assertEq(rewards.walletDailyPaid(alice, rewards.currentDay()), 19_500 ether + 1);
        _claim(bob, 500 ether, 10);
        assertTrue(rewards.usedNonces(10));
    }

    function test_utcMidnightResetsCapsAndInvalidatesPreviousDayVouchers() public {
        _fundInitial();
        uint256 day = rewards.currentDay();
        vm.warp((day + 1) * 1 days - 1);
        for (uint256 i; i < 10; ++i) {
            _claim(alice, 2_000 ether, i);
        }
        MoonRewards.MissionVoucher memory oldVoucher = _voucher(alice, 500 ether, 10);
        _expectFailure(MoonRewards.WalletDailyCapExceeded.selector, oldVoucher, signerKey, alice);
        vm.warp((day + 1) * 1 days);
        _expectFailure(MoonRewards.WrongDay.selector, oldVoucher, signerKey, alice);
        _claim(alice, 500 ether, 10);
        assertEq(rewards.walletDailyPaid(alice, day), 20_000 ether);
        assertEq(rewards.walletDailyPaid(alice, day + 1), 500 ether);
        assertEq(rewards.dailyPaid(day), 20_000 ether);
        assertEq(rewards.dailyPaid(day + 1), 500 ether);
    }

    function test_globalCapIndependentOfWalletCapsAndResetsAtMidnight() public {
        _fundInitial();
        uint256 day = rewards.currentDay();
        for (uint256 i; i < 50; ++i) {
            address player = address(uint160(10_000 + i));
            postOffice.setOffice(player, true);
            for (uint256 j; j < 10; ++j) {
                _claim(player, 2_000 ether, i * 10 + j);
            }
        }
        assertEq(rewards.dailyPaid(day), 1_000_000 ether);
        _expectFailure(MoonRewards.GlobalDailyCapExceeded.selector, _voucher(alice, 500 ether, 500), signerKey, alice);
        vm.warp((day + 1) * 1 days);
        _claim(alice, 500 ether, 500);
        assertEq(rewards.dailyPaid(day + 1), 500 ether);
    }

    function test_ownerRotationInvalidatesOldSignaturesAndDoesNotMoveFunds() public {
        _fundInitial();
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        bytes memory oldSignature = _signature(rewards, voucher, signerKey);
        vm.expectRevert(MoonRewards.Unauthorized.selector);
        vm.prank(alice);
        rewards.setVoucherSigner(bob);
        vm.prank(owner);
        rewards.setVoucherSigner(bob);
        _expectBadSignature(voucher, oldSignature, alice);
        assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING);
        bytes memory newSignature = _signature(rewards, voucher, bobKey);
        vm.prank(alice);
        rewards.claim(voucher, newSignature);
        assertTrue(rewards.usedNonces(1));
    }

    function test_pauseAndResumeOnlyAffectClaims() public {
        _fundInitial();
        vm.expectRevert(MoonRewards.Unauthorized.selector);
        rewards.pause();
        vm.prank(owner);
        rewards.pause();
        _expectFailure(bytes4(keccak256("EnforcedPause()")), _voucher(alice, 500 ether, 1), signerKey, alice);
        assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING);
        vm.expectRevert(MoonRewards.Unauthorized.selector);
        vm.prank(alice);
        rewards.unpause();
        vm.prank(owner);
        rewards.unpause();
        _claim(alice, 500 ether, 1);
    }

    function test_insufficientBalanceAfterActivationCannotConsumeVoucher() public {
        _fundInitial();
        // Model the end of the reward pool's lifetime without executing 350,000 mission transactions.
        deal(address(token), address(rewards), 500 ether - 1);
        _expectFailure(MoonRewards.InsufficientRewards.selector, _voucher(alice, 500 ether, 1), signerKey, alice);
        token.approve(address(rewards), 1);
        rewards.fund(1);
        _claim(alice, 500 ether, 1);
        assertEq(token.balanceOf(address(rewards)), 0);
        assertTrue(rewards.isFunded());
    }

    function test_noWithdrawalRecoveryApprovalUpgradeOrConstantSetters() public {
        _fundInitial();
        bytes[11] memory calls = [
            abi.encodeWithSignature("withdraw(uint256)", 1),
            abi.encodeWithSignature("withdraw(address,uint256)", owner, 1),
            abi.encodeWithSignature("recoverERC20(address,uint256)", address(token), 1),
            abi.encodeWithSignature("rescueTokens(address,address,uint256)", address(token), owner, 1),
            abi.encodeWithSignature("transfer(address,uint256)", owner, 1),
            abi.encodeWithSignature("approve(address,uint256)", owner, 1),
            abi.encodeWithSignature("upgradeTo(address)", owner),
            abi.encodeWithSignature("transferOwnership(address)", alice),
            abi.encodeWithSignature("setPostOffice(address)", owner),
            abi.encodeWithSignature("setDailyCaps(uint256,uint256)", 1, 1),
            abi.encodeWithSignature("setInitialFunding(uint256)", 1)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(owner);
            (bool ok,) = address(rewards).call(calls[i]);
            assertFalse(ok);
            vm.prank(alice);
            (ok,) = address(rewards).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(token.balanceOf(address(rewards)), INITIAL_FUNDING);
        assertEq(token.allowance(address(rewards), owner), 0);
        assertEq(token.allowance(address(rewards), address(shop)), 0);
        assertEq(rewards.INITIAL_FUNDING(), INITIAL_FUNDING);
        assertEq(rewards.WALLET_DAILY_CAP(), 20_000 ether);
        assertEq(rewards.GLOBAL_DAILY_CAP(), 1_000_000 ether);
        assertEq(rewards.POST_OFFICE(), 0x26D80804D0FA2F4598369E0062bFC9536d115D82);
        assertEq(rewards.VOUCHER_TYPEHASH(), VOUCHER_TYPEHASH);
    }

    function test_failedFundingAndFeeOnTransferDoNotCreditPool() public {
        AdversarialToken bad = new AdversarialToken();
        MoonRewards target = new MoonRewards(address(bad), owner);
        bad.approve(address(target), INITIAL_FUNDING);
        bad.setFailure(true, address(0), false);
        vm.expectRevert();
        target.fund(INITIAL_FUNDING);
        assertEq(target.totalFunded(), 0);
        assertFalse(target.activated());
        bad.setFailure(false, address(0), true);
        vm.expectRevert(MoonRewards.InexactFunding.selector);
        target.fund(INITIAL_FUNDING);
        assertEq(bad.balanceOf(address(target)), 0);
        assertEq(target.totalFunded(), 0);
    }

    function test_failedPayoutRollsBackNonceAndCounters() public {
        (AdversarialToken bad, MoonRewards target) = _adversarialPool();
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        bytes memory signature = _signature(target, voucher, signerKey);
        bad.setFailure(true, address(0), false);
        vm.expectRevert();
        vm.prank(alice);
        target.claim(voucher, signature);
        assertFalse(target.usedNonces(1));
        assertEq(target.totalPaid(), 0);
        assertEq(target.dailyPaid(target.currentDay()), 0);
        assertEq(target.walletDailyPaid(alice, target.currentDay()), 0);
        assertEq(bad.balanceOf(address(target)), INITIAL_FUNDING);
        bad.setFailure(false, address(0), false);
        vm.prank(alice);
        target.claim(voucher, signature);
        assertTrue(target.usedNonces(1));
    }

    function test_reentrancyDuringFundingAndPayoutIsRejected() public {
        (AdversarialToken bad, MoonRewards target) = _adversarialPool();
        bad.approve(address(target), 1);
        bad.setCallback(address(target), abi.encodeCall(target.fund, (1)));
        target.fund(1);
        assertFalse(bad.callbackSucceeded());
        assertEq(bytes4(bad.callbackResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        MoonRewards.MissionVoucher memory voucher = _voucher(alice, 500 ether, 1);
        bytes memory signature = _signature(target, voucher, signerKey);
        bad.setCallback(address(target), abi.encodeCall(target.claim, (voucher, signature)));
        vm.prank(alice);
        target.claim(voucher, signature);
        assertFalse(bad.callbackSucceeded());
        assertEq(bytes4(bad.callbackResult()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(target.totalPaid(), 500 ether);
        assertEq(bad.balanceOf(alice), 500 ether);
        assertEq(bad.balanceOf(address(target)), INITIAL_FUNDING + 1 - 500 ether);
    }

    function testFuzz_missionPayoutConservesFunds(uint256 amount, uint256 nonce) public {
        _fundInitial();
        amount = bound(amount, 500 ether, 2_000 ether);
        uint256 beforeBalance = token.balanceOf(alice);
        _claim(alice, amount, nonce);
        assertEq(token.balanceOf(alice), beforeBalance + amount);
        assertEq(token.balanceOf(address(rewards)) + rewards.totalPaid(), INITIAL_FUNDING);
        assertEq(rewards.totalPaid(), amount);
    }

    function _adversarialPool() internal returns (AdversarialToken bad, MoonRewards target) {
        bad = new AdversarialToken();
        target = new MoonRewards(address(bad), owner);
        vm.prank(owner);
        target.setVoucherSigner(signer);
        bad.approve(address(target), INITIAL_FUNDING);
        target.fund(INITIAL_FUNDING);
    }

    function _expectBadSignature(MoonRewards.MissionVoucher memory voucher, bytes memory signature, address caller)
        internal
    {
        vm.expectRevert(MoonRewards.InvalidSignature.selector);
        vm.prank(caller);
        rewards.claim(voucher, signature);
        assertFalse(rewards.usedNonces(voucher.nonce));
    }

    function _expectFailure(bytes4 error, MoonRewards.MissionVoucher memory voucher, uint256 key, address caller)
        internal
    {
        bytes memory signature = _signature(rewards, voucher, key);
        uint256 totalBefore = rewards.totalPaid();
        uint256 dayBefore = rewards.dailyPaid(voucher.day);
        uint256 walletBefore = rewards.walletDailyPaid(voucher.player, voucher.day);
        uint256 balanceBefore = token.balanceOf(address(rewards));
        vm.expectRevert(error);
        vm.prank(caller);
        rewards.claim(voucher, signature);
        assertFalse(rewards.usedNonces(voucher.nonce));
        assertEq(rewards.totalPaid(), totalBefore);
        assertEq(rewards.dailyPaid(voucher.day), dayBefore);
        assertEq(rewards.walletDailyPaid(voucher.player, voucher.day), walletBefore);
        assertEq(token.balanceOf(address(rewards)), balanceBefore);
    }
}
