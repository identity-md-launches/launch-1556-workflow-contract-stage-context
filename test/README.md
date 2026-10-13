# MOON contributor test extension

Run the complete offline suite from the repository root:

```sh
forge build
forge test
```

The added tests use the existing vendored dependencies and real `LaunchToken`,
`MoonRewards`, and `MoonShop` implementations. They require no environment
variables, downloads, RPC, FFI, or files under `.imd/reads/`. All identities and
signing keys are local Foundry fixtures. No production configuration is changed.

## Added coverage

| File | Additional checks |
| --- | --- |
| `MoonRewardsEdges.t.sol` | Funding/claim event accounting; zero and maximum inputs; funding permit rollback and retry; expired-permit fallback restricted by allowance; zero and maximum voucher nonces; global daily cap exceeded by one wei; noncanonical, short, oversized and state-writing PostOffice responses; failed claims before direct-donation activation. |
| `MoonShopAtomicity.t.sol` | Rejected mint rolls back reward activation; failed approval creation and cleanup roll back every payment; creator callbacks cannot reenter item configuration or permit buys; forwarding an NFT then rejecting rolls back the nested transfer; batch-transfer atomicity and operator revocation; split-order rounding; item ID zero and purchase events. |
| `invariant/MoonLifecycle.invariant.t.sol` | Four players and three editable items, initially below the funding threshold. Random sequences combine approval/permit deposits, direct donations, purchases, item edits, authorized/unauthorized transfers, claims, pause and time advancement. |

The three new stateless fuzz properties run **1,000 cases each**. The new invariant
runs **256 sequences at depth 128** with unexpected handler reverts treated as
failures. These settings are inline in the tests, so they travel with the suite.
The pre-existing test suites remain intact.

## Stateful properties

The lifecycle handler maintains its own balances, permit and mission nonces,
purchase history, item inventory, catalog terms, and historical daily payouts.
It updates those records from successful operation inputs, independently of the
production contract's counters. It checks success against the operation's
preconditions as well as checking rollback on failure.

After every generated call:

- Pool balance plus mission payouts equals initial and subsequent `fund` deposits,
  direct donations, and shop recycling. Direct donations are excluded from
  `totalFunded`.
- Every player's MOON balance matches the ledger, and all tracked balances sum to
  the fixed billion-token supply. The creator receives no primary-sale revenue.
- Purchase payments equal burned plus recycled tokens. The shop retains only
  direct donations and leaves no allowance to rewards.
- Each item's inventory across players and lifetime purchases both equal minted
  supply. Transfers never restore purchase limits; rejected edits preserve terms.
- All historical wallet/day totals match the ledger, remain capped, and sum to
  lifetime payouts. Used mission nonces stay used across players and days.
- Permit nonce changes agree with successful permits across both deposit and buy
  entry points. Failed outer transactions restore permits and allowances.
- Activation cannot occur below the initial threshold or become undone after a
  successful activation. Failed purchases cannot commit intermediate activation.

Two deterministic scenarios assert explicit success/failure counts and cover
direct-donation and shop-recycling activation. They ensure the harness exercises
substantive state changes even when random inputs produce many rejected calls.
The global cap is reached using 50 wallets in unit tests; the four-player
invariant cannot saturate that cap within one day.

## Limits

The PostOffice integration is exercised offline at its specified address, with
both the documented boolean interface and adversarial responses. Live Robinhood
Chain code and game-server operation remain unverified by this suite. Tokens
with approval faults and contract receivers are isolated fault-injection fixtures;
the stateful economy uses the actual fixed-supply launch token throughout, without
minting or modifying token storage to manufacture balances.

No implementation defect was reproduced in these checks. Passing tests do not
replace the separately assigned source/manifest review or deployment checks.
