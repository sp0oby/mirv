"use client";

import Link from "next/link";
import { useAccount, useReadContract, useChainId } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { baseSepolia } from "wagmi/chains";
import { formatUnits } from "viem";

const MIRROR_VAULT_BASE = "0x062b9E547689D53D9c5b059215ED967a9ceAf37b" as const;

// Minimal ERC-4626 + ERC-20 ABI shape for the reads we need.
const VAULT_ABI = [
  { name: "balanceOf",       type: "function", stateMutability: "view", inputs: [{ name: "owner", type: "address" }], outputs: [{ type: "uint256" }] },
  { name: "totalSupply",     type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "totalAssets",     type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "convertToAssets", type: "function", stateMutability: "view", inputs: [{ name: "shares", type: "uint256" }], outputs: [{ type: "uint256" }] },
  { name: "principalTracked", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

export default function PositionsPage() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const onBaseSepolia = chainId === baseSepolia.id;
  const enabled = !!address && onBaseSepolia;

  const { data: shares } = useReadContract({
    address: MIRROR_VAULT_BASE, abi: VAULT_ABI, functionName: "balanceOf",
    args: address ? [address] : undefined, query: { enabled },
  });
  const { data: assetsForShares } = useReadContract({
    address: MIRROR_VAULT_BASE, abi: VAULT_ABI, functionName: "convertToAssets",
    args: shares !== undefined ? [shares] : undefined, query: { enabled: enabled && shares !== undefined && shares > 0n },
  });
  const { data: totalSupply } = useReadContract({
    address: MIRROR_VAULT_BASE, abi: VAULT_ABI, functionName: "totalSupply", query: { enabled: onBaseSepolia },
  });
  const { data: totalAssets } = useReadContract({
    address: MIRROR_VAULT_BASE, abi: VAULT_ABI, functionName: "totalAssets", query: { enabled: onBaseSepolia },
  });

  const sharesNum = shares ? Number(formatUnits(shares, 6))          : 0;
  const assetsNum = assetsForShares ? Number(formatUnits(assetsForShares, 6)) : 0;
  const sharePct  = totalSupply && shares ? (Number(shares) / Number(totalSupply)) * 100 : 0;
  const sharePrice = totalAssets && totalSupply && totalSupply > 0n
    ? Number(formatUnits(totalAssets, 6)) / Number(formatUnits(totalSupply, 6))
    : 1;

  return (
    <div className="pt-4">
      <header className="mb-10">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">
          my positions
        </h1>
        <p className="text-[16px] text-ink-soft max-w-[60ch]">
          your share balance + current usdc-denominated value in the mirv
          vault. shares earn whatever extra yield the swarm captures across
          chains, minus the 15% protocol fee on extras only.
        </p>
      </header>

      {!isConnected && (
        <section className="frame-outer p-8 bg-paper-warm text-center" style={{ transform: "rotate(-0.4deg)" }}>
          <p className="text-[16px] text-ink mb-5">
            connect your wallet to see ur shares.
          </p>
          <ConnectButton.Custom>
            {({ openConnectModal }) => (
              <button onClick={openConnectModal} className="btn-win95 btn-win95-primary text-[16px] px-7 py-3">
                connect wallet
              </button>
            )}
          </ConnectButton.Custom>
        </section>
      )}

      {isConnected && !onBaseSepolia && (
        <section className="frame-outer p-6 bg-paper-warm">
          <p className="text-[15px] text-ink">
            ur wallet is on a different chain. switch to <strong>base sepolia</strong> to see positions.
          </p>
        </section>
      )}

      {enabled && (
        <>
          {/* Headline numbers */}
          <section className="grid grid-cols-1 md:grid-cols-3 gap-5 mb-10">
            <div className="frame-outer p-5" style={{ transform: "rotate(-0.5deg)" }}>
              <p className="font-maru text-[12px] uppercase tracking-wider text-ink-faint mb-1">your shares</p>
              <p className="pixel text-[32px] text-ink leading-none">{sharesNum.toFixed(4)}</p>
              <p className="text-[12px] text-ink-soft mt-1">mirvUSDC</p>
            </div>
            <div className="frame-outer p-5 bg-paper-warm" style={{ transform: "rotate(0.5deg)" }}>
              <p className="font-maru text-[12px] uppercase tracking-wider text-ink-faint mb-1">current value</p>
              <p className="pixel text-[32px] text-ink leading-none">${assetsNum.toFixed(2)}</p>
              <p className="text-[12px] text-ink-soft mt-1">if redeemed now</p>
            </div>
            <div className="frame-outer p-5" style={{ transform: "rotate(-0.3deg)" }}>
              <p className="font-maru text-[12px] uppercase tracking-wider text-ink-faint mb-1">share of pool</p>
              <p className="pixel text-[32px] text-ink leading-none">{sharePct.toFixed(2)}%</p>
              <p className="text-[12px] text-ink-soft mt-1">of total supply</p>
            </div>
          </section>

          {/* Detail / actions */}
          <section className="grid grid-cols-1 md:grid-cols-2 gap-6 mb-10">
            <div className="frame-outer p-5">
              <h2 className="font-maru text-[16px] font-semibold text-ink mb-3">share price</h2>
              <p className="text-[14px] text-ink-soft mb-2">
                1 mirvUSDC = <span className="font-mono text-ink">{sharePrice.toFixed(6)}</span> usdc
              </p>
              <p className="text-[12px] text-ink-faint">
                derived from <code className="font-mono text-[12px]">totalAssets() / totalSupply()</code>.
                value can move down if cross-chain LPs underperform.
              </p>
            </div>
            <div className="frame-outer p-5 bg-paper-warm">
              <h2 className="font-maru text-[16px] font-semibold text-ink mb-3">redeem</h2>
              <p className="text-[14px] text-ink-soft mb-4">
                redeem locally if base has enough usdc, or queue an async
                cross-chain unwind (~5min on testnet, can be cancelled after
                24h if the agent stalls).
              </p>
              <Link href="/withdraw" className="btn-win95 btn-win95-secondary text-[14px] px-5 py-2.5 inline-block">
                go to withdraw →
              </Link>
            </div>
          </section>
        </>
      )}

      {enabled && shares === 0n && (
        <section className="frame-outer p-6 mt-2 text-center">
          <p className="text-[15px] text-ink-soft mb-3">no shares yet.</p>
          <Link href="/deposit" className="btn-win95 btn-win95-primary text-[14px] px-5 py-2.5 inline-block">
            deposit usdc
          </Link>
        </section>
      )}
    </div>
  );
}
