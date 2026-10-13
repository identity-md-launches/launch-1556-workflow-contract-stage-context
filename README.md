# MOON — Courier World contracts

MOON is earned by playing Courier World. Deliver letters, earn MOON, spend it on companions. A game currency, not an investment.

This repository delivers the contract implementation stage for Robinhood Chain, chain ID **4663**: source, tests, vendored dependencies, ABI exports, and integration/deployment documentation. The launch's separate manifest contributor writes `launch.json`; independent review and the publishing, attestation, admission, deployment, and frontend services follow. No deployment or funding transaction has been sent by this assignment, so there are no deployment addresses, receipts, or funding transaction hash to report yet.

## Contracts

| Contract | Purpose | Constructor arguments, in order |
| --- | --- | --- |
| `LaunchToken` | MOON ERC-20, 18 decimals, fixed 1 billion supply; EIP-2612 permit | None |
| `MoonRewards` | Irreversible deposits and signed mission claims | `address token_`, `address owner_` |
| `MoonShop` | MOON shop **and** Courier Companions ERC-1155 collection | `address token_`, `address rewards_`, `address owner_` |

`CourierCompanions` is an abstract base of `MoonShop`, not a fourth deployment. Purchases and ERC-1155 transfers use the **same MoonShop address**. This avoids a configurable minter or a circular dependency. Deploy in the table's order. Constructors are nonpayable and never call dependencies or require their code to exist. See [deployment parameters](docs/deployment.md).

The token mints `1000000000000000000000000000` minor units once, entirely to its deployer (the factory). It has no owner, subsequent mint, pause, blocklist, transfer tax, burn function, or upgrade. Permit only authorizes spending. No application constructor moves or reserves any launch supply. The factory handles the approved **10% swarm / 20% pool / 70% creator** split. LP custody and trading-fee distribution stay with the protocol; the pool fee is **1.25%**.

## Rewards and funding

Anyone may approve and call `fund(amount)` to deposit permanently. `fundWithPermit(amount, deadline, v, r, s)` supplies an exact EIP-2612 approval and deposit in one transaction. There are no shares, refunds, withdrawals, recovery, arbitrary execution, approvals from the pool, or upgrades. The only outgoing token call pays `voucher.player` in `claim` after verification.

Claims remain disabled until the pool has held at least **700,000,000 MOON**. This is a **one-time activation threshold**, not a permanently retained reserve: after activation, payouts may reduce the balance below it. Before activation, direct MOON transfers also count toward the actual balance; `isFunded()` detects them, and the first successful `fund` or `claim` at/above the threshold latches `activated`. Never render a depleted but previously activated pool as "NOT FUNDED"; show its actual balance and insufficient-balance state separately.

Each claim requires all of the following:

- Caller equals the named player and `PostOffice.offices(player)` returns canonical `true` from `0x26D80804D0FA2F4598369E0062bFC9536d115D82`. Missing, malformed, and reverting responses fail closed.
- An EOA signature from the currently configured game server over the exact [EIP-712 voucher](docs/abi.md). The domain is `MOON Rewards`, version `1`, current chain ID and rewards address. Amounts are token wei.
- A reward between **500 and 2,000 MOON**, inclusive; UTC day `floor(block.timestamp / 86400)` equals the voucher day; `block.timestamp <= deadline`.
- An unused **global** `uint256` nonce. The server must allocate unique nonces across all players, days and signer rotations. Nonces need not be sequential.
- Per-wallet daily total no greater than **20,000 MOON** and global daily total no greater than **1,000,000 MOON**, sufficient pool balance, and claims unpaused.

Every failed claim reverts the nonce, counters and transfers together. An over-cap voucher remains unused, but an old-day voucher cannot be claimed tomorrow: the server must issue a new current-day voucher if appropriate. Caps, mission bounds, voucher fields, funding threshold, and PostOffice address have no setters. There are no native payments or gas refunds.

The immutable owner can **only** set/rotate the voucher signer and pause/unpause claims. Deposits and shop recycling continue during a pause. Old signatures fail after a rotation; never rotate back to a compromised key because its still-unexpired unused vouchers would become valid again.

## Shop and companions

The owner uses `configureItem(id, price, maxSupply, perWalletLimit, enabled, metadataURI)` to add or edit an item. Price must be positive and metadata URI nonempty. Both limits use **0 = unlimited**. Supply counts all items ever minted and cannot be set below that count. The wallet limit counts lifetime purchases by the buyer, not their present balance; transferring an item away never restores a purchase allowance. Lowering a wallet limit below existing purchases blocks future purchases without confiscation. Limits and metadata remain owner-editable.

`buy(id, quantity, maxTotalPrice)` charges the current price times quantity, bounded by the buyer's **maximum total order price**. `buyWithPermit` uses an EIP-2612 approval for that same maximum. A lower current price leaves the difference as unspent allowance, which the buyer can revoke. The non-permit route supports contract wallets. A previously submitted permit cannot block a purchase: if permit fails, the transaction can proceed only with sufficient existing allowance from the caller. A permit is an allowance authorization, not an item-order signature.

For total order price `cost`, `floor(cost / 2)` goes to the specified sink `0x000000000000000000000000000000000000dEaD`, and `cost - floor(cost / 2)` goes through `MoonRewards.fund()`. An odd wei goes to rewards. The shop retains no purchase revenue or dust, and the creator receives none. The sink transfer does not reduce ERC-20 `totalSupply`. Payment, recycling, accounting, and minting are atomic, including when an ERC-1155 receiver rejects or attempts reentrancy.

Items support standard single/batch safe transfers and operator approvals. Item sale disabling and rewards pausing do not freeze ERC-1155 transfers. ERC-2981 reports a fixed **5%** secondary-sale royalty to the immutable creator (the owner constructor argument). Marketplaces decide whether to honor that royalty; transfers do not collect it automatically. There is no privileged free mint or royalty setter. Direct accidental token transfers to the shop or unrelated tokens sent to rewards are not recoverable.

## After launch

1. The owner at `0x72215670c2266bc224949a12c514a77d7fd5d566` calls **`MoonRewards.setVoucherSigner(gameServerSigningAddress)`**. Obtain the public EOA signing address from the Courier World backend operator. This is the sole missing external setting; there is no guessed signer or constructor placeholder. Until set, claims revert `VoucherSignerNotConfigured`.
2. The creator deposits their **entire current MOON balance**, expected to be the 700 million allocation. For an EOA, sign an exact-value MOON permit for MoonRewards and call `fundWithPermit` once; otherwise approve and call `fund`. Confirm the successful receipt, `Funded` and `RewardPoolActivated` events, and the creator's remaining MOON balance (target zero). Publish the actual funding transaction hash/link. Deposits are irreversible. This creator action is an operational responsibility, not performed or guaranteed by the factory or contributor.
3. The owner configures the real item catalog and durable metadata URIs with `MoonShop.configureItem`. The contract starts with an empty catalog; no prices, item IDs or metadata content are invented for production.
4. The backend verifies missions and walking in Courier World, secures its signer, allocates global nonces, issues current-day vouchers, and avoids issuing more claimable rewards than available caps/balance. The owner operates signer rotation and pause/resume when needed.
5. The frontend service uses the verified deployment handoff and [ABI/metrics guide](docs/abi.md). It supplies live balances, funding provenance, "NOT FUNDED" gating, the exact pool key, and browser-tested mobile/wallet flows. Publication, IPFS hosting, share image, receipts and frontend tests are later-stage deliverables.

## Build and check

```sh
forge build
forge test
forge fmt --check
python3 tools/export_abi.py --check
```

Solidity **0.8.26** is pinned with optimizer 200 runs, Paris EVM, and `bytecode_hash = "none"`. Paris avoids requiring newer chain opcodes. FFI and filesystem permissions are disabled. Dependencies are ordinary files inside `lib/`: OpenZeppelin Contracts **v5.4.0** (only required source files) and forge-std **v1.9.7**, with upstream licenses and archive hashes. No download, submodule, environment variable or RPC is required by the tests. The verifier supplies the pinned compiler; no binary is committed.

Tests cover cap boundaries, signature forgery/replay/domain separation, signer configuration/rotation, PostOffice failures, permanent funding, activation, pausing, insolvency, failed transfers, malicious callbacks, permit routes, item edits/limits, exact splits, ERC-1155 transfers and royalties. Stateful fuzzing checks independent accounting across funding, claims, purchases, transfers, time changes, pausing and signer rotation. A deterministic 40-day sequence exercises both successes and failures. See [validation and security notes](docs/validation.md).

The contracts trust the game server to truthfully certify gameplay. An owner who selects a malicious signer can authorize false missions within the same immutable caps and PostOffice rule; onchain signatures cannot prove the courier walked. PostOffice availability and its external administration can stop claims. Owner-key loss, signer loss or depletion can leave deposits locked because recovery is deliberately absent. Tests are not an independent security audit; the separate source/manifest review remains required before release.
