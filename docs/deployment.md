# Deployment handoff

This is constructor and operations documentation, not a launch manifest. The manifest assignment owns `launch.json`. Publishing source, artifact signing/linkage, attestation, admission and deployment are service responsibilities and are not prerequisites for completing this source assignment.

## Artifact order

| Position | Artifact | ABI-encoded constructor values |
| --- | --- | --- |
| Launch token | `src/LaunchToken.sol:LaunchToken` | Empty |
| Application 1 | `src/MoonRewards.sol:MoonRewards` | `address $token`, `address $owner` |
| Application 2 | `src/MoonShop.sol:MoonShop` | `address $token`, `address $contract:MoonRewards`, `address $owner` |

Here `$owner` resolves to the requester's `0x72215670c2266bc224949a12c514a77d7fd5d566`. Both owner arguments and the shop's royalty recipient must resolve to that owner, never the factory or deployment sender. Each application has fewer than 16 static constructor arguments. `CourierCompanions` is abstract; it is the ERC-1155/2981 base of MoonShop and is not a separate entry. `IPostOffice` is an interface to the supplied external address, not a deployment. Do not list tests, mocks, libraries, a distributor, guard, hook or a standalone companion contract.

Constructors have no outside calls, funding, code-length requirements, ownership inferred from the sender, or post-deployment initialization calls. Dependencies are immutable. The signer setting and shop catalog are ordinary post-launch operations; the factory does not initialize them. No source contract needs an IMD key, subscription, backend URL, policy hash or attestation.

## Fixed launch values

| Field | Approved value |
| --- | --- |
| Chain | Robinhood Chain, `4663` |
| Token name / symbol / decimals | `MOON` / `MOON` / `18` |
| Supply | `1000000000000000000000000000` |
| Supply allocation by factory | Swarm 10%, pool 20%, creator 70% |
| Pair | IMD, `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, 18 decimals |
| Pool fee | `12500` = 1.25% |
| Tick spacing | `60` |
| Manifest initial price | `79228162514264337593543950336` |
| Effective opening price | Service derives it from 2,500 IMD opening market cap and token ordering |
| PostOffice | `0x26D80804D0FA2F4598369E0062bFC9536d115D82` |

The 1.25% pool trading fee is handled by the protocol: 1% to the paying wallet and 0.25% to IMD. Application contracts do not duplicate this fee. The factory supplies the launch distributor and initialization guard and retains LP custody as specified. No reward-pool allocation occurs in an application constructor. The creator must deposit after launch.

Compile with the committed root Foundry configuration. No public/external library link placeholders, proxies, delegatecall, callcode or selfdestruct occur in deployable runtime. The compatibility tests deploy actual creation bytecode through a local CREATE2 fixture, check the full supply remains with that fixture, and scan deployed opcodes while skipping PUSH data. This is a local test fixture, not the production factory.

## Launch/operator checks

- Independent review must compare source and all manifest constructor arguments, including owner/royalty roles and the rewards reference. Policy and signed artifact linkage belong to services; concrete constructor/source/authorization conflicts remain review findings.
- Before funding, deployment services/operators must verify live code and `offices(address) -> bool` behavior at the pinned PostOffice on chain 4663. Unit tests exercise a local implementation at the exact address; no live-chain compatibility claim is made here. The application fails closed if unavailable. The address is immutable by requirement.
- Use verified deployment receipts to populate actual token/rewards/shop addresses and the frontend pool key. There are no guessed production addresses in this repository.
- Configure the backend EOA signer, confirm token and rewards wiring, configure the catalog, and carry out the creator's deposit as described under **After launch** in the README. Store and publish the real funding receipt hash and transaction link.
- Show signing, allowance, UTC-cap, exhausted-pool, pause and unconfigured states correctly in the later frontend. The owner and Courier World operate this launch; IMD does not run the game server or exercise owner privileges.

No deployment receipt or funding hash exists from this assignment. No transactions were broadcast and no wallet keys were accessed.
