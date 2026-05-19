"use client";

import { useState } from "react";
import { useAccount, useReadContract, useWriteContract, useChainId, useSwitchChain } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { baseSepolia } from "wagmi/chains";
import { parseUnits, erc20Abi } from "viem";

// rc6 testnet addresses — these are bound to the deployment, not env, so
// the page works without a build-time secret. Switch to env when we add
// mainnet (different addresses per network).
const USDC_BASE_SEPOLIA   = "0x036CbD53842c5426634e7929541eC2318f3dCF7e" as const;
const MIRROR_VAULT_BASE   = "0x062b9E547689D53D9c5b059215ED967a9ceAf37b" as const;

// Minimal ERC-4626 ABI for the two functions we call here (approve is from
// erc20Abi, vault.deposit takes (assets, receiver)).
const VAULT_DEPOSIT_ABI = [
  {
    name: "deposit",
    type: "function",
    stateMutability: "nonpayable",
    inputs:  [{ name: "assets", type: "uint256" }, { name: "receiver", type: "address" }],
    outputs: [{ name: "shares", type: "uint256" }],
  },
  {
    name: "previewDeposit",
    type: "function",
    stateMutability: "view",
    inputs:  [{ name: "assets", type: "uint256" }],
    outputs: [{ name: "shares", type: "uint256" }],
  },
] as const;

export default function DepositPage() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const { switchChain } = useSwitchChain();
  const wrongChain = isConnected && chainId !== baseSepolia.id;

  const [amount, setAmount] = useState("");
  const amountUnits = amount && /^\d+(\.\d+)?$/.test(amount) ? parseUnits(amount, 6) : 0n;

  // ── current allowance ─────────────────────────────────────────────────
  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: USDC_BASE_SEPOLIA,
    abi: erc20Abi,
    functionName: "allowance",
    args: address ? [address, MIRROR_VAULT_BASE] : undefined,
    query: { enabled: !!address && !wrongChain },
  });

  // ── usdc balance ──────────────────────────────────────────────────────
  const { data: usdcBalance } = useReadContract({
    address: USDC_BASE_SEPOLIA,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: address ? [address] : undefined,
    query: { enabled: !!address && !wrongChain },
  });

  // ── preview shares ────────────────────────────────────────────────────
  const { data: previewShares } = useReadContract({
    address: MIRROR_VAULT_BASE,
    abi: VAULT_DEPOSIT_ABI,
    functionName: "previewDeposit",
    args: [amountUnits],
    query: { enabled: amountUnits > 0n && !wrongChain },
  });

  const needsApproval = amountUnits > 0n && (allowance ?? 0n) < amountUnits;

  const { writeContract: doApprove, isPending: approving } = useWriteContract({
    mutation: { onSuccess: () => setTimeout(refetchAllowance, 2000) },
  });
  const { writeContract: doDeposit, isPending: depositing } = useWriteContract();

  function onApprove() {
    doApprove({
      address: USDC_BASE_SEPOLIA,
      abi: erc20Abi,
      functionName: "approve",
      args: [MIRROR_VAULT_BASE, amountUnits],
    });
  }
  function onDeposit() {
    if (!address) return;
    doDeposit({
      address: MIRROR_VAULT_BASE,
      abi: VAULT_DEPOSIT_ABI,
      functionName: "deposit",
      args: [amountUnits, address],
    });
  }

  // ── primary button state machine ──────────────────────────────────────
  // mirrors qa/SKILL.md "one primary visible at a time"
  let primaryLabel = "deposit usdc";
  let primaryOnClick: (() => void) | undefined = onDeposit;
  let primaryDisabled = amountUnits === 0n;
  if (!isConnected) {
    primaryLabel = ""; // ConnectButton fills in
    primaryOnClick = undefined;
    primaryDisabled = true;
  } else if (wrongChain) {
    primaryLabel = "switch to base sepolia";
    primaryOnClick = () => switchChain({ chainId: baseSepolia.id });
    primaryDisabled = false;
  } else if (needsApproval) {
    primaryLabel = approving ? "approving…" : "approve usdc";
    primaryOnClick = onApprove;
    primaryDisabled = approving;
  } else if (depositing) {
    primaryLabel = "depositing…";
    primaryDisabled = true;
  }

  return (
    <div className="pt-4">
      <header className="mb-10">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">
          deposit
        </h1>
        <p className="text-[16px] text-ink-soft max-w-[60ch]">
          deposit usdc on base sepolia. shares mint 1:1 (more or less) on first
          deposit; afterward the share price reflects total assets / total
          supply. agents handle the mirror from here.
        </p>
      </header>

      <section className="grid grid-cols-1 md:grid-cols-[1fr_320px] gap-10">
        {/* ── form ────────────────────────────────────────────────────── */}
        <div className="frame-outer p-7 bg-paper-warm" style={{ transform: "rotate(-0.4deg)" }}>
          <div className="flex items-center justify-between mb-3">
            <label className="font-maru text-[14px] text-ink font-semibold">
              amount
            </label>
            {isConnected && !wrongChain && usdcBalance !== undefined && (
              <button
                onClick={() => setAmount((Number(usdcBalance) / 1e6).toString())}
                className="text-[12px] text-pink-hot underline"
              >
                use max ({(Number(usdcBalance) / 1e6).toFixed(2)} usdc)
              </button>
            )}
          </div>
          <div className="flex items-center gap-3 mb-5">
            <input
              type="text"
              inputMode="decimal"
              value={amount}
              onChange={(e) => setAmount(e.target.value)}
              placeholder="0.00"
              className="flex-1 bg-paper border-2 border-ink rounded-stamp px-4 py-3 text-[24px] font-mono text-ink outline-none focus:border-pink-hot"
            />
            <span className="font-maru text-[16px] text-ink-soft">usdc</span>
          </div>

          {amountUnits > 0n && previewShares !== undefined && (
            <p className="text-[13px] text-ink-soft mb-5">
              you would receive ~
              <span className="font-mono text-ink"> {(Number(previewShares) / 1e6).toFixed(4)} </span>
              mirvUSDC shares.
            </p>
          )}

          <div className="flex items-center gap-3">
            {!isConnected ? (
              <ConnectButton.Custom>
                {({ openConnectModal }) => (
                  <button
                    onClick={openConnectModal}
                    className="btn-win95 btn-win95-primary text-[16px] px-7 py-3"
                  >
                    connect wallet
                  </button>
                )}
              </ConnectButton.Custom>
            ) : (
              <button
                onClick={primaryOnClick}
                disabled={primaryDisabled}
                className="btn-win95 btn-win95-primary text-[16px] px-7 py-3 disabled:opacity-40 disabled:cursor-not-allowed"
              >
                {primaryLabel}
              </button>
            )}
          </div>

          {isConnected && needsApproval && !wrongChain && (
            <p className="text-[12px] text-ink-faint mt-3">
              first time: usdc needs a one-time approval before the vault can pull it.
            </p>
          )}
        </div>

        {/* ── sidebar facts ───────────────────────────────────────────── */}
        <aside className="space-y-3">
          <div className="frame-outer p-4" style={{ transform: "rotate(0.5deg)" }}>
            <p className="font-maru text-[11px] uppercase tracking-wider text-ink-faint mb-1">
              vault address
            </p>
            <p className="font-mono text-[11px] text-ink break-all">
              {MIRROR_VAULT_BASE}
            </p>
          </div>
          <div className="frame-outer p-4" style={{ transform: "rotate(-0.5deg)" }}>
            <p className="font-maru text-[11px] uppercase tracking-wider text-ink-faint mb-1">
              chain
            </p>
            <p className="text-[14px] text-ink">base sepolia</p>
          </div>
          <div className="frame-outer p-4" style={{ transform: "rotate(0.3deg)" }}>
            <p className="font-maru text-[11px] uppercase tracking-wider text-ink-faint mb-1">
              allocations
            </p>
            <p className="text-[13px] text-ink-soft">
              60% base · 40% eth sepolia
            </p>
            <p className="text-[11px] text-ink-faint mt-1">
              eth share bridges via cctp.
            </p>
          </div>
        </aside>
      </section>

      <p className="text-[12px] text-ink-faint mt-10">
        testnet. tokens have no value. dyor before mainnet.
      </p>
    </div>
  );
}
