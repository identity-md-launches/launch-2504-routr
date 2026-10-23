# Implementation review

This is a local implementation review, not an independent audit. The supplied Ethereum and v4 security references were used as background alongside the pinned v4-core code. Unit, fuzz and invariant tests exercise an actual locally deployed PoolManager; no mocked swap arithmetic or network fork is used.

| Area | Implementation and evidence |
| --- | --- |
| Callback authority | Every enabled callback requires the immutable PoolManager. Pool checks use the entire bound `PoolId`. Tests reject unauthorized initialization, swap, removal and redemption callbacks. |
| Permission/address consistency | Exactly six permission flags, mask `0x12cc`; constructor calls `Hooks.validateHookPermissions`. CREATE2 deployment and incorrect-flag failure are tested. |
| Initialization | Native ETH plus the constructor token, fee 12,500 and spacing 60 only; one binding; no external constructor calls. Empty predicted-hook initialization fails. Atomic factory deployment/initialization remains required. |
| Return-delta / NoOp risk | `beforeSwap` charges at most the immutable fee, never replaces the entire swap or calls an internal swap. The AMM performs the trade. ETH-specified partial fills revert instead of retaining an oversized fee; exact-output buys and exact-input sells may partially fill and are charged on the actual ETH. Exact-output net amounts are preserved. |
| Currency accounting | Only ETH deltas and native claim ID 0 are used. No ROUTR fee or token conversion. Tests compare hook-adjusted deltas to actual manager events and wallet balances. Every unlock settles to zero. |
| Recipient failures | Automatic calls have bounded gas and zero return-data copying. Reverts and exhausted recipient gas create credits; the other payment proceeds. Claims handle insufficient manager native balance. |
| Reentrancy | A transient lock spans both callbacks and all payout calls; the same lock protects flush and withdrawal. Swap context includes sender, pool key and full parameters. Withdrawal effects precede external calls. Reentrant withdrawal, flush and same-pool swap attempts fail. |
| Credit solvency | `credits[research] + credits[team] == totalCredits`; hook ETH plus native claims back all credit. Stateful invariants verify backing and cumulative recipient entitlements across rejection, retries and withdrawals. |
| Redemption | Claims are burned and the same ETH is taken in one unlock. A transient redemption amount authorizes the callback; unexpected or direct external callbacks fail. Flush never accepts a destination; withdrawal uses only the caller's credit. |
| Arithmetic | Swap input is bounded to signed 128-bit magnitudes before negation/multiplication; return deltas use checked casts. ETH gross-up stays within v4 delta bounds. Integer split rounding is documented and tested. |
| Token | Fixed constructor-only supply; allowance checks; zero-address restrictions; unchecked balance arithmetic bounded by total supply. No callbacks, tax, admin, proxy, mint or burn surface. |
| Liquidity | Every negative liquidity delta reverts. No caller, elapsed-time or admin exemption. A zero delta (LP fee collection, including the launch factory's) is let through with no hook delta, so principal stays locked while LP fees remain claimable. |
| Price and MEV | Fee calculation uses actual AMM deltas, not an oracle. The hook preserves the router's price limit. Routers remain responsible for slippage, deadlines and transaction routing. |
| Deployment / mutability | Both application runtime sizes fit EIP-170. No externally linked libraries, delegatecall, callcode, selfdestruct, setters or upgrades. Tests apply the supplied runtime opcode scan criterion. |
| State cleanup | Context, fee and lock transient slots are cleared after each successful swap; reverted operations roll back. Multiple swaps in a single unlock are tested. |

The native-balance fallback is intentional: v4 invokes the hook before a router normally settles input. A first buy on a token-only manager cannot universally transfer ETH to recipients within `afterSwap`. It records fully charged recipient entitlements as native claims instead. A router can redeem them through `flush` after settlement in the same unlock; a subsequent permissionless flush also works. A deployment requiring immediate payment in the first `afterSwap` must use a manager with sufficient native balance or a router that pre-settles input.

Automatic payout failure does not confer any new authority on the recipient. A complex vault needing more than 50,000 gas should pull its credit with `withdraw`, whose destination call uses available gas under the reentrancy guard. A non-upgradeable contract that both rejects ETH and cannot call another contract cannot recover its credit; operations must confirm the provided vault can receive or initiate withdrawal.

Remaining release responsibilities are independent adversarial review, validation of the actual manager/factory/recipient contracts, an atomic launch rehearsal using the actual opening price and liquidity range, explorer verification, and monitoring. The local review does not claim Slither, Mythril, formal verification, a mainnet fork, or an independent audit was run. The research vault's spending is governed by its own owner (the team wallet on mainnet), outside these contracts.
