import { formatEther } from "viem";
import { heartbeatSeconds, loadDeployment } from "./config.js";
import {
  assertChain,
  publicClient,
  relayer,
  signers,
  submitOne,
} from "./attest.js";
import { readBook } from "./whitebit.js";

const { sources } = loadDeployment();

function stamp(): string {
  return new Date().toISOString().replace("T", " ").slice(0, 19);
}

function log(msg: string): void {
  process.stdout.write(`[${stamp()}] ${msg}\n`);
}

async function printAddresses(): Promise<void> {
  log("Keeper signing keys — one process, five signatures, all ours.");
  signers.forEach((s, i) => log(`  cotejo-keeper-${i + 1}  ${s.address}`));
  const balance = await publicClient.getBalance({ address: relayer.address });
  log(`  relayer            ${relayer.address}  ${formatEther(balance)} WBT`);
  if (balance === 0n) {
    log("  [WARN] the relayer holds nothing and cannot pay for a single submit.");
  }
}

async function cycle(): Promise<void> {
  const obs = await readBook();
  const block = await publicClient.getBlock();

  log(
    `book: mid ${obs.midHuman.toFixed(4)} USDT  spread ${obs.spreadBps.toFixed(2)} bps  ` +
      `depth $${obs.depthUsd.toLocaleString("en-US")}  venue t=${obs.observedAt}`,
  );

  // Sequential, not Promise.all. The relayer is one account with one nonce, and
  // five concurrent writes would race for it; the public RPC also caps at
  // 50 req/s and this process shares that budget with the panel.
  for (let i = 0; i < sources.length; i++) {
    const out = await submitOne(i, sources[i], obs, block.timestamp);
    if (out.status === "sent") {
      log(`  keeper-${i + 1} sent    ${out.hash}`);
    } else if (out.status === "skipped") {
      log(`  keeper-${i + 1} skipped ${out.reason}`);
    } else {
      log(`  keeper-${i + 1} FAILED  ${out.reason}`);
    }
  }
}

async function main(): Promise<void> {
  const once = process.argv.includes("--once");
  const addressesOnly = process.argv.includes("--addresses");

  await assertChain();
  await printAddresses();
  if (addressesOnly) return;

  log(
    `heartbeat ${heartbeatSeconds}s over ${sources.length} sources ` +
      `(${once ? "single cycle" : "looping"})`,
  );

  for (;;) {
    try {
      await cycle();
    } catch (err) {
      // A failed cycle is survivable and a fabricated price is not. The route
      // tolerates exactly one missed beat before it starts refusing, which is
      // the correct outcome: a stale-price refusal is information, a made-up
      // number is a lie the whole system is built to prevent.
      log(`cycle failed, skipping: ${err instanceof Error ? err.message : err}`);
    }
    if (once) return;
    await new Promise((r) => setTimeout(r, heartbeatSeconds * 1000));
  }
}

main().catch((err) => {
  log(`fatal: ${err instanceof Error ? err.message : err}`);
  process.exit(1);
});
