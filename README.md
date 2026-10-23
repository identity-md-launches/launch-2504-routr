# routr/

Routr (`ROUTR`) is a fixed-supply ERC-20 and an immutable Uniswap v4 hook that funds open research. The root is a complete Foundry project; all Solidity dependencies are vendored as ordinary source files. Tests deploy a real, local v4 `PoolManager` and require no RPC, keys, environment configuration, FFI, filesystem cheatcodes, or network.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x50760a92d388271d340b769691a828bcdd04f3ff763124f46ac70e63546670b2 forge test
forge fmt --check
```

The compiler is pinned to Solidity **0.8.26**, with optimization, Cancun/EIP-1153, and `bytecode_hash = "none"`. Foundry and that compiler must already be installed for an offline build. Dependency provenance and licenses are in [DEPENDENCIES.md](DEPENDENCIES.md).

**Token.** [RoutrToken.sol](src/RoutrToken.sol) mints exactly **1,000,000,000 ROUTR**, with 18 decimals (`10^27` base units), once to its constructor caller. At launch that caller is the factory. There is no owner, mint function, burn function, transfer tax, blacklist, pause, proxy, or upgrade function. Transfers and approved `transferFrom` move the requested amount. Self transfers and zero-amount transfers are supported; transfers to the zero address are rejected. The factory, rather than these contracts, performs the launch allocation: 80% pool, 10% swarm distributor, 10% launch payer/treasury under launch policy.

The public constant metadata and the token's NatSpec header both contain:

```text
WEBSITE = "https://imdroutr.network"
TWITTER = "https://x.com/routr_network"
DESCRIPTION = "routr/ funds open research through a token. Trades feed a vault, and specialized agents from the imd.fun swarm take paid jobs in cancer, disease, medicine, robotics and AI. Every job, result and payment is public."
```

**Fee definition.** [RoutrHook.sol](src/RoutrHook.sol) charges **2% of gross ETH** on every successful swap, starting with the first trade. Gross ETH means the buyer's total ETH input including the hook fee, or the seller's ETH output before the hook fee. The fee is separate from the pool's **1.25% LP fee**. There is no launch tax, time decay, holder payout, LP fee override, token conversion, or administrator.

For gross ETH `G`, in wei:

```text
total fee = floor(G * 200 / 10_000)
research  = floor(G * 150 / 10_000)
team      = total fee - research
```

All rounding is in wei. Assigning the residual to the team conserves the total fee; it differs from separately rounding 0.5% down by at most one wei. A mathematical fee below one wei rounds to zero. Splitting trades cannot avoid more than this integer rounding per trade.

| Trade | Fee calculation and callback |
| --- | --- |
| Exact-input buy, ETH budget `B` | `beforeSwap` returns `floor(B * 200 / 10_000)` in specified ETH. The AMM uses the remainder. |
| Exact-output buy, desired ROUTR | `afterSwap` observes actual AMM ETH input `A`, adds `floor(A * 200 / 9_800)` in unspecified ETH, and pays the fee. Gross ETH is `A + fee`. |
| Exact-input sell, ROUTR budget | `afterSwap` observes actual gross ETH output `G` and deducts `floor(G * 200 / 10_000)` in unspecified ETH. |
| Exact-output sell, net ETH target `N` | `beforeSwap` returns `floor(N * 200 / 9_800)` in specified ETH, asking the AMM for `N + fee`; the seller receives exactly `N`. |

The gross-up formulas preserve `fee = floor(grossETH * 2%)`. Research and team amounts always use that same gross basis. A 10 ETH exact-input buy pays 0.15 ETH research and 0.05 ETH team. A 9.8 ETH exact-output sell asks the AMM for 10 ETH and pays those same shares. For an exact-output buy requiring 9.8 ETH of AMM input, the buyer pays 10 ETH including the same split.

EIP-1153 transient slots carry the fee and swap context from `beforeSwap` to `afterSwap`, and guard against nested swaps and payout/withdrawal reentrancy. Every enabled callback checks the immutable PoolManager caller. `hookData` cannot change fees or recipients. No router allowlist is needed because every router faces the same fee and no user identity is taken from hook data.

**Price limits and partial fills.** The supplied price limit reaches the AMM unchanged. An exact-input sell can partially fill and is charged on the ETH actually received. ETH-specified swaps (exact-input buys and exact-output sells) must fill completely, because v4's `afterSwap` return value cannot correct a previously returned *specified-currency* fee. These swaps revert with `PartialFill` if the limit or available liquidity prevents completion. Exact-output buys also revert if the requested tokens cannot be delivered. All state and payouts revert atomically. Routers must quote through the hook, enforce minimum output/maximum input and deadlines, and handle these reverts; they must not assume every price-limited request can partially execute.

**ETH payout and credit recovery.** On a funded manager, the hook takes only its ETH fee and attempts both recipient payments during `afterSwap`. Each automatic push has a 50,000 gas budget and copies no return data. A rejecting, gas-consuming, or reentering recipient cannot block an adequately funded swap: its amount remains credited, while the other recipient can receive its share. Native ETH and token transfers never become a later conversion job.

A newly deployed manager seeded only with ROUTR has no ETH before the first buyer's router settles. v4 invokes `afterSwap` **before** that settlement, so immediate native payment is impossible in this case. If the manager's ETH balance cannot cover the fee, the hook mints native ETH ERC-6909 claims to itself and records the exact recipient credits. This avoids `NativeTransferFailed` and charges the first trade fully. The claims are backed when the router settles the swap.

Recovery entry points are ordinary payment functions, not administrative powers:

| Function | Caller and effect |
| --- | --- |
| `credits(recipient)` / `totalCredits()` | Read unpaid ETH liabilities. Claims plus the hook's native balance back these amounts. |
| `flush()` | Anyone can redeem available native claims and retry payments to the two immutable recipients. It accepts no destination argument. It works during an existing unlock after router settlement, or opens its own unlock in a later transaction. Failed pushes remain credited. |
| `withdraw(to)` | A credited recipient withdraws only its own entire credit to an accepting address. It redeems claims as needed, clears accounting before the external call, and restores credit on any revert. A stranger cannot withdraw another recipient's balance. |
| `unlockCallback(bytes)` | PoolManager-only, available solely during a redemption initiated by the hook. Burns claims and takes the matching ETH, leaving no unpaid manager delta. |

For an initially empty manager, an integrating router can call `flush()` **after settling its input**, within the same unlock, to deliver the first trade's fees in the same transaction. With a router that does not do this, anyone can flush afterwards. Redemption requires available manager ETH. No keeper has custody or configuration powers; a keeper pays its own transaction gas. A recipient contract must either accept a later push within the automatic gas budget or expose a way to call `withdraw` to an accepting destination. Unexpected forced ETH or unrelated tokens have no administrative rescue path.

**Pool and permanent liquidity lock.** `afterInitialize` binds once to the full `PoolId`: native ETH as currency0, this token as currency1, this hook, fee 12,500 and tick spacing 60. Other pairs, fee tiers, spacings, or a second initialization revert. Calls to an undeployed predicted hook cannot initialize the pool because the required callback must return the correct selector. The factory must deploy and initialize atomically so nobody can choose an opening price between those steps.

`beforeRemoveLiquidity` reverts **for every caller and every liquidity delta**, including zero. No owner, factory exemption, unlock date, or emergency removal exists. Existing liquidity principal can never be withdrawn. Additional positive liquidity deposits remain possible and are also permanently locked.

**Compatibility conflict in the supplied checks:** `Owners.protected.t.sol` expects a factory's zero-delta fee collection to succeed. The explicit assignment instead requires every `beforeRemoveLiquidity` call to revert and states that it overrides reference material. This implementation follows the unconditional lock, including zero-delta fee collection, and tests it. Consequently that specific protected fee-collection assertion is incompatible with the requested behavior. A positive liquidity addition may realize accrued LP fees as part of v4's normal accounting; it cannot remove principal. Launch operations must not rely on the usual zero-delta collection path.

**Deployment parameters.** Only these two application contracts are deployed; the research vault already exists and the chain's PoolManager is supplied by the launch system.

| Contract / argument | Value |
| --- | --- |
| `RoutrToken()` | No arguments; all supply goes to the deploying factory. |
| `RoutrHook.manager_` | `IPoolManager`, resolved from `$poolManager`; never a hardcoded manager. |
| `RoutrHook.token_` | Address of the launch's `RoutrToken`, resolved from `$token`. |
| `RoutrHook.researchVault_` | `0x087C0CF0A103acA2c487c5017DbC121ad6C5afEE` |
| `RoutrHook.teamWallet_` | `0x5Cf44fb6a49156125b5f9Dfea73E4011534C7944` |
| Hook address low 14 bits | `0x12cc` (decimal 4812) |
| Chain / EVM | Ethereum mainnet, chain ID 1; Cancun or newer. |
| Pool | Native ETH / ROUTR; LP fee 12,500; tick spacing 60. |

Constructors make no external contract calls and do not require code at supplied addresses. Zero manager, token, and recipients are rejected. Recipients cannot be the hook or manager. The constructor validates the hook's permission bits, so a normal unmined CREATE address will generally revert.

The permissions are precisely `afterInitialize`, `beforeRemoveLiquidity`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`. All others are false. The implementation uses the v4-core interfaces directly with no additional base class, share token, access-control framework, or externally linked library.

[MineRoutrHook.s.sol](script/MineRoutrHook.s.sol) is an offline, read-only salt utility. Call `run(factory, manager, token, start, attempts)` with the actual CREATE2 executor, manager and predicted/deployed token addresses. The two recipient addresses above are fixed in this utility. It returns the predicted hook address, salt and init-code hash; it neither deploys nor broadcasts. Search in batches (200,000 attempts is the suggested first batch). Recompute after any bytecode, compiler-setting, constructor-argument, or factory change, and check that the returned address is unoccupied before deploying. Tests deploy the exact returned init code with CREATE2 and verify the resulting permission bits and recipients.

The launch system must deploy the token, deploy the hook at the mined address, initialize the pool, and seed the token-only position atomically. Use the opening price derived by the launch policy from the 10 ETH opening market cap and supply. The tests' 1:1 price is only a local fixture. Since native ETH sorts first, a token-only position has its upper tick at or below the opening price and its lower tick below that, both multiples of 60. The deployer calculates the range and liquidity to supply the policy's 800,000,000 ROUTR allocation without ETH. Buyers move the price down into that range and supply ETH. Never seed an in-range position that requires ETH when rehearsing the token-only launch.

**After launch.** There are no settings to configure or admin keys to hand over. Operations should verify deployed bytecode, metadata, immutable arguments, pool binding and permission flags; monitor `FeeCharged`, `Payment`, `CreditAccrued`, `ClaimsRedeemed` and `Withdrawal`; call `flush` when claims or rejected payments remain; and ensure the vault can receive or withdraw funds. Research-job selection, agent execution, result publication, and vault spending are responsibilities of the existing research vault and swarm, outside these two contracts. The separate launch process owns its manifest and deployment; this repository does not contain `launch.json` or broadcast transactions.

**Verification and review.** Tests cover all four swap modes and ETH accounting against actual PoolManager swap events, first-trade token-only liquidity, claim redemption both inside and outside a router unlock, recipient rejection, gas exhaustion, reentrancy, failed withdrawal rollback, partial-fill handling, irreversible liquidity lock, pool binding, callback access, metadata, fixed supply, ERC-20 behavior and CREATE2 deployment. Stateful invariants interleave swaps, payment rejection, withdrawals and flushes and check backing, recipient shares, native/token conservation and settled manager deltas. [SECURITY.md](SECURITY.md) records the implementation review and remaining release responsibilities. No live fork rehearsal, independent audit, or production deployment is claimed.
