import { formatEther } from "viem";
import { heartbeatSeconds, loadDeployment, runSeconds } from "./config.js";
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

/** Runs one pass over every source and reports how many attestations landed. */
async function cycle(): Promise<number> {
  const obs = await readBook();
  const block = await publicClient.getBlock();

  log(
    `book: mid ${obs.midHuman.toFixed(4)} USDT  spread ${obs.spreadBps.toFixed(2)} bps  ` +
      `depth $${obs.depthUsd.toLocaleString("en-US")}  venue t=${obs.observedAt}`,
  );

  // Sequential, not Promise.all. The relayer is one account with one nonce, and
  // five concurrent writes would race for it; the public RPC also caps at
  // 50 req/s and this process shares that budget with the panel.
  let sent = 0;
  for (let i = 0; i < sources.length; i++) {
    const out = await submitOne(i, sources[i], obs, block.timestamp);
    if (out.status === "sent") {
      sent++;
      log(`  keeper-${i + 1} sent    ${out.hash}`);
    } else if (out.status === "skipped") {
      log(`  keeper-${i + 1} skipped ${out.reason}`);
    } else {
      log(`  keeper-${i + 1} FAILED  ${out.reason}`);
    }
  }
  return sent;
}

async function main(): Promise<void> {
  const once = process.argv.includes("--once");
  const addressesOnly = process.argv.includes("--addresses");

  await assertChain();
  await printAddresses();
  if (addressesOnly) return;

  const budget = once ? "single cycle" : runSeconds > 0 ? `${runSeconds}s budget` : "looping";
  log(`heartbeat ${heartbeatSeconds}s over ${sources.length} sources (${budget})`);

  const startedAt = Date.now();
  let cycles = 0;
  let published = 0;

  for (;;) {
    let sent = 0;
    try {
      sent = await cycle();
    } catch (err) {
      // A failed cycle is survivable and a fabricated price is not. The route
      // tolerates exactly one missed beat before it starts refusing, which is
      // the correct outcome: a stale-price refusal is information, a made-up
      // number is a lie the whole system is built to prevent.
      log(`cycle failed, skipping: ${err instanceof Error ? err.message : err}`);
    }
    cycles++;
    if (sent > 0) published++;
    else log("nothing landed this cycle");

    if (once) {
      // A scheduled runner reports success by exit status, and a green run that
      // wrote no price is a false uptime signal — the one claim this repo
      // cannot afford to make by accident. So a cycle that published nothing
      // exits non-zero and shows up red in the run history.
      if (sent === 0) process.exit(1);
      return;
    }
    // Stop while there is still time for a whole heartbeat, so the process
    // ends on its own terms rather than being killed mid-submit by the job
    // timeout - a run cancelled that way is recorded as a failure and would
    // pollute the very uptime history it exists to produce.
    if (runSeconds > 0) {
      const elapsed = (Date.now() - startedAt) / 1000;
      if (runSeconds - elapsed <= heartbeatSeconds) {
        log(`published ${published}/${cycles} cycles in ${Math.round(elapsed)}s; budget spent`);
        if (published === 0) process.exit(1);
        return;
      }
    }
    await new Promise((r) => setTimeout(r, heartbeatSeconds * 1000));
  }
}

main().catch((err) => {
  log(`fatal: ${err instanceof Error ? err.message : err}`);
  process.exit(1);
});
