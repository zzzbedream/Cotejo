import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { defineChain } from "viem";

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, "..", "..");

/**
 * Loads the repository-root `.env` without a dependency.
 *
 * Deliberately does not overwrite a variable already present in the real
 * environment: a value passed on the command line should win over a stale line
 * in a file nobody remembers editing.
 */
function loadEnv(): void {
  let raw: string;
  try {
    raw = readFileSync(resolve(repoRoot, ".env"), "utf8");
  } catch {
    return; // No .env is fine; the variables may come from the environment.
  }
  for (const line of raw.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eq = trimmed.indexOf("=");
    if (eq < 1) continue;
    const key = trimmed.slice(0, eq).trim();
    let value = trimmed.slice(eq + 1).trim();

    // A mnemonic has spaces in it, so people quote it, and `foundry` strips the
    // quotes while a naive reader does not. Leaving them in produces a valid
    // BIP-39 failure several layers down, which reads as "my seed is wrong"
    // rather than "there are quote marks in my seed".
    if (value.length >= 2) {
      const first = value[0];
      const last = value[value.length - 1];
      if ((first === '"' && last === '"') || (first === "'" && last === "'")) {
        value = value.slice(1, -1);
      }
    }

    if (!value) continue;
    if (process.env[key] === undefined) process.env[key] = value;
  }
}
loadEnv();

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`${name} is not set. See keeper/README.md.`);
  return v;
}

/**
 * Chain 1874, not 2625.
 *
 * `viem/chains` exports both `whitechainSepolia` (1874) and `whitechainTestnet`
 * (2625), and they are different networks. The chain is defined here rather
 * than imported so that picking the wrong one is not one autocomplete away, and
 * the id is asserted against the RPC before anything is signed.
 */
export const whitechainSepolia = defineChain({
  id: 1874,
  name: "Whitechain Sepolia",
  nativeCurrency: { name: "WBT", symbol: "WBT", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.testnet.whitechain.io"] } },
  blockExplorers: {
    default: {
      name: "Blockscout",
      url: "https://explorer.testnet.whitechain.io",
    },
  },
});

/** Deployment state, read from the file the scripts maintain. */
type State = {
  contracts: Record<string, `0x${string}`>;
};

export function loadDeployment(): {
  sources: `0x${string}`[];
  router: `0x${string}`;
} {
  const path = resolve(repoRoot, "deployments", "1874.json");
  const state = JSON.parse(readFileSync(path, "utf8")) as State;

  const sources: `0x${string}`[] = [];
  for (let i = 1; i <= SOURCE_COUNT; i++) {
    const addr = state.contracts[`AttestationSource_cotejo-keeper-${i}`];
    if (!addr || /^0x0+$/.test(addr)) {
      throw new Error(
        `AttestationSource_cotejo-keeper-${i} is missing from ${path}. Run 01_Deploy first.`,
      );
    }
    sources.push(addr);
  }
  return { sources, router: state.contracts.PriceRouter };
}

export const SOURCE_COUNT = 5;

/** The pair the oracle prices, and the WhiteBIT market standing in for it. */
export const ASSET_NAME = "WBT/USD";
export const WHITEBIT_MARKET = "WBT_USDT";

/**
 * Half-width of the band the depth figure is measured over, in basis points.
 *
 * Wider reads as more depth, which permits more debt, so this is a risk
 * parameter and not a display choice. 100 bps against a book whose spread is
 * well under a basis point leaves the thin side around 2.5x the configured
 * floor, measured 2026-09-18.
 */
export const DEPTH_BAND_BPS = 100;

export const mnemonic = required("COTEJO_KEEPER_MNEMONIC");
export const relayerIndex = Number(process.env.COTEJO_RELAYER_INDEX ?? 100);
export const heartbeatSeconds = Number(
  process.env.COTEJO_HEARTBEAT_SECONDS ?? 900,
);
