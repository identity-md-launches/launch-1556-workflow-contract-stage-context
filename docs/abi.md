# ABI and integration guide

Raw, compiler-generated JSON ABI arrays live in `docs/abi/LaunchToken.json`, `MoonRewards.json`, `MoonShop.json`, `CourierCompanions.json`, and `IPostOffice.json`. Regenerate with `python3 tools/export_abi.py`; check with `--check`. Use the full MoonShop ABI at its one address for purchases and the ERC-1155 collection. The abstract CourierCompanions ABI is a convenience subset, not a deployment artifact.

## EIP-712 mission vouchers

The exact primary type is:

```text
MissionVoucher(address player,uint256 amount,uint256 day,uint256 nonce,uint256 deadline)
```

Field order and types are fixed. Sign the EIP-712 typed-data digest, not `personal_sign`/`signMessage`. Use canonical 65-byte `r || s || v` ECDSA signatures, low `s`, and `v` of 27 or 28. Compact 64-byte signatures and ERC-1271 server signatures are not accepted. Players may be EOAs or contract wallets if the claim call's immediate sender is the signed player; the server itself uses an EOA signing address.

Load [voucher-types.json](voucher-types.json), then populate `domain.verifyingContract` with the **verified MoonRewards deployment address**. That field is deliberately absent until deployment, and the JSON must not be used to sign before adding it. Use chain ID `4663` for this launch. Never use the token or shop address as the voucher domain. `DOMAIN_SEPARATOR()` and `hashVoucher(voucher)` let an integration cross-check its digest. An independent manual encoder in the tests verifies these helpers. Domain separation follows [EIP-712](https://eips.ethereum.org/EIPS/eip-712).

All integers should use big integers or decimal strings in JavaScript, never floating-point token amounts:

| Field | Meaning |
| --- | --- |
| `player` | Exact wallet that will call `claim` |
| `amount` | 18-decimal MOON wei; inclusive range `500000000000000000000` through `2000000000000000000000` |
| `day` | `floor(latest block.timestamp / 86400)`; UTC epoch-day index, not timestamp or YYYYMMDD |
| `nonce` | Globally unique unsigned 256-bit integer, allocated across players and signer rotations |
| `deadline` | Inclusive Unix seconds expiry |

Call `claim((player, amount, day, nonce, deadline), signature)` from `player`. There is no relayer or alternate recipient parameter and no gas refund. A deadline extending past midnight does not extend the signed day. A rejected voucher can be retried while still valid; failures consume neither nonce nor daily capacity. Rotation immediately changes the one accepted signer. Persistent nonces prevent replay across rotations; rotating back to an old key can revive that key's still-valid, unused vouchers.

## Public read model

Read these at a consistent recent block, without requesting a wallet connection:

| Display | Source |
| --- | --- |
| Pool balance | `LaunchToken.balanceOf(MoonRewards)` |
| Initial funding status | `MoonRewards.isFunded()`; false means **NOT FUNDED** |
| Claims ready | Funding status, nonzero `voucherSigner()`, `paused() == false`, live PostOffice check, caps and enough balance |
| Player has an open office | First returned field (`open`) of `PostOffice.offices(player)` using `docs/abi/IPostOffice.json`; the getter returns the whole nine-field `Office` struct |
| Current day | `MoonRewards.currentDay()` / block timestamp, never block number |
| Paid today / cap | `dailyPaid(currentDay())` / `GLOBAL_DAILY_CAP()` |
| Player paid today / cap | `walletDailyPaid(player, currentDay())` / `WALLET_DAILY_CAP()` |
| Total mission payouts | `MoonRewards.totalPaid()` |
| Total burned by shop | `MoonShop.totalBurned()` |
| Total recycled by shop | `MoonShop.totalRecycled()` |
| Deposits through fund methods | `MoonRewards.totalFunded()` (includes shop recycling, excludes raw ERC-20 donations) |
| All MOON at the burn sink | `LaunchToken.balanceOf(MoonShop.BURN_ADDRESS())` (can also include direct transfers from others) |
| Creator balance | `LaunchToken.balanceOf(0x72215670c2266bc224949a12c514a77d7fd5d566)`; target zero |
| User MOON | `LaunchToken.balanceOf(player)` |
| User companions | `MoonShop.balanceOf` / `balanceOfBatch` for catalog IDs |
| Item availability | `items(id)`: `(price, maxSupply, perWalletLimit, minted, enabled, exists)` |
| User remaining purchases | `perWalletLimit - purchased(player, id)`, clamped to zero; limit zero is unlimited |
| Supply remaining | `maxSupply - minted`, clamped to zero; maxSupply zero is unlimited |
| Item metadata | `uri(id)` |

The reserve threshold proves the pool was funded; it does not prove the identity of every depositor or that the creator retained nothing. Show the creator's **live balance** and verified creator deposit receipt separately. Later transfers to that wallet can change its balance. `activated` remains true after spending down the pool. There is no transaction-hash field in contract storage: derive receipt links from indexed logs and the deployment handoff.

## Events and indexing

- `Funded(funder, amount, poolBalance)` identifies the depositing wallet. When recycling, `funder` is MoonShop. Index creator deposits from the actual owner wallet, not merely the first funder.
- `RewardPoolActivated(poolBalance)` records the first observed threshold crossing through `fund` or a successful `claim`. Direct transfers are visible through MOON `Transfer` logs; a claim that first activates the pool is not itself the creator funding transaction.
- `MissionClaimed(player, nonce, day, amount)` is emitted only for successful claims; player, nonce and day are indexed. Reverted transactions have no retained events.
- `VoucherSignerChanged(previousSigner, newSigner)`, `Paused(account)` and `Unpaused(account)` update service availability.
- `ItemConfigured(id, price, maxSupply, perWalletLimit, enabled, metadataURI)` enumerates catalog IDs and edits. `URI(value, id)` announces metadata changes.
- `ItemPurchased(buyer, id, quantity, totalPrice, burned, recycled)` accounts for the split. `TransferSingle`, `TransferBatch` and `ApprovalForAll` are the standard collection events.

Index from the verified deployment block, handle chain reorganizations, and reconcile logs against live state. Do not label a submitted but failed transaction as funding or payment.

## Purchases and permit

For approval purchases: read the current item, choose a maximum **total** payment, approve MoonShop for that amount on MOON, then call `buy(id, quantity, maxTotalPrice)` from the buyer. Minting always goes to that buyer; a contract buyer must implement ERC-1155 receipt acceptance.

For permit purchases, use MOON's EIP-2612 domain: name `MOON`, version `1`, chain ID `4663`, **token address** as verifying contract. The type is `Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)`. Use buyer as owner, shop as spender, maximum total price as value, and `LaunchToken.nonces(buyer)`. Call `buyWithPermit(id, quantity, maxTotalPrice, deadline, v, r, s)`. Mission nonces and permit nonces are separate. This uses the [OpenZeppelin ERC20Permit implementation](https://docs.openzeppelin.com/contracts/5.x/api/token/erc20#ERC20Permit).

`fundWithPermit` has the same token domain, with MoonRewards as spender and the exact deposit amount as value. Anyone can submit a valid permit directly to MOON; convenience methods tolerate that by falling back to the caller's existing allowance if permit reverts. Consequently an expired/invalid permit does **not** forbid an independently approved purchase/deposit. No method spends another caller's tokens. An exact-price permit leaves no allowance after success; a maximum exceeding current price leaves the difference.

Items support [ERC-1155](https://eips.ethereum.org/EIPS/eip-1155). `royaltyInfo(id, salePrice)` reports the owner and floor-rounded 5% royalty. [ERC-2981](https://eips.ethereum.org/EIPS/eip-2981) reports royalty information; it does not force marketplaces to pay.

## Errors to surface

Reward preconditions have named custom errors: `VoucherSignerNotConfigured`, `NotFunded`, `NotVoucherPlayer`, `InvalidMissionAmount`, `WrongDay`, `VoucherExpired`, `NonceAlreadyUsed`, `InvalidSignature`, `PostOfficeUnavailable`, `PostOfficeRequired`, `WalletDailyCapExceeded`, `GlobalDailyCapExceeded`, `InsufficientRewards`, and inherited `EnforcedPause`. Rejection ordering follows validation order and should not be treated as an exhaustive preflight report.

Shop failures include `UnknownItem`, `ItemDisabled`, `ZeroQuantity`, `MaxPriceExceeded`, `SupplyLimitExceeded`, `WalletLimitExceeded`, `DependencyNotDeployed`, `RewardsTokenMismatch`, and `InexactPayment`. Funding rejects zero amounts and inexact transfers. Token/receiver failures bubble up or use OpenZeppelin errors, all present in the generated ABIs where statically referenced. A rejected receiver or recycling transfer rolls back the entire purchase; do not display minted inventory from a failed receipt.
