# Cotejo keeper

One process. Five signatures. **Not a reporter fleet, and this document will not
call it one.**

The keeper reads the WhiteBIT order book, derives five keys from a single
mnemonic, signs five EIP-712 attestations with them, and relays those to the
five `AttestationSource` contracts on Whitechain Sepolia.

## What this is not

Cotejo's oracle is built on the premise that independent operators disagree
before they are wrong together. INV-5 enforces one source per operator group,
and R2 requires three distinct groups before a lending market may be created.
Those rules are real and the contracts enforce them.

**This process satisfies them nominally and not actually.** Five keys derived
from one seed, running in one process, reading one venue, on one machine, are
one operator with five addresses. A single compromised host, a single bad price
from WhiteBIT, or a single bug in this file moves all five sources at once —
which is precisely the correlated failure the deviation check cannot catch,
because there is nothing left to disagree with it.

### Measured, not asserted

The first live cycle, 18 September 2026, wrote this to all five sources:

```
price      83.348500000000000000   (identical on all five, bit for bit)
depthUsd   668760                  (identical)
observedAt 1789770763              (identical)
deviation  0.00 bps                route tolerance: 200 bps
```

That zero is the whole argument, on chain and checkable. INV-2 rejects a set
whose spread exceeds the route tolerance, and it will never fire here, because
five signatures over one number cannot disagree with each other. The invariant
is not broken — it is idle, and it will stay idle until the five prices come
from five places.

So the honest reading of a healthy panel today is narrow: it shows the
aggregation, staleness, quorum and operator-concentration checks running against
real data, and it does not show the deviation check doing anything, because
there is nothing for it to catch.

Nothing here is hidden from the chain: the on-chain operator groups are named
`cotejo-keeper-1` … `cotejo-keeper-5`, which claim no venue and imply no
relationship with anyone. Replacing this with genuinely independent operators is
the work; this is the placeholder that lets the rest be tested.

## Price and depth

Both come from one endpoint, verified against the live API rather than assumed:

```
GET https://whitebit.com/api/v4/public/orderbook/WBT_USDT?limit=100
```

Documented at `docs.whitebit.com/api-reference/market-data/orderbook`. Rate
limit 600 requests / 10 s, response cached 100 ms. The keeper uses one request
per cycle.

- **Price** is the mid of best bid and best ask.
- **Depth** is the notional within ±1 % of mid, taking the **thinner of the two
  sides**. That is the side that binds: unwinding collateral sells into bids,
  and the market's borrow ceiling should be set by whichever side would run out
  first. Measured on 2026-09-18: ±1 % gave $627k on the thin side against a
  $250k configured floor.

**`WBT_USDT` is not `WBT/USD`.** The oracle prices `WBT/USD` and this feeds it a
USDT quote. On testnet that is an acceptable stand-in and it is stated here
rather than papered over; a production route would price USDT/USD separately and
compose, which is exactly what `CotejoOracleAdapter` already does for the
market's two legs.

## Setup

```bash
cd keeper
npm install
```

Environment, read from the repository root `.env`:

| Variable | Meaning |
|---|---|
| `COTEJO_KEEPER_MNEMONIC` | Seed for the five signing keys. The same seed `02_Configure` authorised. |
| `COTEJO_RELAYER_INDEX` | Derivation index of the account that pays gas. Default 100. |
| `COTEJO_HEARTBEAT_SECONDS` | Publish cadence. Default 900, matching the route. |

The relayer needs WBT. `submit` is permissionless — the signature authorises the
write, not the caller — so one funded account relays all five attestations and
the signing keys never need a balance.

```bash
npm run addresses    # prints the five reporter addresses and the relayer
npm start            # runs the loop
npm run once         # one cycle, then exit. Use this first.
```

## Cost

A steady-state `submit` measured at 34,526 gas, ~61,222 as a transaction, at the
5 gwei floor, plus an L1 data fee measured at 0.11 % of that. Five sources on one
pair at the 900 s heartbeat is 480 submits/day, about **0.147 WBT/day**. The
relayer held 7.99 WBT on 19 September, roughly 54 days.

## Where it runs

`npm start` in a terminal is the wrong answer for anything that has to stay up:
it dies with the SSH session, the laptop lid, or the first Windows update. Live,
it runs on GitHub - [`.github/workflows/keeper.yml`](../.github/workflows/keeper.yml).

### What the first night measured

The first version of that workflow asked GitHub's scheduler for the heartbeat: a
ten-minute cron, one cycle per run. Over the first night it fired **once in 4
hours 48 minutes**, and the last observation on chain was **2h44m old against a
1800-second tolerance** - stale by more than five times. Scheduled workflows are
documented as best-effort, and for short intervals that means dropped, not
delayed.

The number is recorded here because the conclusion is not obvious in advance and
is easy to assume away: "best-effort with delays" sounded like minutes. It was
hours, and the whole point of this process is a gap that never opens.

### What replaced it

The scheduler is no longer asked for a heartbeat. It is asked for a **restart**.
One process runs for 5h45m driving its own 900-second cadence, and the cron -
hourly, at :13, off the top of the hour where every cron on the platform fires
at once - only has to land once inside that window. The concurrency group queues
the next run behind the current one, so when a process reaches its budget the
waiting run takes over.

That is a much weaker dependency: one fire per 5h45m against a measured rate of
one per 4h48m. It is not a guarantee. If GitHub drops fires for six hours
straight there is a gap, and the honest description of this arrangement is
"good enough to demonstrate, not good enough to depend on". The real fix is a
process that does not live inside someone else's build system.

### Setup

| Where | Name | Value |
|---|---|---|
| Secrets → Actions | `COTEJO_KEEPER_MNEMONIC` | the same seed `02_Configure` authorised |
| Variables → Actions | `COTEJO_RELAYER_INDEX` | optional; defaults to 100 |

Then **Actions → Keeper → Run workflow** once by hand. A manual run tells you
whether the secret is readable without waiting on the cron to find out.

Set `COTEJO_RUN_SECONDS` to bound a process's lifetime; unset, `npm start` loops
forever, which is what you want locally and not what you want inside a job
GitHub kills at six hours.

Two costs of this arrangement, neither of them hidden:

- **The signing seed lives in GitHub's secret store.** GitHub, and anyone with
  write access to this repository, can then publish prices as all five sources.
  That is the trust anchor of the oracle sitting in a third party's database. It
  is acceptable because the seed has never held anything but faucet WBT; it
  would not be with value behind the feed, and the fix is not a better secret
  store, it is five operators who each hold their own key.
- Scheduled workflows are **disabled automatically after 60 days** without
  repository activity. Within a three-week window that is not a concern, but it
  is the reason this is a bridge and not an architecture.

Public repositories get unmetered Actions minutes, so the hosting is free. On a
private repository a 5h45m job every 5h45m would exhaust the 2,000-minute
monthly allowance in about six days.

A cycle that publishes nothing is logged, and a process where **no** cycle
published exits non-zero. A scheduled runner reports success by exit status, so
a green run that wrote no price would be exactly the false uptime signal this
repo refuses everywhere else.

## Failure behaviour

The keeper never substitutes a value it did not get. If WhiteBIT is unreachable,
or the book is thinner than the configured floor, it logs and skips the cycle.
Missing a heartbeat is survivable — `maxStalenessSeconds` is twice the heartbeat,
so the route tolerates exactly one missed beat and refuses on the second. Posting
a made-up price to avoid the gap would defeat the entire system.
