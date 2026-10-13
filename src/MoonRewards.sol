// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPostOffice} from "./interfaces/IPostOffice.sol";

/// @notice Permanent MOON reward pool. The only outgoing transfer is a verified player's mission claim.
/// @dev The explicit immutable owner can only rotate the EOA voucher signer and pause/resume claims.
contract MoonRewards is EIP712, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct MissionVoucher {
        address player;
        uint256 amount;
        uint256 day;
        uint256 nonce;
        uint256 deadline;
    }

    address public constant POST_OFFICE = 0x26D80804D0FA2F4598369E0062bFC9536d115D82;
    uint256 public constant WALLET_DAILY_CAP = 20_000 ether;
    uint256 public constant GLOBAL_DAILY_CAP = 1_000_000 ether;
    uint256 public constant INITIAL_FUNDING = 700_000_000 ether;
    uint256 public constant MIN_MISSION_REWARD = 500 ether;
    uint256 public constant MAX_MISSION_REWARD = 2_000 ether;
    bytes32 public constant VOUCHER_TYPEHASH =
        keccak256("MissionVoucher(address player,uint256 amount,uint256 day,uint256 nonce,uint256 deadline)");

    IERC20 public immutable token;
    address public immutable owner;
    address public voucherSigner;
    bool public activated;
    uint256 public totalFunded;
    uint256 public totalPaid;

    /// @notice Nonces are global, permanent and survive day changes and signer rotation.
    mapping(uint256 nonce => bool used) public usedNonces;
    mapping(uint256 day => uint256 amount) public dailyPaid;
    mapping(address player => mapping(uint256 day => uint256 amount)) public walletDailyPaid;

    error InvalidAddress();
    error Unauthorized();
    error TokenNotDeployed();
    error VoucherSignerNotConfigured();
    error NotFunded();
    error NotVoucherPlayer();
    error InvalidMissionAmount();
    error WrongDay();
    error VoucherExpired();
    error NonceAlreadyUsed();
    error InvalidSignature();
    error PostOfficeUnavailable();
    error PostOfficeRequired();
    error WalletDailyCapExceeded();
    error GlobalDailyCapExceeded();
    error InsufficientRewards();
    error ZeroAmount();
    error InexactFunding();

    event VoucherSignerChanged(address indexed previousSigner, address indexed newSigner);
    event Funded(address indexed funder, uint256 amount, uint256 poolBalance);
    event RewardPoolActivated(uint256 poolBalance);
    event MissionClaimed(address indexed player, uint256 indexed nonce, uint256 indexed day, uint256 amount);

    /// @param token_ The launch's $token; constructors do not call dependencies.
    /// @param owner_ The launch's $owner, never the factory or tx.origin.
    constructor(address token_, address owner_) EIP712("MOON Rewards", "1") {
        if (token_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        token = IERC20(token_);
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /// @notice Configure or rotate the game server's signing address. No signer is guessed at deployment.
    function setVoucherSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert InvalidAddress();
        emit VoucherSignerChanged(voucherSigner, newSigner);
        voucherSigner = newSigner;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Irreversibly deposit MOON. No depositor receives a withdrawal right.
    function fund(uint256 amount) external nonReentrant {
        _fund(msg.sender, amount);
    }

    /// @notice Deposit with an exact-value EIP-2612 approval in a single transaction.
    /// @dev A previously submitted permit is harmless: the existing allowance must still cover the deposit.
    function fundWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        try IERC20Permit(address(token)).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        _fund(msg.sender, amount);
    }

    function currentDay() public view returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @notice The threshold is a one-time activation condition, not a minimum retained balance.
    /// @dev Direct token donations count toward activation but are not included in totalFunded.
    function isFunded() public view returns (bool) {
        return activated || _poolBalance() >= INITIAL_FUNDING;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function hashVoucher(MissionVoucher calldata voucher) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    VOUCHER_TYPEHASH, voucher.player, voucher.amount, voucher.day, voucher.nonce, voucher.deadline
                )
            )
        );
    }

    /// @notice Claim a current UTC-day mission as the named player. Every failure leaves the nonce unused.
    function claim(MissionVoucher calldata voucher, bytes calldata signature) external nonReentrant whenNotPaused {
        address signer = voucherSigner;
        if (signer == address(0)) revert VoucherSignerNotConfigured();
        if (msg.sender != voucher.player) revert NotVoucherPlayer();
        if (voucher.amount < MIN_MISSION_REWARD || voucher.amount > MAX_MISSION_REWARD) revert InvalidMissionAmount();
        if (voucher.day != currentDay()) revert WrongDay();
        if (block.timestamp > voucher.deadline) revert VoucherExpired();
        if (usedNonces[voucher.nonce]) revert NonceAlreadyUsed();

        (address recovered, ECDSA.RecoverError error,) = ECDSA.tryRecover(hashVoucher(voucher), signature);
        if (error != ECDSA.RecoverError.NoError || recovered != signer) revert InvalidSignature();

        _requirePostOffice(voucher.player);
        uint256 playerPaid = walletDailyPaid[voucher.player][voucher.day] + voucher.amount;
        uint256 allPaid = dailyPaid[voucher.day] + voucher.amount;
        if (playerPaid > WALLET_DAILY_CAP) revert WalletDailyCapExceeded();
        if (allPaid > GLOBAL_DAILY_CAP) revert GlobalDailyCapExceeded();

        uint256 balance = _poolBalance();
        _activateIfFunded(balance);
        if (!activated) revert NotFunded();
        if (balance < voucher.amount) revert InsufficientRewards();

        usedNonces[voucher.nonce] = true;
        walletDailyPaid[voucher.player][voucher.day] = playerPaid;
        dailyPaid[voucher.day] = allPaid;
        totalPaid += voucher.amount;
        emit MissionClaimed(voucher.player, voucher.nonce, voucher.day, voucher.amount);
        token.safeTransfer(voucher.player, voucher.amount);
    }

    function _fund(address funder, uint256 amount) private {
        if (amount == 0) revert ZeroAmount();
        uint256 beforeBalance = _poolBalance();
        token.safeTransferFrom(funder, address(this), amount);
        uint256 afterBalance = _poolBalance();
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != amount) revert InexactFunding();
        totalFunded += amount;
        emit Funded(funder, amount, afterBalance);
        _activateIfFunded(afterBalance);
    }

    function _activateIfFunded(uint256 balance) private {
        if (!activated && balance >= INITIAL_FUNDING) {
            activated = true;
            emit RewardPoolActivated(balance);
        }
    }

    function _poolBalance() private view returns (uint256) {
        if (address(token).code.length == 0) revert TokenNotDeployed();
        return token.balanceOf(address(this));
    }

    function _requirePostOffice(address player) private view {
        // Explicitly fail closed on a missing contract, a revert or a malformed/non-boolean response.
        (bool success, bytes memory data) = POST_OFFICE.staticcall(abi.encodeCall(IPostOffice.offices, (player)));
        if (!success || data.length != 32) revert PostOfficeUnavailable();
        uint256 status = abi.decode(data, (uint256));
        if (status > 1) revert PostOfficeUnavailable();
        if (status == 0) revert PostOfficeRequired();
    }
}
