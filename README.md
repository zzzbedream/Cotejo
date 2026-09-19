# Cotejo

A price oracle for **Whitechain Sepolia** (OP Stack L2, chain id `1874`, gas token WBT), and an
isolated lending market built on top of it.

Cotejo is safe because it refuses to answer, not because it answers well. Given any doubt it
reverts with a typed error. A consumer that reverts is a consumer that is still alive.

It exposes `AggregatorV3Interface` with Chainlink's exact signature, so a protocol already
integrated against Chainlink can point at Cotejo without changing a line.

---

## What is live, and what it currently refuses to do

Phase 1 has been on chain since **18 September 2026**. Eight contracts, deployed and verified on
Blockscout:

| Contract | Address |
|---|---|
| `PriceRouter` | [`0xB4f9C215…0Fd096`](https://explorer.testnet.whitechain.io/address/0xB4f9C2151B73eDEa730A72e9642C971d803Fd096) |
| `RouteGovernor` | [`0x116a41d0…55341D`](https://explorer.testnet.whitechain.io/address/0x116a41d02bF43f7c15D9DB8EC3e0fDccAE55341D) |
| `AttestationSource` x5 | `cotejo-keeper-1..5`, one per operator group |
| `CotejoAggregatorAdapter` WBT/USD | [`0xc7624150…faE16`](https://explorer.testnet.whitechain.io/address/0xc7624150c28bF26cdF920A0715a7c0ba614faE16) |

Five sources publish real WBT/USD prices derived from the WhiteBIT order book, relayed from
GitHub Actions rather than from anybody's laptop.

**And `latestRoundData()` reverts.** `Cotejo__RouteNotConfigured`: the contracts exist and the
data is arriving, but no route is installed yet, because installing one takes a 48-hour
timelock that has not elapsed. An oracle that returned a number in this state would be the
problem, not the progress.

**The lending market is written, tested, and deliberately not deployed.** Its admission rules
are checked at `createMarket` and none is relaxable by governance: R1 requires the adapter to
point at routes with `minSources >= 3`, R2 requires those routes to carry at least three
distinct operator groups, R7 requires `sources.length >= minSources + 2`, and R8 freezes the
route policy at deployment so governance can tighten it but never loosen it. Every one of them
reads a **live route**, and no route is installed yet. The market cannot be deployed until the
oracle it depends on is actually serving — which is the ordering the rules exist to enforce.

Once the route executes, the five deployed sources satisfy R1, R2 and R7 on their face. They
will not satisfy them in substance, for the reason immediately below.

## What the live deployment does not prove

The five sources currently publish **identical prices, bit for bit. Deviation: 0.00 bps against
a 200 bps tolerance.**

That is arithmetic, not luck. One process reads one order book and signs five times with five
keys derived from one seed. INV-5 (one source per operator group) and R2 (three distinct
groups) are enforced by the contracts and satisfied *nominally*, not *actually*: five addresses
belonging to one operator are one operator.

So **INV-2, the deviation check, will never fire here** — five signatures over one number cannot
disagree. The invariant is not broken; it is idle, and it stays idle until the five prices come
from five places.

A healthy dashboard today therefore demonstrates aggregation, staleness, quorum and operator
concentration running against real data. It demonstrates nothing about deviation, which is the
check people assume demonstrates everything. The figure is on chain, so this can be confirmed
rather than taken on trust.

None of it is concealed: the on-chain operator groups are named `cotejo-keeper-1` …
`cotejo-keeper-5`, claiming no venue and implying no relationship with anyone. Replacing this
with genuinely independent operators is the work; this is the placeholder that lets everything
else be tested. [`keeper/README.md`](keeper/README.md) makes the same argument at greater
length, and calls itself a keeper rather than a reporter fleet.

---

## Why it exists

Whitechain has no price oracle deployed. Verified against the official documentation index
(`llms.txt`), which contains no oracle page, and against the six occurrences of "oracle" in the
full documentation, every one of which is OP Stack infrastructure rather than a price feed:

| Occurrence | What it is |
|---|---|
| `GasPriceOracle` (`0x420…000F`) | L1 data-fee predeploy |
| `l2OutputOracle` | Explicitly marked **not applicable** (Whitechain uses fault proofs) |
| `preimageOracleChallengePeriod` | Dispute-game parameter |
| "no gas-oracle action" | Note on the Etherscan-compatible API |

There is no Chainlink, no Pyth, no RedStone. There is also no native stablecoin — the gas token
is WBT — and swaps are documented as *"not available on any testnet"*. So **the price has to
come from outside, signed**, and the contracts assume whoever signs may lie or be compromised.

### Verified network parameters

Against `/learn/network/reference`:

| Parameter | Value |
|---|---|
| Chain id | `1874` (hex `0x752`), **Live** |
| L1 settlement | Ethereum Sepolia (`11155111`) |
| Block time | **1 s** |
| Min base fee | 5 gwei |
| Gas token | WBT, 18 decimals |
| RPC | `https://rpc.testnet.whitechain.io` |
| Explorer | `https://explorer.testnet.whitechain.io` |

Mainnet is not live yet; its chain id is published before launch.

One trap worth naming: `viem/chains` exports both `whitechainSepolia` (1874) and
`whitechainTestnet` (2625), and they are different networks. Every signing path here asserts
the chain id against the RPC before it signs, because picking the wrong one is one autocomplete
away.

---

## How a price flows

```
  Off-chain reporters (registered keys, one operatorGroup per source)
        |
        |  PriceAttestation{asset, price, decimals, observedAt, depthUsd, sourceId}
        |  EIP-712 signed  --  submit() is permissionless: the signature
        |                      authorises the write, the caller does not
        v
  +---------------------------------------------------------------------+
  | AttestationSource           ChainlinkCompatSource      TwapSource    |
  | - rejects future observedAt - wraps a feed             - v1: ALWAYS  |
  | - rejects replays           - requires answer > 0        REVERTS     |
  | - requires strict advance   - requires answeredInRound - supportsAsset
  |   of observedAt               >= roundId                 == false    |
  | - requires minimum depthUsd                                          |
  +---------------------------------------------------------------------+
        |  IPriceSource.latestPrice(asset) -> (price, decimals, observedAt, group)
        |  All view (D3). 200k gas cap per source.
        v
  +---------------------------------------------------------------------+
  | PriceRouter.latestPrice(asset)                                       |
  |                                                                      |
  |   0. paused?                --> Cotejo__Paused               (INV-6) |
  |   1. read every source                                               |
  |        - reverts            --> dropped, not fatal                   |
  |        - observedAt future  --> dropped                              |
  |        - price 0            --> dropped                              |
  |        - STALE              --> Cotejo__StalePrice           (INV-3) |
  |        - ok                 --> normalise to 18 decimals             |
  |   2. |fresh| < minSources   --> Cotejo__InsufficientSources  (INV-1) |
  |   3. operator concentration --> Cotejo__OperatorConcentration(INV-5) |
  |   4. insertion sort (n <= 15, D4)                                    |
  |   5. (max-min)*1e4/median   --> Cotejo__DeviationExceeded     (INV-2)|
  |   6. return (median, 18, OLDEST observedAt in the set)               |
  +---------------------------------------------------------------------+
        |
        v
  +---------------------------------------------------------------------+
  | CotejoAggregatorAdapter  ·  exact AggregatorV3Interface              |
  |   latestRoundData() -> rescales to the consumer's decimals           |
  |                        roundId derived from observedAt (monotonic)   |
  |                        reverts if it would round to 0 or exceed int256
  |   getRoundData()    -> ALWAYS reverts: there is no history to fake   |
  +---------------------------------------------------------------------+
        |
        v
   Consuming protocol (no code changes)


  Administrative path - never touches a price (INV-7)

   RouteGovernor --48 h--> PriceRouter.commitRoute()      (INV-4)
   RouteGovernor --48 h--> PriceRouter.unpause()          (INV-6)
   Guardian      --now---> PriceRouter.pause()            (INV-6)
```

The asymmetry in step 1 is deliberate and is the decision most often questioned: **a source
that reverts is dropped, but a source that answers with stale data reverts the whole read.** A
missing source is a missing source, and `minSources` decides whether enough remain. A source
that answers with old data is evidence that something upstream is broken, and reading past that
is how an oracle serves a number nobody should act on.

---

## The seven invariants

| ID | Invariant | Tests that prove it |
|---|---|---|
| **INV-1** | `latestPrice` reverts when fresh sources are fewer than `minSources` | `test_INV1_revertsBelowMinSources`<br>`test_INV1_passesAtExactlyMinSources`<br>`test_INV1_revertingSourceIsDroppedNotFatal`<br>`test_INV1_gasBombSourceIsContainedAndDropped` |
| **INV-2** | Reverts when the fresh set's deviation exceeds `maxDeviationBps` | `test_INV2_revertsWhenDeviationExceeded`<br>`test_INV2_deviationIsMeasuredAgainstMedianNotMin`<br>`test_INV2_passesAtExactlyMaxDeviation` |
| **INV-3** | Reverts when `block.timestamp − observedAt > maxStalenessSeconds` for **any** source in the set | `test_INV3_revertsOnStaleSource`<br>`test_INV3_oneStaleSourceRevertsEvenWithQuorumOfFreshOnes`<br>`test_INV3_passesAtExactlyMaxStaleness`<br>`test_INV3_reportsOldestObservationInTheSet` |
| **INV-4** | A route change takes effect only after `ROUTE_TIMELOCK = 48 h`, and the pending route is publicly readable for the whole wait | `test_INV4_routeChangeRequiresFullTimelock`<br>`test_INV4_pendingRouteIsPubliclyReadableForTheWholeWait`<br>`test_INV4_routeIsUnchangedWhileProposalIsPending` |
| **INV-5** | Operator independence: never more than `maxSourcesPerOperatorGroup` (default 1) per group, validated **at proposal AND at read** | `test_INV5_rejectsTwoSourcesFromSameOperator`<br>`test_INV5_revertsAtReadWhenGroupChangesAfterCommit`<br>`test_INV5_honoursMaxSourcesPerOperatorGroupAboveOne`<br>`test_CircularPricing` |
| **INV-6** | Pausing is one-way toward safety: pausing is immediate and guardian-held; unpausing takes the full timelock | `test_INV6_guardianPausesImmediately`<br>`test_INV6_unpauseRequiresFullTimelock`<br>`test_INV6_guardianCannotUnpause`<br>`test_INV6_nonGuardianCannotPause`<br>`test_INV6_pauseSurvivesRepeatedGuardianCalls` |
| **INV-7** | No administrative role can write a price. No such function exists | `test_INV7_routerExposesNoPriceWritingFunction`<br>`test_INV7_governorCannotMovePriceWithoutSources` |

`test_INV7_routerExposesNoPriceWritingFunction` scans the deployed bytecode for nine
price-writing selectors. It is structural on purpose: it fails if somebody adds a setter later,
whatever they call it.

### Scenario tests

| Test | What it reproduces |
|---|---|
| `test_TectonicScenario` | One source going 100x over 20 minutes while two stay flat. The router stops answering during the ramp and ends at exactly `Cotejo__DeviationExceeded(990_000 bps, 500)` |
| `test_TectonicScenario_downwardRunawayIsAlsoRefused` | The mirror case downward, which is the one that triggers liquidations |
| `test_CircularPricing` | Three sources sharing an `operatorGroup`. Reverts **at proposal**; it never enters the queue |
| `test_TwapDisabled_cannotBeCommittedIntoARoute` | `TwapSource` cannot be enabled by configuration, only by writing the implementation |

This is a direct answer to Tectonic (30 August 2026, $75M): a single feed ran away and the
protocol kept quoting it. [`test/market/TectonicReplay.t.sol`](test/market/TectonicReplay.t.sol)
replays it against this code.

---

## Design decisions

### D1 — Deviation is measured against the median

```
(max − min) × 10 000 / median  <=  maxDeviationBps
```

**This is not symmetric.** For the same absolute spread, the figure depends on which side the
majority sits:

| Set | Median | Spread | Deviation |
|---|---|---|---|
| `[100, 100, 200]` — low majority, **high** outlier | 100 | 100 | **10 000 bps** |
| `[100, 200, 200]` — high majority, **low** outlier | 200 | 100 | **5 000 bps** |

A downward outlier under an expensive majority is judged half as harshly, because it divides by
a larger median. That is the direction which triggers liquidations, so `maxDeviationBps`
**protects asymmetrically**, and a route should be calibrated with the downward case in mind.
Pinned as a property in `testFuzz_deviationBps_medianBaseIsAsymmetric`.

`(max − min) × 10 000` overflows above roughly 1.15e73 and reverts. That is intended: a number
like that is not a price, and failing closed is the correct answer.

### D2 — `maxStalenessSeconds >= 2 × reporterHeartbeatSeconds`

Validated when the route is configured. The deployment uses a 900 s heartbeat and 1800 s
staleness: exactly the minimum D2 permits. That is precisely what the doubling buys — the check
is `age > maxStaleness`, strict, so the window **tolerates one entire missed beat and fails on
the second consecutive one**. The heartbeat is set by the faucet budget (see `DEPLOYMENT.md`
§2), not by preference; the freshness window is a safety parameter and is not widened to
accommodate an unreliable keeper. Below the doubling, normal operation produces random reverts
and nobody understands why.

`reporterHeartbeatSeconds` lives on the `Route`, not on the source. Reading it from the source
would let a lying source declare a tiny heartbeat to pass the check.

### D3 — The entire read path is `view`

Source → router → adapter, without exception, so that `latestRoundData()` is `view`, which is
how every consumer calls it. A source that needs to write state in order to answer cannot be a
source. For a RedStone-style pull model, extraction from `msg.data` works in a `view` context;
that is documented in `IPriceSource`.

### D4 — `MAX_SOURCES_PER_ROUTE = 15`, in-memory insertion sort

O(n²) on purpose: at n <= 15 it beats every alternative on gas and is auditable at a glance. It
bounds the cost of the read, which is what matters when a liquidator calls under pressure.

### Five more, closed in review

| Decision | Resolution |
|---|---|
| A source that reverts | Dropped and counted as not fresh; `minSources` decides. 200,000 gas cap per source against 63/64 griefing |
| Median with even N | Average of the two middle values, rounded down, computed as `lo + (hi−lo)/2` so it cannot overflow |
| Returned `observedAt` | The **oldest** in the set, not the newest: the consumer measures against the weakest link |
| `getRoundData` | Reverts with `Cotejo__HistoricalDataUnavailable`. There are no rounds, and inventing one would violate fail-closed |
| Adapter precision | Reverts if rescaling would round to zero, instead of returning 0 |

---

## Dependencies

**OpenZeppelin 5.1.0**, not solmate. In order:

1. `ECDSA` rejects malleability (`s > n/2`); solmate does not cover that case the same way.
2. `EIP712` caches the domain separator with fork protection, which matters on an L2 whose
   mainnet chain id does not exist yet.
3. `Ownable2Step` avoids losing control to a typo in a transfer.
4. Whitechain's own documentation demonstrates OpenZeppelin verifying on this Blockscout (its
   reference deployment uses `@openzeppelin/contracts@5.6.1`).

**Why 5.1.0 and not 5.6.1:** OZ 5.6.1 uses `mcopy` in `Bytes.sol`, which `Math.sol` imports, and
`mcopy` is a Cancun opcode. With `evm_version = "shanghai"` the build fails. 5.1.0 is the last
release that does not use it, so it keeps the shanghai target without giving up a modern OZ.

### On `evm_version = "shanghai"`

The chain **does** support Cancun: Holocene has been active since genesis, and the
documentation's reference deployment verifies with EVM `cancun` and solc 0.8.28. Shanghai is
kept because Cotejo uses no transient storage, shanghai bytecode runs unchanged on a cancun
chain, and the older target keeps the artifacts portable to any OP Stack chain that has not yet
activated Ecotone. It is a choice, not a limit.

`v0.8.24+commit.e11b9ed9` is confirmed present in the explorer's compiler list
(`GET /api/v2/smart-contracts/verification/config`), so the contracts are verifiable.

---

## Coverage

269 tests across 24 suites. `forge coverage --no-match-coverage "(test/|script/)"`, both layers:

```
| File                                     | % Lines           | % Statements       | % Branches       | % Funcs          |
|------------------------------------------|-------------------|--------------------|------------------|------------------|
| src/PriceRouter.sol                      | 100.00% (148/148) | 99.44% (177/178)   | 97.44% (38/39)   | 100.00% (19/19)  |
| src/RouteGovernor.sol                    | 100.00% (79/79)   | 100.00% (78/78)    | 100.00% (14/14)  | 100.00% (17/17)  |
| src/adapters/CotejoAggregatorAdapter.sol | 100.00% (25/25)   | 100.00% (23/23)    | 100.00% (3/3)    | 100.00% (6/6)    |
| src/libraries/AggregationLib.sol         | 100.00% (35/35)   | 100.00% (50/50)    | 100.00% (8/8)    | 100.00% (4/4)    |
| src/market/AdaptiveCurveIrm.sol          | 92.50% (37/40)    | 94.12% (48/51)     | 100.00% (11/11)  | 83.33% (5/6)     |
| src/market/CotejoMarket.sol              | 99.56% (448/450)  | 99.25% (527/531)   | 96.70% (88/91)   | 98.25% (56/57)   |
| src/market/CotejoOracleAdapter.sol       | 98.65% (73/74)    | 96.77% (90/93)     | 90.00% (9/10)    | 100.00% (16/16)  |
| src/market/libraries/MathLib.sol         | 100.00% (19/19)   | 100.00% (23/23)    | 100.00% (0/0)    | 100.00% (8/8)    |
| src/market/libraries/SharesMathLib.sol   | 100.00% (8/8)     | 100.00% (8/8)      | 100.00% (0/0)    | 100.00% (4/4)    |
| src/sources/AttestationSource.sol        | 100.00% (73/73)   | 100.00% (76/76)    | 100.00% (18/18)  | 100.00% (17/17)  |
| src/sources/ChainlinkCompatSource.sol    | 100.00% (30/30)   | 100.00% (35/35)    | 100.00% (7/7)    | 100.00% (7/7)    |
| src/sources/TwapSource.sol               | 72.73% (8/11)     | 66.67% (4/6)       | 100.00% (0/0)    | 80.00% (4/5)     |
| Total                                    | 99.09% (983/992)  | 98.87% (1139/1152) | 97.51% (196/201) | 98.19% (163/166) |
```

**The number is 97.51 % of branches.** Branch coverage is quoted rather than line coverage
(99.09 %) or function coverage (98.19 %) because branches are the hard ones to move; quoting
either of the others alone would be selective.

This README displayed 100 % branch coverage for a while. That was the oracle-layer-only run,
taken before the market existed. It was true about what it measured and false about this
repository — the real figure at that moment was 73.63 %, with `CotejoMarket.sol`, the contract
that custodies funds, at 59.34 %.

The five missing branches are **not "not yet"**: each was traced to its caller and none is
reachable. None holds anything up; all five are defence in depth behind a check that fires
first. They are listed one by one, with the reason, in [`coverage.txt`](coverage.txt). One
documented unreachable branch says more than a percentage that averages it away.

Foundry's invariant suite runs 256 sequences x 64 calls per run over six handler actions
(report, report late, report at a different scale, outages, operator reassignment, time
passing) and recomputes the expected result directly from the sources, bypassing the router, so
the comparison is independent.

---

## Running it

```bash
forge build
forge test
forge coverage
```

Deep sweep before an audit — 10,000 fuzz runs, 1,024 invariant runs:

```bash
FOUNDRY_PROFILE=deep forge test
```

The Foundry toolchain is pinned to **1.7.1** in CI. An unpinned toolchain means a Foundry
release can turn this repository red without anybody touching it, and `forge fmt` in particular
changed its line wrapping between 1.7.1 and 1.8.3. 1.7.1 is also the version that built, tested
and deployed everything in `deployments/` and `broadcast/`, so CI verifies those artifacts with
the toolchain that produced them.

### Deploying to Whitechain Sepolia

The contracts reference one another, so order matters:

1. `PriceRouter(owner)`
2. `RouteGovernor(router, owner)`
3. `router.setGovernor(governor)` — once only; afterwards the owner loses all power over
   routing, pausing and prices
4. `governor.setGuardian(guardian, true)`
5. Deploy the sources, one `AttestationSource` per operator
6. `governor.proposeRoute(asset, route)` → wait 48 h → `executeRoute(asset)`
7. `CotejoAggregatorAdapter(router, asset, decimals, description)`

Deployment needs a TTY for the keystore password, so run it yourself rather than from CI:

```bash
forge create src/PriceRouter.sol:PriceRouter --rpc-url https://rpc.testnet.whitechain.io --account <account-name> --broadcast --verify --verifier blockscout --verifier-url https://explorer.testnet.whitechain.io/api/ --constructor-args <owner-address>
```

Three things that will cost you an afternoon otherwise:

- `--broadcast` is mandatory. Without it `forge create` only simulates, and prints something
  that looks like a real result.
- `--constructor-args` must come **last**. It is variadic and swallows every token after it.
- The Blockscout `--verifier-url` must end in **`/api/` with the trailing slash**. Hardhat uses
  `/api` without it and the two are not interchangeable.

Do not split the command across lines in PowerShell. `\` is not a line continuation there; the
backslashes become positional arguments and you get `encode length mismatch: expected 0 types,
got 2`, where "2" is the number of backslashes.

For multi-file verification, if `--verify` fails, use Blockscout's `standard-input` method.

---

## What Cotejo does not do

- **No TWAP.** `TwapSource` always reverts and `supportsAsset` returns `false`, so it cannot be
  enabled by configuration. A contract labelled `UniswapV3Pool` exists on Whitechain Sepolia
  (`0x6e057133CFa4a9Ec70c77aaFe29751460FE16307`), but with no documented factory, no published
  pool addresses and no swaps enabled on testnet, a TWAP over it is a number an attacker sets
  for the cost of moving a thin pool. At 1-second blocks, a 30-minute window is 1,800 blocks of
  a cheap position, not the deterrent it is on a 12-second chain.
- **Not upgradeable.** Immutable contracts in v1; migration happens by changing the route.
- **No token**, and no tokenised governance.
- **No flash loans**, and no cross-market collateral.
- **No admin function to change an existing market's LLTV.** Writing one would reintroduce the
  problem the isolation is there to prevent.
- **Not gas-optimised** beyond what the 15-source cap requires.
- **No contract reporters** (EIP-1271). `ECDSA.recover` derives the signer from the signature,
  and the agreed `PriceAttestation` struct carries no reporter address to validate a contract
  against.

## Known risks

| Risk | Scope | Mitigation |
|---|---|---|
| D1 asymmetry | `maxDeviationBps` is more permissive toward downward outliers | Calibrate the route for the downward case |
| The router owner can remove every guardian | Liveness, not safety: they still cannot produce a price or unpause without the 48 h | Owner on a multisig |
| A source owner controls its `operatorGroup` | Could declare false independence | INV-5 is revalidated on every read and every commit |
| `getRoundData` reverts | Breaks consumers that walk history | Deliberate; faking a history would be worse |
| Depth is self-declared | The `depthUsd` that bounds borrowing is attested by the same parties the system defends against | Unsolved. Stated in full as attack 5 in [`THREAT_MODEL.md`](THREAT_MODEL.md) |
| The keeper is one process | Five keys, one seed, one host, one venue | Unsolved by design in v1; see the section above and `keeper/README.md` |

[`THREAT_MODEL.md`](THREAT_MODEL.md) section 5 lists ten things this design does **not** cover
— nine attacks and an explicit out-of-scope list — including one that undermines its own debt
ceiling. That section is the most useful thing in this repository for anyone deciding whether
to trust it.

