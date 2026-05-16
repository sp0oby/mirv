import { ChatAnthropic } from "@langchain/anthropic";
import { HumanMessage, SystemMessage } from "@langchain/core/messages";
import {
  createPublicClient, createWalletClient, http,
  parseAbi, encodeAbiParameters, parseAbiParameters,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { COORDINATOR_PROMPT } from "../prompts/loader.js";
import type { MirrorState, CoordinatorDecision } from "../state.js";

const mirrorHookAbi = parseAbi([
  "function dispatchRebalance(bytes32 pairId, int128 deltaToken0, int128 deltaToken1, uint24 newFee, int24 tickLower, int24 tickUpper) external payable",
]);

const llm = new ChatAnthropic({
  model: "claude-opus-4-7",
  apiKey: process.env.ANTHROPIC_API_KEY,
  temperature: 0,
  maxTokens: 1024,
});

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
Output the CoordinatorDecision JSON.`;

  const response = await llm.invoke([
    new SystemMessage(COORDINATOR_PROMPT),
    new HumanMessage(prompt),
  ]);

  const content = typeof response.content === "string"
    ? response.content
    : JSON.stringify(response.content);

  let decision: CoordinatorDecision;
  try {
    const match = content.match(/\{[\s\S]*\}/);
    decision = JSON.parse(match?.[0] ?? content) as CoordinatorDecision;
  } catch {
    return {
      coordinatorDecision: {
        approved: false,
        reasoning: `Parse error: ${content.slice(0, 200)}`,
        executeNow: false,
      },
    };
  }

  // Execute on-chain if approved, risk is green, and execute_now=true
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
    const account = privateKeyToAccount(process.env.AGENT_PRIVATE_KEY as `0x${string}`);
    const hookAddress = process.env.MIRROR_HOOK_BASE as Address;

    const publicClient = createPublicClient({ chain: base, transport: http(process.env.ALCHEMY_BASE_URL) });
    const walletClient = createWalletClient({ account, chain: base, transport: http(process.env.ALCHEMY_BASE_URL) });

    const pairId = encodeAbiParameters(
      parseAbiParameters("bytes32"),
      [("0x" + "0".repeat(64)) as `0x${string}`]
    ); // Replace with real keccak of pair

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
