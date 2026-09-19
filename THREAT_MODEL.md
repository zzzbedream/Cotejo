# Cotejo Phase 2 · Threat model

An isolated lending market on top of the phase 1 oracle, on Whitechain.

This document exists so a reviewer can judge the design without reading the code, and above all
so they know **which attacks it does not cover**. A threat model that only lists victories is
not a threat model.

---

## 0. The attack that defines the design

On 30 August 2026, Tectonic — the largest credit protocol on Cronos, with $121.7M in deposits —
was exploited for $75M. The mechanism: a collateral asset with a 20% factor and barely $1.34M of
liquidity, whose price rose 100x in twenty minutes. Crypto.com halted the entire chain. Capital
was shared across every market, so **one bad collateral drained the whole pool**.

Three properties of the incident, and the response to each:

| Tectonic property | Response in Cotejo |
|---|---|
| Shared pool: one bad collateral reaches all capital | Markets isolated by `Id`; a collateral can only damage its own markets |
| Price movable by a single source | The router reverts on INV-2 before publishing (phase 1) |
| Debt far exceeding the liquidity backing it | `maxTotalBorrow` tied to observed depth |

---

## 1. Admission rules

Validated at market creation, and they revert. None is relaxable by governance.

| Rule | What it requires | Why |
|---|---|---|
| **R1** | The `oracleAdapter` points at Cotejo routes with `minSources >= 3` | A two-source price has no defensible median |
| **R2** | Those routes carry `>= 3` distinct `operatorGroup`s | An asset that cannot be valued independently cannot be collateral |
| **R3** | `lltv <= MAX_LLTV` (86%) | Minimum margin for a liquidation to be viable |
| **R4** | The `irm` is whitelisted among deployed implementations | Bounds the damage of an arbitrary interest curve |
| **R5** | `LIF <= min(derived formula, absolute ceiling)` | See §2 |
| **R6** | The `assetId -> token` registry confirms the adapter prices the market's tokens | Without it, R1 and R2 verify a route that might not be the collateral's |
| **R7** | Every route a market uses satisfies `sources.length >= minSources + 2` | See §4 |
| **R8** | The adapter freezes route policy at deployment; `price()` reverts if the live route weakens | Governance may tighten, never loosen |

### R6 is append-only, out of necessity

The `assetId -> token` registry lives in the `PriceRouter`. **Once a mapping is set it cannot
change.** If governance could remap `keccak256("WBT/USD")` to a different token, every market
created under the previous mapping would silently be valuing an asset other than the one it
custodies, with no invariant firing. A mutable registry turns R6 into decoration. It is
append-only, with no delete function.

---

## 2. Deriving R5 — the incentive ceiling

The liquidation incentive is not a matter of taste: it is the exact amount of value an attacker
can extract if they move the price to the edge of what the route tolerates without reverting.

At the LLTV limit, debt is `lltv × collateralValue`. A liquidation pockets `LIF × debt` in
collateral, so the seized fraction of collateral is:

```
seizedFraction = LIF × lltv
```

The route may be wrong by up to `deviationCombined` without reverting — that is precisely the
tolerance INV-2 grants. For the seizure not to exceed the **real** collateral even under the
worst tolerated error:

```
LIF × lltv  <=  1 − deviationCombined

LIF_max  =  (WAD − deviationCombined) × WAD / lltv
```

with `deviationCombined = devColRoute + devLoanRoute`, both in WAD.

Numerically verified values:

| Routes | Combined | LLTV | `LIF_max` | Bonus |
|---|---|---|---|---|
| 100 + 100 bps | 200 bps | 86% | 1.139535 | **13.95%** |
| 200 + 200 bps | 400 bps | 86% | 1.116279 | **11.63%** |

### Two limits the formula does not impose, and which are needed anyway

**The formula does not protect the borrower.** It is a *safety* ceiling, not an *economic* one.
At 50% LLTV with 100 bps routes it yields `LIF_max = 1.96`, a **96%** bonus: the liquidator
takes nearly double what they repay. That extracts no value via oracle error — which is what R5
watches — but it does squeeze the borrower. Hence the market applies
`LIF <= min(formula, MAX_LIF_ABSOLUTE)`. The absolute ceiling is not an oracle-risk estimate; it
is a different protection for a different problem.

**The formula imposes an implicit ceiling on route tolerance.** When
`deviationCombined >= WAD − lltv`, `LIF_max` falls below `WAD`: the liquidator would pocket less
than they repay and nobody would ever liquidate. At 86% LLTV that happens from **1400 combined
bps** upward. Above `WAD` the formula underflows. Market creation rejects both cases explicitly,
because a market with no viable liquidation is not a conservative market: it is a market with
guaranteed bad debt.

---

## 3. Degraded mode

When the phase 1 router reverts — stale price, excessive deviation, operator concentration,
pause — the market enters degraded mode.

| Operation | State | Reason |
|---|---|---|
| `repay` | **ALLOWED** | Needs no price. Reducing debt is always safe |
| `supply` | **ALLOWED** | Adding liquidity cannot harm anyone |
| `supplyCollateral` | **ALLOWED** | Improves position health |
| `withdrawCollateral` | **ALLOWED only if `borrowShares == 0`** | With no debt there is no solvency check to make |
| `withdraw` (supply) | **BLOCKED** | See below |
| `borrow` | **BLOCKED** | Requires a solvency check |
| `liquidate` | **BLOCKED** | See below |

Interest **keeps accruing** during degradation. Freezing it would reward whoever caused it. The
mitigation for prolonged degradation is R7, not stopping the clock.

### Why liquidations are blocked

This is the most counter-intuitive decision in the design and the one a reviewer asks about
first.

Liquidating at a manipulated price **is** the extraction mechanism. At Tectonic the attacker did
not break the liquidation engine: they used it. They inflated the price of an illiquid
collateral and let the protocol's own machinery hand them $75M of good assets in exchange for
inflated security. The liquidations worked perfectly; that was the problem.

The explicit trade: **we prefer temporary bad debt to a liquidation based on a lie.** Bad debt is
bounded, socialised among that market's suppliers, and recoverable if the price returns. A
liquidation executed at a false price is irreversible and transfers the value to whoever
manufactured the lie.

### Why supply `withdraw` is blocked too

Allowing supply withdrawal during degradation opens the **first-mover advantage**: informed
suppliers withdraw while the price is untrustworthy, and whatever bad debt appears afterwards
concentrates on those who stayed. M3's socialisation is only fair if nobody can run before it is
recognised.

---

## 4. R7 — why five sources and not three

With `minSources = 3` over **exactly** three sources, a single reporter going down produces
`Cotejo__InsufficientSources`, the adapter reverts, and the market enters degraded mode. Because
degraded mode blocks liquidations, that means:

> **One reporter going down freezes solvency control for the entire market.**

That is a 1-of-3 liveness dependency for protocol safety, and it turns a routine operational
incident — a process crashing, an API rate-limiting — into a halt of the mechanism that keeps
the market solvent. Worse, it hands an underwater attacker a cheap target. They do not need to
manipulate a price; knocking over one reporter is enough.

R7 requires `sources.length >= minSources + 2`. With `minSources = 3` that is **5 sources across
5 distinct operator groups**, and two simultaneous outages are needed to degrade.

**Consequence for phase 1, as currently deployed:** the live deployment configures five
`AttestationSource` contracts under five distinct groups (`cotejo-keeper-1` … `cotejo-keeper-5`)
with `minSources = 3`, so it satisfies R7 arithmetically.

It does not satisfy the property R7 exists to buy. All five keys are derived from one seed,
held by one process, reading one venue. Two simultaneous outages are required only if the
outages are independent, and here they are the same outage. R7 is met on paper and unmet in
substance until five operators hold five keys. This is stated at length in
[`keeper/README.md`](keeper/README.md) and is the single largest gap between what the contracts
enforce and what is actually true today.

---

## 5. What this design does NOT cover

The part that matters.

### 5.1 `depthUsd` is declared by the very parties we defend against

The debt ceiling is computed from **self-reported** depths in the attestations. There is no
on-chain check that the liquidity exists. A colluding set of reporters inflates `depthUsd`,
raises `maxTotalBorrow`, and enables exactly the over-borrowing the ceiling exists to prevent.

Partial mitigations, none sufficient:

- R2 and R7 require collusion to span several independent operators.
- M1 used to take the **minimum**; it now takes the **second-lowest**, read through the router so
  it inherits INV-2 and INV-5. The trade is exact and **costs something real**: with the minimum,
  one honest reporter sufficed to bound the ceiling, but one malicious reporter could drive it to
  zero and block all borrowing on the route. With the second-lowest, two liars are needed to
  inflate it and two to deny it. Giving up "one honest reporter is enough" is only defensible
  because A1.1 bounds the loss without consulting any reporter at all. The two ship together or
  neither ships.
- The growth clamp (2500 bps/hour) removes instantaneous inflation right before a large borrow.

Two defences added after this document was first written:

- **A1.1 — absolute ceiling (`MAX_ADAPTER_DEBT_USD`).** Immutable, fixed before deployment,
  enforced per adapter. It is the **only mechanism in the design whose guarantee does not depend
  on any reporter being honest**: under total collusion it turns an unbounded loss into a bounded
  one. It does not prevent the attack; it caps what the attack is worth.
- **A1.2 — bad-debt feedback.** When a liquidation leaves bad debt, the depth anchor is cut by
  50%. Bad debt is on-chain proof that the declared depth was not there: a liquidator could not
  unwind the position against the book that supposedly existed. It is the system's only check on
  a reporter claim that uses evidence reporters do not produce. It arrives after the fact.

Even so, **a mostly-colluding, patient set can inflate the ceiling** up to the absolute cap. The
root cause has no solution within this scope: it would require on-chain proof of liquidity, which
does not exist on Whitechain testnet because there is no DEX. On mainnet, WhiteSwap survives the
migration, and adding a TWAP source to the route **requires no phase 2 contract change** — R8
only reverts if the route weakens, and adding an operator strengthens it.

### 5.2 Blocking liquidations is a griefing vector — now with a bounded exit

An underwater borrower benefits from degradation. R7 makes causing it expensive, but does not
eliminate it. The exit is **A2, `liquidateDegraded`**: after 72 hours of continuous degradation, a
pro-rata liquidation opens that **consults no live price**.

Why that does not reopen the extraction path: there is no price in the seizure formula, so there
is nothing to manipulate. At zero premium the seizure is exactly proportional, which leaves the
collateralisation ratio **where it was** — it is arithmetically neutral. All the liquidator's edge
is the premium: at most 10%, reached only after 72 hours plus a seven-day ramp of *continuous*
failure, capped at half the debt, and requiring real tokens to be fronted against a position that
is by definition already underwater.

Eligibility is decided by the price anchor, which is the only place a stored price enters the
market, and it obeys a rule you can check with a `grep`:

> **INV-7′** — a stored price may only *restrict* an action. No code path may compute a token
> amount from it.

Pinned by `testFuzz_A2_seizureIsIndependentOfPrice`, which varies the underlying price across 512
runs and requires the seizure not to change.

**What it does NOT do:** it does not restore health. Shrinking an underwater position
proportionally leaves it underwater. It is an orderly liquidation valve, not a solvency repair,
and pretending otherwise would be dishonest.

One oversight fixed along the way: `RouteGovernor.setGuardian` was immediate, justified by "a
guardian can only pause, so granting it cannot cause harm". That held while the router stood
alone. With phase 2 it is false — pausing freezes liquidations, which is a solvency event. So
**granting** pause power now waits 48 hours (A6.3); revoking it remains immediate.

### 5.3 Total oracle collusion — bounded upward, not downward

If every group reports the same false price, deviation is zero and INV-2 never fires. R2 and R7
buy structural independence, not honesty.

**A3 closes the upward direction.** The market keeps a rate-limited price anchor and reverts
`borrow` and `withdrawCollateral` if the live price rises faster than the band (5% instantaneous,
+20%/hour, 50% ceiling). It compares against what this market itself saw a moment ago, not
against what other reporters say — which is exactly what a lying consensus cannot fake. The anchor
clamp is the half a reviewer skips and the half that makes it work: without it the circuit breaker
falls in a single block (inflate the price, call any permissionless mutator to anchor the lie,
borrow).

**The downward direction is deliberately uncovered, and that needs saying plainly.** A circuit
breaker on a falling price would fire during a genuine crash, degrade the market, and freeze
liquidations exactly when they matter most: **it would manufacture the bad debt it claims to
prevent**. The only safe variant would compute the seizure from a stored price, violating INV-7′.
That is why `liquidate` is **never** subject to the band — that exemption is the property that
makes the whole mechanism safe, and it is pinned by
`test_A3_liquidationIsNeverGatedByTheBand`.

So under total collusion the deflationary direction is **not prevented**. It is bounded by
`MAX_ADAPTER_DEBT_USD` and by the guardian pause, and by nothing else.

### 5.4 Absence of liquidators

`maxTotalBorrow` assumes willing, capitalised liquidators exist. If nobody liquidates, the ceiling
saves nothing: it only guarantees the debt *could* be unwound, not that it is.

### 5.5 IRM whitelist capture

**Correction.** An earlier version of this section claimed the worst damage was an absurd interest
rate. That was false. `IIrm.borrowRate` is not `view` and is called from all seven mutators, so an
IRM that reverts — or a proxy later repointed at one that reverts, or one that simply burns all
the gas — **froze the entire market permanently, `repay` and `liquidate` included, with the funds
inside**. And because `irm` is part of the `Id`, removing it from the whitelist did not rescue an
already-created market: R4 is a creation-time check and nothing more. Freezing is worse than 800%
interest.

Closed with three layers:

- **A5.1.** The call is wrapped in `try/catch` with `IRM_GAS_LIMIT = 150,000`, the same pattern
  `PriceRouter._readSource` applies to sources and for the same reason: without a gas cap, the
  63/64 rule leaves the caller unable to finish and the `try/catch` becomes the denial vector
  instead of the protection. A failing model means 0% interest for that interval, which is
  recoverable.
- **A5.2.** `ReentrancyGuard` on every mutator. A whitelisted IRM had a reentry point inside
  `borrow` and `liquidate`, and the only thing preventing it was trusting the whitelist —
  precisely what this threat assumes compromised.
- A timelock on the whitelist (A5.3) is still outstanding. It buys little on its own: R4 is
  creation-time, so revoking does not affect live markets.

### 5.6 MEV and liquidation competition

Liquidation sandwiching, gas priority, and incentive capture by searchers are not addressed. The
50% close factor limits the size per operation, not who captures it.

### 5.7 Non-standard tokens

M6 validates by balance delta on every entry, so fee-on-transfer and rebasing tokens **fail on
first use** instead of silently corrupting accounting. That detects them; it does not support
them. A positively-rebasing token leaves orphaned funds in the contract.

### 5.8 L1 → L2 migration risk

On migration, state is preserved but the chain id changes. Two consequences:

- EIP-712 attestations signed before the migration stop validating. That is correct, but the
  reporters must be reconfigured the same day.
- The L2 Mainnet chain id is **not yet published**, so it cannot be fixed in advance.

M7 removes the related risk: `block.number` is used in no temporal calculation, because 1-second
blocks plus a chain change turn any block-number logic into a time bomb.

### 5.9 Route governance risk

R8 prevents a route from weakening under a live market. Governance can still **pause** the asset,
which degrades the market and freezes liquidations.

**One mechanism covers both threats.** A guardian pause and a reporter outage are
indistinguishable at the adapter: both make `price()` revert, both start the same clock, and both
open `liquidateDegraded` after 72 hours. Pinned by `test_A2_guardianPauseAlsoOpensTheWindDown`.
Additionally, granting pause power now waits 48 hours (A6.3), so a compromised owner cannot
manufacture themselves a guardian in the same block.

### 5.10 Explicitly out of scope in v1

Flash loans, cross-market collateral, a governance token, and any function that allows changing an
existing market's `lltv`. The last one is not an omission: writing it would reintroduce the
problem the entire design avoids.

---

## 6. Invariants verified in tests

| Invariant | Test |
|---|---|
| The sum of borrower debt never exceeds the total borrowed | `invariant_borrowSharesNeverExceedTotal` |
| No market touches another's collateral | `invariant_marketsNeverShareCollateral` |
| `totalBorrow` never exceeds `maxTotalBorrow` after a successful operation | `invariant_borrowNeverExceedsDepthCap` |
| Rounding always favours the protocol | `testFuzz_supplyRoundTripNeverFavoursTheUser`<br>`testFuzz_borrowRoundTripNeverFavoursTheUser` |
| R2 rejects collateral with a concentrated oracle | `test_R2_rejectsCollateralWithConcentratedOracle` |
| The Tectonic attack does not work | `test_TectonicReplay` |
| A depth drop blocks borrowing, it does not enable liquidations | `test_DepthCapBlocksBorrowNotLiquidation` |
