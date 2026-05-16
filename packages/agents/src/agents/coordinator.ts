import {
  createPublicClient, createWalletClient, http,
  parseAbi, encodeAbiParameters, parseAbiParameters,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { callClaude } from "../llm.js";
import { COORDINATOR_PROMPT } from "../prompts/loader.js";
import type { MirrorState, CoordinatorDecision } from "../state.js";

const mirrorHookAbi = parseAbi([
  "function dispatchRebalance(bytes32 pairId, int128 deltaToken0, int128 deltaToken1, uint24 newFee, int24 tickLower, int24 tickUpper) external payable",
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
    const match = response.match(/\{[\s\S]*\}/);
    decision = JSON.parse(match?.[0] ?? response) as CoordinatorDecision;
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
    const result = await _executeOnChain(decision, proposal);
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

    const publicClient = createPublicClient({ chain: base, transport: http(process.env.ALCHEMY_BASE_URL) });
    const walletClient = createWalletClient({ account, chain: base, transport: http(process.env.ALCHEMY_BASE_URL) });

    const pairId = encodeAbiParameters(
      parseAbiParameters("bytes32"),
      [("0x" + "0".repeat(64)) as `0x${string}`]
    );

    const { request } = await publicClient.simulateContract({
      account,
      address: hookAddress,
      abi: mirrorHookAbi,
      functionName: "dispatchRebalance",
      args: [
        pairId as unknown as `0x${string}`,
        BigInt(proposal.deltaToken0 ?? "0"),
        BigInt(proposal.deltaToken1 ?? "0"),
        proposal.newFee ?? 3000,
        proposal.newTickLower ?? -60,
        proposal.newTickUpper ?? 60,
      ],
      value: 0n,
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
