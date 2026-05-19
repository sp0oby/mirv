"use client";

import { useState } from "react";
import { useAccount, useReadContract, useWriteContract, useChainId } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { baseSepolia } from "wagmi/chains";
import { parseUnits, erc20Abi, formatUnits } from "viem";

const USDC_BASE_SEPOLIA = "0x036CbD53842c5426634e7929541eC2318f3dCF7e" as const;
const MIRROR_VAULT_BASE = "0x062b9E547689D53D9c5b059215ED967a9ceAf37b" as const;

// Two withdraw modes:
//   `redeem(shares, receiver, owner)` — sync, requires enough USDC on Base.
//   `requestWithdraw(shares, receiver)` — async, queues for cross-chain unwind.
const VAULT_ABI = [
  { name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "convertToAssets", type: "function", stateMutability: "view", inputs: [{ name: "shares", type: "uint256" }], outputs: [{ type: "uint256" }] },
  {
    name: "redeem", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "shares", type: "uint256" },
      { name: "receiver", type: "address" },
      { name: "owner", type: "address" },
    ],
    outputs: [{ type: "uint256" }],
  },
  {
    name: "requestWithdraw", type: "function", stateMutability: "nonpayable",
    inputs: [
      { name: "shares", type: "uint256" },
      { name: "receiver", type: "address" },
    ],
    outputs: [{ name: "requestId", type: "uint256" }],
  },
] as const;

export default function WithdrawPage() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const onBaseSepolia = chainId === baseSepolia.id;
  const enabled = !!address && onBaseSepolia;

  const [mode, setMode]   = useState<"sync" | "async">("sync");
  const [amount, setAmount] = useState("");
  const amountUnits = amount && /^\d+(\.\d+)?$/.test(amount) ? parseUnits(amount, 6) : 0n;

  const { data: shareBalance } = useReadContract({
    address: MIRROR_VAULT_BASE, abi: VAULT_ABI, functionName: "balanceOf",
    args: address ? [address] : undefined, query: { enabled },
  });
  const { data: vaultLocalUsdc } = useReadContract({
    address: USDC_BASE_SEPOLIA, abi: erc20Abi, functionName: "balanceOf",
    args: [MIRROR_VAULT_BASE], query: { enabled: onBaseSepolia },
  });
  const { data: previewAssets } = useReadContract({
    address: MIRROR_VAULT_BASE, abi: VAULT_ABI, functionName: "convertToAssets",
    args: amountUnits > 0n ? [amountUnits] : undefined, query: { enabled: enabled && amountUnits > 0n },
  });

  const vaultUsdcNum  = vaultLocalUsdc ? Number(formatUnits(vaultLocalUsdc, 6)) : 0;
  const wouldGetNum   = previewAssets ? Number(formatUnits(previewAssets, 6)) : 0;
  const cannotSync    = previewAssets !== undefined && vaultLocalUsdc !== undefined && previewAssets > vaultLocalUsdc;

  const { writeContract: doRedeem,  isPending: redeeming  } = useWriteContract();
  const { writeContract: doRequest, isPending: requesting } = useWriteContract();

  function onSubmit() {
    if (!address || amountUnits === 0n) return;
    if (mode === "sync") {
      doRedeem({
        address: MIRROR_VAULT_BASE, abi: VAULT_ABI, functionName: "redeem",
        args: [amountUnits, address, address],
      });
    } else {
      doRequest({
        address: MIRROR_VAULT_BASE, abi: VAULT_ABI, functionName: "requestWithdraw",
        args: [amountUnits, address],
      });
    }
  }

  return (
    <div className="pt-4">
      <header className="mb-10">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">
          withdraw
        </h1>
        <p className="text-[16px] text-ink-soft max-w-[60ch]">
          burn ur mirvUSDC shares for the underlying. sync redeems are
          instant when base has enough usdc; otherwise ur shares queue for
          the agent to unwind cross-chain.
        </p>
      </header>

      {!isConnected && (
        <section className="frame-outer p-8 bg-paper-warm text-center" style={{ transform: "rotate(0.4deg)" }}>
          <p className="text-[16px] text-ink mb-5">connect your wallet to withdraw.</p>
          <ConnectButton.Custom>
            {({ openConnectModal }) => (
              <button onClick={openConnectModal} className="btn-win95 btn-win95-primary text-[16px] px-7 py-3">
                connect wallet
              </button>
            )}
          </ConnectButton.Custom>
        </section>
      )}

      {enabled && (
        <section className="grid grid-cols-1 md:grid-cols-[1fr_320px] gap-10">
          <div className="frame-outer p-7 bg-paper-warm" style={{ transform: "rotate(-0.3deg)" }}>
            {/* mode switch */}
            <div className="inline-flex border-2 border-ink rounded-stamp overflow-hidden mb-6">
              {(["sync", "async"] as const).map((m) => (
                <button
                  key={m}
                  onClick={() => setMode(m)}
                  className={`px-4 py-2 font-maru text-[13px] ${
                    mode === m ? "bg-marigold text-ink" : "bg-paper text-ink-soft hover:text-ink"
                  }`}
                >
                  {m === "sync" ? "instant (local)" : "async (cross-chain)"}
                </button>
              ))}
            </div>

            <label className="font-maru text-[14px] text-ink font-semibold block mb-3">
              shares to burn
            </label>
            <div className="flex items-center justify-between mb-2 text-[12px]">
              <span className="text-ink-faint">
                ur balance: {shareBalance ? Number(formatUnits(shareBalance, 6)).toFixed(4) : "—"} mirvUSDC
              </span>
              {shareBalance !== undefined && shareBalance > 0n && (
                <button
                  onClick={() => setAmount(formatUnits(shareBalance, 6))}
                  className="text-pink-hot underline"
                >
                  use max
                </button>
              )}
            </div>
            <input
              type="text"
              inputMode="decimal"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              placeholder="0.0000"
              className="w-full bg-paper border-2 border-ink rounded-stamp px-4 py-3 text-[24px] font-mono text-ink outline-none focus:border-pink-hot mb-4"
            />

            {amountUnits > 0n && (
              <p className="text-[14px] text-ink-soft mb-5">
                you would receive ~
                <span className="font-mono text-ink"> ${wouldGetNum.toFixed(2)} </span>
                usdc.
              </p>
            )}

            {mode === "sync" && cannotSync && (
              <div className="frame-middle p-3 mb-4 bg-paper">
                <p className="text-[13px] text-ink">
                  base only has <span className="font-mono">${vaultUsdcNum.toFixed(2)}</span> usdc locally.
                  this amount needs the async path so the agent can unwind a sister LP first.
                </p>
              </div>
            )}

            <button
              onClick={onSubmit}
              disabled={amountUnits === 0n || (mode === "sync" && cannotSync) || redeeming || requesting}
              className="btn-win95 btn-win95-primary text-[16px] px-7 py-3 disabled:opacity-40 disabled:cursor-not-allowed"
            >
              {mode === "sync"
                ? (redeeming ? "redeeming…" : "redeem")
                : (requesting ? "queuing…" : "queue async withdraw")}
            </button>
          </div>

          {/* sidebar */}
          <aside className="space-y-3">
            <div className="frame-outer p-4">
              <p className="font-maru text-[11px] uppercase tracking-wider text-ink-faint mb-1">
                local liquidity
              </p>
              <p className="font-mono text-[18px] text-ink">${vaultUsdcNum.toFixed(2)}</p>
              <p className="text-[11px] text-ink-faint mt-1">usdc on base sepolia vault</p>
            </div>
            <div className="frame-outer p-4 bg-paper-warm">
              <p className="font-maru text-[12px] font-semibold text-ink mb-2">async mode</p>
              <ul className="text-[12px] text-ink-soft space-y-1 leading-snug">
                <li>— shares move into vault custody (not yet burned)</li>
                <li>— agent unwinds sister LP, bridges usdc back via cctp</li>
                <li>— agent calls fulfillWithdraw, paid out at current price</li>
                <li>— after 24h, requester can cancel if agent stalls</li>
              </ul>
            </div>
          </aside>
        </section>
      )}
    </div>
  );
}
