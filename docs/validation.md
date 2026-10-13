# Local validation and security notes

These are the implementing contributor's checks, not an independent audit or admission decision. The required independent source/manifest review is a separate assignment.

## Recorded results

Validated locally on 2026-10-13 with Foundry 1.8.3 and the pinned Solidity 0.8.26 configuration:

| Check | Result |
| --- | --- |
| `forge build` | Passed from clean artifacts, no compiler errors |
| `forge test` | 70 tests passed, no failures or skips |
| Tests offline, empty process environment, four threads | Passed, 70 tests |
| Stateful invariant campaign | Four properties; 128 runs × 96 calls = 12,288 calls; no handler reverts |
| `forge fmt --check` | Passed |
| `python3 tools/export_abi.py --check` | All five ABI exports match compiler output |
| Supplied protected project/token checks | All nine passed, no skips |

Foundry groups the four invariant properties into one reported test; the suite also contains 69 ordinary/fuzz tests. Fuzz tests run 256 examples each. The invariant model exercises expected application reverts using low-level calls and verifies their state rollback; `fail_on_revert = true` means an unexpected revert in the **handler** fails the campaign rather than being discarded.

The supplied protected tests were copied unmodified into temporary `test/scratch/` and run against actual compiled creation bytecode with constructor arguments and CREATE2 predictions generated for an isolated local factory fixture. Their required environment inputs were confined to that subprocess. Those temporary test copies were removed; delivered tests require neither environment input nor the pinned `.imd/reads/` files. Local floor checks do not substitute for the verifier's run against the eventual signed manifest.

| Deployable | Runtime bytes | EIP-170 maximum |
| --- | --- | --- |
| LaunchToken | 3,799 | 24,576 |
| MoonRewards | 6,420 | 24,576 |
| MoonShop | 9,038 | 24,576 |

All deployable creation bytecodes have empty library link references. Constructors leave the policy supply entirely at the deploying factory. Opcode scans skip PUSH immediates and reject `DELEGATECALL`, `CALLCODE`, and `SELFDESTRUCT` in actual deployed runtime. Dynamic test linking is disabled to exercise real creation code. No contract calls dependencies during construction.

## Requirement coverage

| Behavior | Evidence |
| --- | --- |
| Fixed token supply, exact transfers, no privileged mint | `test/LaunchToken.t.sol`, protected token tests |
| Approvals and permit nonces, deadlines, signer and chain binding | Token tests; permit purchase and deposit tests |
| Initial signer missing/set, owner authorization | `test_signerStartsUnconfiguredAndOnlyOwnerCanSetIt` |
| Funding gate and continued payouts below threshold | `test_claimCannotSucceedBeforeThresholdAndVoucherRemainsUnused`, direct-donation activation test |
| Whole-wallet, one-transaction permit funding | `test_fundWithPermitDepositsWholeCreatorBalanceInOneTransaction` |
| Permanent deposits; no owner transfer/recovery/upgrade/constants setters | `test_noWithdrawalRecoveryApprovalUpgradeOrConstantSetters`, source review of the only payout site |
| Named-player claims; every signed field; expiration and bounds | Reward claim, mutation, signature-domain and amount-bound tests |
| Nonce replay across players, days, signer rotation | `test_eachNoncePaysOnceAcrossPlayersDaysAndSignerRotation` |
| PostOffice open/closed/missing/reverting/malformed | Both PostOffice test groups |
| Wallet cap, one-wei boundary, UTC midnight | Wallet cap and UTC boundary tests |
| Global cap | 50 players × 10 missions × 2,000 MOON, followed by rejection and next-day success |
| Rotation and pause cannot move pool funds | Rotation and pause/resume tests; independent invariant model |
| Insolvency, failed funding and payout transfers | Adversarial token tests; exhaustion test checks retry without nonce loss |
| Shop permits, front-run permits, exact/max pricing | `test/MoonShop.t.sol` permit and quote tests |
| Supply, lifetime wallet limits, edits and transfers | Supply/wallet/limit/metadata tests, ERC-1155 operator and batch tests |
| 50/50 split, odd wei, no retained funds, no owner revenue | Split fuzzing, one-wei purchase, independent accounting invariants |
| Failed pull, sink transfer, recycle, and receiver rejection | Atomic purchase rollback tests |
| Reentrancy during funding, payout, payment and NFT acceptance | Adversarial token and receiver callback tests |
| ERC-1155/165/2981 interfaces and immutable 5% royalty | Interface tests and royalty fuzzing |
| Solvency across mixed sequences over many days | Stateful independent model and deterministic 40-day scenario |

The stateful model uses the real LaunchToken, with no minting or balance mutation during sequences. It compares each operation against independently tracked nonces, caps, purchases and cash flows. It checks:

```text
rewards.balance + successfulClaims
    = initialFunding + voluntaryFunding + shopRecycling

shopBurned + shopRecycled = successfulPurchasePayments

all tracked MOON balances = fixed launch supply

all player companion balances = items minted
```

The exhaustion unit test changes the test balance after legitimate activation to represent the end of the pool's lifetime, then verifies failure at one wei below a valid reward and success after topping up. It does not claim to execute hundreds of thousands of historical mission payouts. The separate sequence tests conserve the real fixed supply throughout.

Time-changing tests use `vm.getBlockTimestamp()` instead of relying on the compiler to reload `block.timestamp` after `vm.warp`. Independent signing helpers use the fixture's explicit chain ID; replay tests change the actual EVM chain to verify rejection. No delivered test reads or sets environment variables, forks a network, invokes FFI, or accesses files through cheatcodes.

## Security review of the implementation

- **Pool custody:** `MoonRewards.claim` contains the only outgoing MOON transfer, always to the verified voucher player. There is no allowance granted from the pool, arbitrary call, withdrawal, rescue, ownership transfer or upgrade route. `fund` pulls exclusively from its caller and grants no redemption rights.
- **Authorization:** The explicit owner is immutable. Reward administration consists only of signer rotation and claim pause/unpause. The shop owner can edit catalog terms and metadata, but cannot redirect primary payments, change royalties, freely mint or seize user inventory. Constructor ownership is never inferred from `msg.sender` or `tx.origin`.
- **Accounting and callbacks:** Nonces and paid totals update before payout. Purchase counters update before payment and mint callbacks. Both funding routes, claim, both purchase routes and catalog edits use a nonreentrancy guard. A failed token transfer, recycler or receiver reverts all state and all previous transfers in that transaction. Token inflows check exact balance deltas; the production asset is the fixed, non-rebasing LaunchToken.
- **Signatures:** OpenZeppelin EIP712 and ECDSA handle domain hashing and canonical recovery. Global consumed nonces survive rotation/day changes. The PostOffice check is a `STATICCALL` to the specified constant address and rejects any non-canonical boolean response.
- **Dependencies and arithmetic:** Dependencies cannot be replaced after deployment. MoonShop checks live dependency code and that rewards uses its token before charging. The split adds exactly to cost, including odd wei. Limits use lifetime counters, and checked arithmetic prevents overflow-based free purchases. Shop approvals to rewards are exact and cleared after use.

Foundry's build linter reports conservative reentrancy/event-order warnings at external calls and the intentional timestamp-based expiry check. The external mutation paths are enclosed by OpenZeppelin `nonReentrant`, which enters the guard before the call and clears it on return; the reported `_status` write after a call is that guard reset. Claim/quote read calls are static. Callback tests verify rejection, and failure tests verify reverted logs/accounting cannot survive. UTC timestamps are the requested time source and are never used as randomness. Warnings have not been globally suppressed. Slither, Mythril, formal verification and a live-chain fork were not run.

## Assumptions and later-stage responsibilities

The initial threshold is a one-time activation, mission bounds are inclusive, voucher nonces are global, zero wallet limit means unlimited, and the odd payment wei is recycled. These implementation choices are explicit in the README and ABI guide. There is no separately deployable companion contract; MoonShop is the collection.

The game server is trusted to certify real missions and protect its EOA signer. An owner can select a malicious signer and authorize false gameplay within the immutable constraints. Signatures prove authorization, not physical travel. The owner can censor claims through pause or signer selection; loss of these keys can strand funds. PostOffice availability and truthfulness are external dependencies, unverified against live chain state here. Its fixed address cannot be repaired in place.

The creator's complete deposit is an operational promise. The threshold checks actual pool funding, not which account funded it. The frontend must separately show the creator balance and authentic funding receipt; those values cannot be fabricated before deployment. Metadata remains editable; secondary marketplaces choose whether to pay royalties. Direct accidental transfers to contracts are not recoverable.

The independent contributor must review source plus the complete launch manifest, especially token/rewards dependencies and owner/royalty arguments. Services then publish, attest, admit and deploy. Courier World supplies its production signer and mission server; the creator deposits and publishes the funding receipt. The subsequent frontend stage uses verified addresses and performs browser/mobile/wallet testing. No live deployment, funding receipt, GitHub publication, IPFS site or independent audit is asserted by this contract assignment.
