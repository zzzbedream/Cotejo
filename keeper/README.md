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

A steady-state `submit` measured at 34,526 gas, ~61,222 as a transaction. Five
sources on one pair at a 900 s heartbeat is 480 submits/day ≈ **0.147 WBT/day**
at the 5 gwei floor, plus an L1 data fee measured at 0.11 % of that. Fund the
relayer accordingly.

## Failure behaviour

The keeper never substitutes a value it did not get. If WhiteBIT is unreachable,
or the book is thinner than the configured floor, it logs and skips the cycle.
Missing a heartbeat is survivable — `maxStalenessSeconds` is twice the heartbeat,
so the route tolerates exactly one missed beat and refuses on the second. Posting
a made-up price to avoid the gap would defeat the entire system.
