import {
  createPublicClient, createWalletClient, http,
  parseAbi,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { callClaude } from "../llm.js";
import { COORDINATOR_PROMPT } from "../prompts/loader.js";
import { chainFor } from "../chains.js";
import { extractJson } from "../utils/parseJson.js";
import type { MirrorState, CoordinatorDecision } from "../state.js";

const mirrorHookAbi = parseAbi([
  "function dispatchRebalance(int128 deltaToken0, int128 deltaToken1, uint24 newFee, int24 tickLower, int24 tickUpper) external payable",
]);

// 8.5.9 — Home-chain auto-LP path. Calls Relayer.provideLiquidity directly
// without going through Hyperlane. Used when the proposal's target chain is
// the home chain (Base today). Sister-chain proposals still use the
// hook.dispatchRebalance + Hyperlane path.
const relayerAbi = parseAbi([
  "function provideLiquidity(bytes32 pairId, int128 deltaToken0, int128 deltaToken1, int24 tickLower, int24 tickUpper) external",
]);

function normalizePrivateKey(pk: string | undefined): `0x${string}` {
  if (!pk) throw new Error("AGENT_PRIVATE_KEY not set");
  return (pk.startsWith("0x") ? pk : `0x${pk}`) as `0x${string}`;
}

export async function runCoordinatorAgent(state: MirrorState): Promise<Partial<MirrorState>> {
  const proposal = state.rebalanceProposal;

  if (!proposal || proposal.action === "none") {
    return {
      coordinatorDecision: {
        approved: false,
        reasoning: "No rebalance proposed",
        executeNow: false,
      },
    };
  }

  const prompt = `Rebalance proposal to validate:
${JSON.stringify(proposal, null, 2)}

Monitor results:
${JSON.stringify(Object.values(state.monitorResults), null, 2)}

Cycle: ${state.cycle}
Last execution result: ${JSON.stringify(state.executionResult)}

Run all validation checks. Encode the Hyperlane payload if approved.
Output the CoordinatorDecision JSON only — no other text.`;

  let decision: CoordinatorDecision;
  try {
    const response = await callClaude({
      system:     COORDINATOR_PROMPT,
      user:       prompt,
      maxTokens:  1024,
      agentLabel: "coordinator",
    });
    decision = extractJson<CoordinatorDecision>(response);
    console.log(`  [coordinator] approved=${decision.approved} executeNow=${decision.executeNow} reasoning="${(decision.reasoning ?? '').slice(0, 80)}"`);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return {
      coordinatorDecision: {
        approved: false,
        reasoning: `Coordinator parse error: ${msg.slice(0, 150)}`,
        executeNow: false,
      },
    };
  }

  if (decision.approved && decision.executeNow && state.riskAssessment?.veto === false) {
    // 8.5.3 — tick recenter is a LOCAL LP-range adjustment (no cross-chain
    // movement). The on-chain dispatch path (`hook.dispatchRebalance`) fires
    // a cross-chain Hyperlane message, which is wrong for a local recenter.
    // For now we record the intent but don't broadcast; a follow-up contract
    // change will add a local `recenterLocal(int24,int24)` entry point.
    if (proposal.action === "recenter") {
      console.log(`  [coordinator] recenter proposed on ${proposal.recenterChain ?? "?"} (range [${proposal.newTickLower}, ${proposal.newTickUpper}]) — execution path is a contract-level TODO (8.5.3). Recording intent only.`);
      return {
        coordinatorDecision: decision,
        executionResult: {
          success: true,
          timestamp: Date.now(),
          error: "recenter execution path not yet on-chain — intent recorded",
        },
      };
    }
    // 8.5.9 — Pick the execution path based on the target chain. Home-chain
    // (Base) actions go to Relayer.provideLiquidity directly. Sister-chain
    // actions go through hook.dispatchRebalance + Hyperlane.
    const targetIsHome = proposal.toChains?.[0] === "base" || proposal.fromChain === "base";
    const homeRelayer = process.env.RELAYER_BASE;
    const result = (targetIsHome && homeRelayer)
      ? await _executeHomeChainLp(homeRelayer, proposal)
      : await _executeOnChain(decision, proposal);
    return { coordinatorDecision: decision, executionResult: result };
  }

  return { coordinatorDecision: decision };
}

async function _executeOnChain(
  _decision: CoordinatorDecision,
  proposal: NonNullable<MirrorState["rebalanceProposal"]>
) {
  try {
    const account = privateKeyToAccount(normalizePrivateKey(process.env.AGENT_PRIVATE_KEY));
    const hookAddress = process.env.MIRROR_HOOK_BASE as Address;
    if (!hookAddress) throw new Error("MIRROR_HOOK_BASE not set");

    // chainFor() picks baseSepolia when NETWORK=sepolia so chainId matches RPC.
    // Critical for walletClient — txs would sign with chainId 8453 but submit to
    // 84532 and bounce as "invalid chain ID".
    const baseChain    = chainFor("base");
    const publicClient = createPublicClient({ chain: baseChain, transport: http(process.env.ALCHEMY_BASE_URL) });
    const walletClient = createWalletClient({ account, chain: baseChain, transport: http(process.env.ALCHEMY_BASE_URL) });

    // dispatchRebalance uses the hook's canonicalPairId internally — no pairId arg.
    // try/catch wrapping inside _dispatchToAllSisters makes the mailbox call
    // gas-hungry; raise the simulated gas budget so it doesn't OOG on broadcast.
    const { request } = await publicClient.simulateContract({
      account,
      address: hookAddress,
      abi: mirrorHookAbi,
      functionName: "dispatchRebalance",
      args: [
        BigInt(proposal.deltaToken0 ?? "0"),
        BigInt(proposal.deltaToken1 ?? "0"),
        proposal.newFee ?? 3000,
        proposal.newTickLower ?? -60,
        proposal.newTickUpper ?? 60,
      ],
      value: 0n,
      gas: 1_000_000n,
    });

    const txHash = await walletClient.writeContract(request);
    console.log(`[Coordinator] dispatchRebalance tx: ${txHash}`);

    return { success: true, txHash, timestamp: Date.now() };
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    console.error("[Coordinator] execution failed:", error);
    return { success: false, error, timestamp: Date.now() };
  }
}

/// 8.5.9 — home-chain LP provider path. Calls Relayer.provideLiquidity
/// directly (no Hyperlane). Used when the proposed action's target is Base.
/// Pulls the canonical pair id from env so the Relayer's pool registry lookup
/// matches what the hook + factory recorded.
async function _executeHomeChainLp(
  homeRelayer: string,
  proposal: NonNullable<MirrorState["rebalanceProposal"]>
) {
  try {
    const account = privateKeyToAccount(normalizePrivateKey(process.env.AGENT_PRIVATE_KEY));
    const baseChain    = chainFor("base");
    const publicClient = createPublicClient({ chain: baseChain, transport: http(process.env.ALCHEMY_BASE_URL) });
    const walletClient = createWalletClient({ account, chain: baseChain, transport: http(process.env.ALCHEMY_BASE_URL) });

    // The Relayer's registerPool stored the canonical pair id; we send it back
    // here. The factory's pair id is what got registered.
    const pairId = (process.env.CANONICAL_PAIR_ID ??
      "0x7a00c543412ae44415418950dc1ea26ae8977c50cbcec8035a5d99a911085b04") as `0x${string}`;

    const { request } = await publicClient.simulateContract({
      account,
      address: homeRelayer as Address,
      abi: relayerAbi,
      functionName: "provideLiquidity",
      args: [
        pairId,
        BigInt(proposal.deltaToken0 ?? "0"),
        BigInt(proposal.deltaToken1 ?? "0"),
        proposal.newTickLower ?? -60,
        proposal.newTickUpper ?? 60,
      ],
      gas: 800_000n,
    });

    const txHash = await walletClient.writeContract(request);
    console.log(`[Coordinator] provideLiquidity (home chain) tx: ${txHash}`);

    return { success: true, txHash, timestamp: Date.now() };
  } catch (err) {
    const error = err instanceof Error ? err.message : String(err);
    console.error("[Coordinator] home-chain LP execution failed:", error);
    return { success: false, error, timestamp: Date.now() };
  }
}
