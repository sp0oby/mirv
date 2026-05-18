// Centralized viem chain object resolution.
//
// Each createPublicClient / createWalletClient in mirv needs a viem chain
// object. When NETWORK=sepolia the testnet RPC URLs are wired but the chain
// object still has to match — otherwise viem signs transactions with the wrong
// chainId (e.g. wallet signs Base mainnet 8453 → submits to Base Sepolia 84532
// → tx rejected as "invalid chain ID"), and multicall3 routing can hit the
// wrong contract address.
//
// Always import chain objects from this helper, NEVER inline `chain: base`
// or `chain: mainnet` in agent code.

import { mainnet, base, bsc, sepolia, baseSepolia } from "viem/chains";
import type { Chain } from "viem/chains";

const NETWORK = process.env.NETWORK ?? "mainnet";
const IS_SEPOLIA = NETWORK === "sepolia";

export type ChainKey = "ethereum" | "base" | "bnb";

/** Resolves the right viem chain object based on the NETWORK env. */
export function chainFor(name: ChainKey): Chain {
  if (IS_SEPOLIA) {
    if (name === "ethereum") return sepolia;
    if (name === "base") return baseSepolia;
    // BNB has no first-class viem Sepolia equivalent — return mainnet bsc as fallback
    // (BNB testnet is unsupported in mirv at launch; flag exists only for post-launch enablement).
    return bsc;
  }
  if (name === "ethereum") return mainnet;
  if (name === "base") return base;
  return bsc;
}

/** Strict check used in tests + boot logs to surface misconfiguration early. */
export function isSepolia(): boolean {
  return IS_SEPOLIA;
}
