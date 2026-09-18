import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  toHex,
  type Address,
  type PublicClient,
  type WalletClient,
} from "viem";
import { mnemonicToAccount } from "viem/accounts";
import {
  ASSET_NAME,
  SOURCE_COUNT,
  heartbeatSeconds,
  mnemonic,
  relayerIndex,
  whitechainSepolia,
} from "./config.js";
import type { Observation } from "./whitebit.js";

export const ASSET_ID = keccak256(toHex(ASSET_NAME));

const SOURCE_ABI = [
  {
    type: "function",
    name: "submit",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "att",
        type: "tuple",
        components: [
          { name: "asset", type: "bytes32" },
          { name: "price", type: "uint256" },
          { name: "decimals", type: "uint8" },
          { name: "observedAt", type: "uint256" },
          { name: "depthUsd", type: "uint256" },
          { name: "sourceId", type: "bytes32" },
        ],
      },
      { name: "signature", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "SOURCE_ID",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "bytes32" }],
  },
  {
    type: "function",
    name: "latestObservation",
    stateMutability: "view",
    inputs: [{ name: "asset", type: "bytes32" }],
    outputs: [
      { name: "price", type: "uint256" },
      { name: "decimals", type: "uint8" },
      { name: "observedAt", type: "uint256" },
      { name: "depthUsd", type: "uint256" },
      { name: "reporter", type: "address" },
      { name: "group", type: "bytes32" },
    ],
  },
  {
    type: "function",
    name: "isAuthorised",
    stateMutability: "view",
    inputs: [
      { name: "reporter", type: "address" },
      { name: "asset", type: "bytes32" },
    ],
    outputs: [{ type: "bool" }],
  },
] as const;

/** The EIP-712 type, matching `AttestationSource.PRICE_ATTESTATION_TYPEHASH`. */
const TYPES = {
  PriceAttestation: [
    { name: "asset", type: "bytes32" },
    { name: "price", type: "uint256" },
    { name: "decimals", type: "uint8" },
    { name: "observedAt", type: "uint256" },
    { name: "depthUsd", type: "uint256" },
    { name: "sourceId", type: "bytes32" },
  ],
} as const;

export const signers = Array.from({ length: SOURCE_COUNT }, (_, i) =>
  mnemonicToAccount(mnemonic, { addressIndex: i }),
);
export const relayer = mnemonicToAccount(mnemonic, {
  addressIndex: relayerIndex,
});

export const publicClient: PublicClient = createPublicClient({
  chain: whitechainSepolia,
  transport: http(),
});

export const walletClient: WalletClient = createWalletClient({
  account: relayer,
  chain: whitechainSepolia,
  transport: http(),
});

/** Aborts unless the RPC really is chain 1874. */
export async function assertChain(): Promise<void> {
  const id = await publicClient.getChainId();
  if (id !== whitechainSepolia.id) {
    throw new Error(
      `RPC reports chain ${id}, expected ${whitechainSepolia.id}. ` +
        `Whitechain has a second testnet on 2625 and it is not this one.`,
    );
  }
}

/**
 * Picks an `observedAt` the contract will accept.
 *
 * Three constraints have to hold at once, and they are all enforced on chain:
 * it may not be in the future relative to the block timestamp, it must be
 * strictly greater than the observation already stored, and the resulting
 * digest must not have been consumed before.
 *
 * The venue clock and the chain clock are independent and neither is
 * authoritative. Taking the venue timestamp raw is the obvious choice and it
 * fails the first time WhiteBIT's clock runs a second ahead, with
 * `Cotejo__FutureObservation` — an error that would look like a bug in the
 * oracle rather than clock skew between two machines. So: clamp to the chain,
 * then force strict progress.
 *
 * Returns `null` when no acceptable value exists, which happens when the stored
 * observation is already at or ahead of the current block. Skipping is correct
 * there; the alternative is inventing a timestamp.
 */
export function chooseObservedAt(
  venueSeconds: number,
  chainSeconds: bigint,
  storedObservedAt: bigint,
): bigint | null {
  let at = BigInt(venueSeconds);
  if (at > chainSeconds) at = chainSeconds;
  if (at <= storedObservedAt) {
    const next = storedObservedAt + 1n;
    if (next > chainSeconds) return null;
    at = next;
  }
  return at;
}

/**
 * viem wraps a revert in a long, multi-paragraph error. `shortMessage` carries
 * the useful line, including Cotejo's typed refusals, so prefer it when present
 * without pretending every Error has one.
 */
function describeError(err: unknown): string {
  if (err && typeof err === "object" && "shortMessage" in err) {
    const short = (err as { shortMessage?: unknown }).shortMessage;
    if (typeof short === "string" && short.length > 0) return short;
  }
  return err instanceof Error ? err.message : String(err);
}

export type SubmitOutcome =
  | { index: number; status: "sent"; hash: `0x${string}` }
  | { index: number; status: "skipped"; reason: string }
  | { index: number; status: "failed"; reason: string };

/**
 * Signs and relays one attestation.
 *
 * `submit` is permissionless: the signature authorises the write, the caller
 * does not. That is why one funded relayer can post for all five sources and
 * the signing keys never need a balance of their own.
 */
export async function submitOne(
  index: number,
  source: Address,
  obs: Observation,
  chainSeconds: bigint,
): Promise<SubmitOutcome> {
  const account = signers[index];

  const [sourceId, stored, authorised] = await Promise.all([
    publicClient.readContract({
      address: source,
      abi: SOURCE_ABI,
      functionName: "SOURCE_ID",
    }),
    publicClient
      .readContract({
        address: source,
        abi: SOURCE_ABI,
        functionName: "latestObservation",
        args: [ASSET_ID],
      })
      .catch(() => null), // Cotejo__NoPrice on a source that has never published.
    publicClient.readContract({
      address: source,
      abi: SOURCE_ABI,
      functionName: "isAuthorised",
      args: [account.address, ASSET_ID],
    }),
  ]);

  if (!authorised) {
    return {
      index,
      status: "skipped",
      reason:
        `${account.address} is not authorised on this source. ` +
        `Run 02_Configure with COTEJO_KEEPER_MNEMONIC set to this same seed.`,
    };
  }

  const storedObservedAt = stored ? (stored[2] as bigint) : 0n;
  const observedAt = chooseObservedAt(
    obs.observedAt,
    chainSeconds,
    storedObservedAt,
  );
  if (observedAt === null) {
    return {
      index,
      status: "skipped",
      reason: "stored observation is not older than the current block",
    };
  }

  const message = {
    asset: ASSET_ID,
    price: obs.priceWad,
    decimals: 18,
    observedAt,
    depthUsd: obs.depthUsd,
    sourceId: sourceId as `0x${string}`,
  };

  const signature = await account.signTypedData({
    domain: {
      name: "Cotejo",
      version: "1",
      chainId: whitechainSepolia.id,
      verifyingContract: source,
    },
    types: TYPES,
    primaryType: "PriceAttestation",
    message,
  });

  try {
    const hash = await walletClient.writeContract({
      address: source,
      abi: SOURCE_ABI,
      functionName: "submit",
      args: [message, signature],
      account: relayer,
      chain: whitechainSepolia,
    });
    return { index, status: "sent", hash };
  } catch (err) {
    return {
      index,
      status: "failed",
      reason: describeError(err),
    };
  }
}

export { heartbeatSeconds };
