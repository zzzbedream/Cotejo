import { parseUnits } from "viem";
import { DEPTH_BAND_BPS, WHITEBIT_MARKET } from "./config.js";

const ORDERBOOK_URL = `https://whitebit.com/api/v4/public/orderbook/${WHITEBIT_MARKET}?limit=100`;

type OrderbookResponse = {
  ticker_id: string;
  timestamp: number;
  asks: [string, string][];
  bids: [string, string][];
};

export type Observation = {
  /** Mid price, scaled to 18 decimals. */
  priceWad: bigint;
  /** Whole USD of notional on the thinner side within the band. */
  depthUsd: bigint;
  /** Venue timestamp, seconds. */
  observedAt: number;
  /** For logging only. */
  midHuman: number;
  spreadBps: number;
};

export async function readBook(signal?: AbortSignal): Promise<Observation> {
  const res = await fetch(ORDERBOOK_URL, { signal });
  if (!res.ok) {
    throw new Error(`WhiteBIT orderbook returned HTTP ${res.status}`);
  }
  const body = (await res.json()) as OrderbookResponse;

  const bids = body.bids ?? [];
  const asks = body.asks ?? [];
  if (bids.length === 0 || asks.length === 0) {
    throw new Error("WhiteBIT orderbook came back with an empty side");
  }

  // The price is carried in BigInt the whole way. `Number(price) * 1e18` looks
  // like the obvious conversion and silently loses precision: 83.378e18 is far
  // past 2^53, so the last four digits of the attested price would be whatever
  // the float rounded to. The API hands back decimal strings, so parse those.
  const bestBidWad = parseUnits(bids[0][0], 18);
  const bestAskWad = parseUnits(asks[0][0], 18);

  if (bestBidWad <= 0n || bestAskWad <= 0n) {
    throw new Error("WhiteBIT orderbook came back with a non-positive top level");
  }
  if (bestAskWad < bestBidWad) {
    // A crossed book means the snapshot is inconsistent, not that there is an
    // arbitrage. Refusing is cheaper than reasoning about which side is stale.
    throw new Error(
      `WhiteBIT orderbook is crossed: bid ${bids[0][0]} > ask ${asks[0][0]}`,
    );
  }

  const priceWad = (bestBidWad + bestAskWad) / 2n;

  // Depth is whole USD, order 1e6, so doubles are exact enough here and the
  // band arithmetic stays readable. It is floored, never rounded up.
  const mid = Number(bids[0][0]) / 2 + Number(asks[0][0]) / 2;
  const band = (mid * DEPTH_BAND_BPS) / 10_000;

  let bidNotional = 0;
  for (const [priceStr, qtyStr] of bids) {
    const price = Number(priceStr);
    if (price < mid - band) break; // bids arrive descending
    bidNotional += price * Number(qtyStr);
  }
  let askNotional = 0;
  for (const [priceStr, qtyStr] of asks) {
    const price = Number(priceStr);
    if (price > mid + band) break; // asks arrive ascending
    askNotional += price * Number(qtyStr);
  }

  // The thinner side is the one that binds a liquidation, so it is the one the
  // borrow ceiling should be derived from.
  const depth = Math.min(bidNotional, askNotional);

  return {
    priceWad,
    depthUsd: BigInt(Math.floor(depth)),
    observedAt: body.timestamp,
    midHuman: mid,
    spreadBps: ((Number(asks[0][0]) - Number(bids[0][0])) / mid) * 10_000,
  };
}
