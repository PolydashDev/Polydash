# Owner Capabilities

The `PolydashFactory` and `BuybackRouter` are `Ownable2Step` — ownership transfers need the new owner to call
`acceptOwnership()`. The owner **should be a multisig**. `PolydashLaunch`, `PolydashToken` and `PolydashHook` have
**no owner at all**.

Golden rule: **every factory setting applies only to launches created after the change.** Each launch copies its
config at creation (`initialize`) and keeps it forever.

## What the owner CAN do

### PolydashFactory

| Function | What it does | Bounds |
|---|---|---|
| `setAntiSniperConfig(highFeeBps, feeDuration, capBlocks, capBps)` | Anti-sniper surplus start rate, decay time, wallet-cap window and cap size for future launches | fee ≤ 20%, duration ≤ 1h, cap window ≤ 100 blocks, `0 < capBps ≤ 100%` |
| `setGraduationTarget(mode, value)` | Graduate on ETH raised or on market cap | ETH mode: 0.1 – 10,000 ETH; mcap mode: `0 < value ≤ 10M ETH` |
| `setBuybackConfig(enabled, bps, router)` | Send a share of **platform** fees to the BuybackRouter | `bps ≤ 100%`; router required when enabled. Never touches creator fees |
| `setTradingRewardsPool(pool)` | Destination of bought-back $POLYDASH | `address(0)` allowed = buyback disabled (router reverts, factory falls back to sending everything to the fee wallet) |
| `initiateFeeWalletChange(w)` / `executeFeeWalletChange()` / `cancelFeeWalletChange()` | Change the **platform** fee wallet | **48h timelock**, `address(0)` rejected |
| `setHook(hook)` | Hook used by future launches | must report `factory() == this` |
| `setPostGraduationSellSpike(bps, duration)` | Optional decaying sell surcharge after graduation, donated to locked LP | ≤ 10%, ≤ 1h; off by default |
| `transferOwnership` / `acceptOwnership` / `renounceOwnership` | OZ Ownable2Step | — |

`collectPlatformFees(launch)` / `collectPlatformFeesMany(...)` are **permissionless** — funds can only go to the
configured fee wallet / buyback router.

### BuybackRouter

| Function | Bounds |
|---|---|
| `setMaxSlippageBps(bps)` | ≤ 10% vs. TWAP |
| `setTwapWindow(seconds)` | 60 s – 1 day |
| `setPool(pool, fee)` | non-zero |

**PolydashCommitVault** has **no owner and no admin functions** at all: no fee, pause, sweep or upgrade. Its funds
only move via user `deposit`/`withdraw`/`claim` and the permissionless `settle`.

## What the owner CANNOT do

* **Change the 0.2% platform fee.** `PLATFORM_FEE_BPS = 20` is a compile-time constant; no setter exists
  (`test_NoPlatformFeeSetterSelectorExists`).
* **Touch creator fees** — change the rate, redirect, pause or seize them (see `CREATOR_FEE_SAFETY.md`).
* **Change a live launch** — curve parameters, graduation threshold, anti-sniper config, hook and fee rate are frozen
  per launch.
* **Remove or move graduated liquidity.** The hook owns the LP and has no removal code path.
* **Mint, pause, blacklist or tax** any launched token — `PolydashToken` has no owner.
* **Withdraw curve ETH, commitments or refunds** from a launch.
* **Upgrade** anything — no proxies with admin rights; launch clones point at an immutable implementation.
* **Deploy to mainnet by accident** — `Deploy.s.sol` reverts on Robinhood Chain unless
  `I_HAVE_WRITTEN_APPROVAL_AND_AUDIT=true`.

## Worst case if the owner key is compromised

An attacker could: start a fee-wallet change (visible for 48h, cancellable by the real owner only if they still hold
the key — hence the multisig recommendation), route up to 100% of **platform** fees into the buyback, or set harsh
(but bounded) anti-sniper / sell-spike settings for **new** launches. Existing launches, creator fees, user funds and
locked liquidity are unaffected.
