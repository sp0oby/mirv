import {
  createPublicClient,
  createWalletClient,
  http,
  parseAbi,
  type Address,
  encodeAbiParameters,
  parseAbiParameters,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { mainnet, base, bsc } from "viem/chains";
import { tool } from "@langchain/core/tools";
import { z } from "zod";

const MAILBOXES: Record<string, Address> = {
  ethereum: (process.env.HYPERLANE_MAILBOX_MAINNET ?? "0x0") as Address,
  base:     (process.env.HYPERLANE_MAILBOX_BASE    ?? "0x0") as Address,
  bnb:      (process.env.HYPERLANE_MAILBOX_BNB     ?? "0x0") as Address,
};

const CHAIN_CONFIGS = {
  ethereum: { chain: mainnet, rpc: process.env.ALCHEMY_MAINNET_URL },
  base:     { chain: base,    rpc: process.env.ALCHEMY_BASE_URL },
  bnb:      { chain: bsc,     rpc: process.env.ALCHEMY_BNB_URL },
} as const;

const mailboxAbi = parseAbi([
  "function quoteDispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody) external view returns (uint256 fee)",
  "function dispatch(uint32 destinationDomain, bytes32 recipientAddress, bytes calldata messageBody) external payable returns (bytes32 messageId)",
]);

// ─── Tool: estimateHyperlaneFee ───────────────────────────────────────────────
export const estimateHyperlaneFee = tool(
  async ({ sourceChain, destinationDomain, recipientAddress, messageBodyHex }) => {
    const cfg    = CHAIN_CONFIGS[sourceChain as keyof typeof CHAIN_CONFIGS];
    const client = createPublicClient({ chain: cfg.chain, transport: http(cfg.rpc) });
    const mb     = MAILBOXES[sourceChain];

    const fee = await client.readContract({
      address: mb,
      abi: mailboxAbi,
      functionName: "quoteDispatch",
      args: [destinationDomain, recipientAddress as `0x${string}`, messageBodyHex as `0x${string}`],
    });

    return { sourceChain, destinationDomain, feeWei: fee.toString(), feeEth: Number(fee) / 1e18 };
  },
  {
    name: "estimateHyperlaneFee",
    description: "Quote the ETH cost to dispatch a Hyperlane cross-chain message",
    schema: z.object({
      sourceChain:      z.enum(["ethereum", "base", "bnb"]),
      destinationDomain: z.number(),
      recipientAddress:  z.string().describe("32-byte recipient address as hex"),
      messageBodyHex:    z.string().describe("Hex-encoded message payload"),
    }),
  }
);

// ─── Tool: encodeRebalancePayload ─────────────────────────────────────────────
export const encodeRebalancePayload = tool(
  async ({ pairId, deltaToken0, deltaToken1, newFee, tickLower, tickUpper, minExpectedYield }) => {
    const payload = encodeAbiParameters(
      parseAbiParameters("bytes32 pairId, int128 deltaToken0, int128 deltaToken1, uint24 newFee, int24 tickLower, int24 tickUpper, uint256 minExpectedYield"),
      [
        pairId as `0x${string}`,
        BigInt(deltaToken0),
        BigInt(deltaToken1),
        newFee,
        tickLower,
        tickUpper,
        BigInt(minExpectedYield),
      ]
    );
    return { payload };
  },
  {
    name: "encodeRebalancePayload",
    description: "ABI-encode a RebalanceMessage struct for Hyperlane dispatch",
    schema: z.object({
      pairId:           z.string().describe("keccak256(token0, token1) as hex"),
      deltaToken0:      z.string().describe("signed int128 as string"),
      deltaToken1:      z.string().describe("signed int128 as string"),
      newFee:           z.number(),
      tickLower:        z.number(),
      tickUpper:        z.number(),
      minExpectedYield: z.string().describe("uint256 as string"),
    }),
  }
);

// ─── Tool: sendHyperlaneMessage (CoordinatorAgent only) ───────────────────────
export const sendHyperlaneMessage = tool(
  async ({ sourceChain, destinationDomain, recipientAddress, messageBodyHex }) => {
    const cfg     = CHAIN_CONFIGS[sourceChain as keyof typeof CHAIN_CONFIGS];
    const account = privateKeyToAccount(process.env.AGENT_PRIVATE_KEY as `0x${string}`);
    const mb      = MAILBOXES[sourceChain];

    const publicClient = createPublicClient({ chain: cfg.chain, transport: http(cfg.rpc) });
    const walletClient = createWalletClient({ account, chain: cfg.chain, transport: http(cfg.rpc) });

    // Quote fee first
    const fee = await publicClient.readContract({
      address: mb, abi: mailboxAbi, functionName: "quoteDispatch",
      args: [destinationDomain, recipientAddress as `0x${string}`, messageBodyHex as `0x${string}`],
    });

    const { request } = await publicClient.simulateContract({
      account,
      address: mb,
      abi: mailboxAbi,
      functionName: "dispatch",
      args: [destinationDomain, recipientAddress as `0x${string}`, messageBodyHex as `0x${string}`],
      value: fee,
    });

    const txHash = await walletClient.writeContract(request);
    return { sourceChain, destinationDomain, txHash, feeWei: fee.toString() };
  },
  {
    name: "sendHyperlaneMessage",
    description: "Dispatch a Hyperlane cross-chain message from CoordinatorAgent",
    schema: z.object({
      sourceChain:       z.enum(["ethereum", "base", "bnb"]),
      destinationDomain: z.number(),
      recipientAddress:  z.string(),
      messageBodyHex:    z.string(),
    }),
  }
);

export const hyperlaneTools = [estimateHyperlaneFee, encodeRebalancePayload, sendHyperlaneMessage];
