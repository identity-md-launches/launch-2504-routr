# Vendored dependencies

All files under `lib/` are ordinary files, with no submodules or install-time downloads. `dependencies.sha256` records the content hashes. The new token and hook are MIT-licensed; dependency licenses remain as supplied upstream.

| Directory | Upstream source and pin | Included files |
| --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75), commit `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | Unmodified production `src/` (upstream `src/test/` omitted) and both upstream licenses. |
| `lib/forge-std` | [foundry-rs/forge-std](https://github.com/foundry-rs/forge-std/tree/3b20d60d14b343ee4f908cb8079495c07f5e8981), tag `v1.9.6`, commit `3b20d60d14b343ee4f908cb8079495c07f5e8981` | Unmodified `src/` and license files; used by tests only. |
| `lib/solmate` | [transmissions11/solmate](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647), commit `4b47a19038b798b4a33d9749d25e570443520647` | Unmodified `src/auth/Owned.sol` and license, at v4-core's pinned revision; only the local test PoolManager uses it. |

Uniswap v4-core includes MIT interfaces/utilities and BUSL-1.1 core implementation files; licenses are retained under `lib/v4-core/licenses/`. The PoolManager implementation and its Solmate owner are deployed only as offline test infrastructure. The application hook neither inherits those ownership powers nor deploys a PoolManager in production; it connects to the manager supplied by the launch system. Forge Standard Library is MIT/Apache-2.0; Solmate's included `Owned.sol` is AGPL-3.0-only. Consult each file's SPDX identifier and the included license texts.

Verify vendored contents with `sha256sum --check dependencies.sha256`. No downloaded compiler binary is part of the project.
