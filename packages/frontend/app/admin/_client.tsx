"use client";

import { useAccount, useReadContract, useChainId } from "wagmi";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { baseSepolia } from "wagmi/chains";
import { WalletProviders } from "@/components/WalletProviders";

const MIRROR_VAULT_BASE = "0x062b9E547689D53D9c5b059215ED967a9ceAf37b" as const;
const MIRROR_HOOK_BASE  = "0xA059C8544E046F29C5c2A9f0dE6314964926c540" as const;

const OWNABLE_ABI = [
  { name: "owner",    type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "guardian", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "paused",   type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] },
] as const;

const VAULT_VIEW_ABI = [
  ...OWNABLE_ABI,
  { name: "treasury",                       type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "pendingTreasury",                type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { name: "pendingTreasuryEffectiveAt",     type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "maxCrossChainAssetsDeltaBps",    type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "crossChainAssetsMaxStaleness",   type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

const HOOK_VIEW_ABI = [
  ...OWNABLE_ABI,
  { name: "oracleDeviationToleranceBps", type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "maxSisterDepthMultiple",      type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { name: "dispatchCooldown",            type: "function", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

export default function AdminClient() {
  return (
    <WalletProviders>
      <AdminContent />
    </WalletProviders>
  );
}

function AdminContent() {
  const { address, isConnected } = useAccount();
  const chainId = useChainId();
  const onBaseSepolia = chainId === baseSepolia.id;
  const enabled = onBaseSepolia;

  const { data: vaultOwner }      = useReadContract({ address: MIRROR_VAULT_BASE, abi: VAULT_VIEW_ABI, functionName: "owner",                        query: { enabled } });
  const { data: vaultGuardian }   = useReadContract({ address: MIRROR_VAULT_BASE, abi: VAULT_VIEW_ABI, functionName: "guardian",                     query: { enabled } });
  const { data: vaultPaused }     = useReadContract({ address: MIRROR_VAULT_BASE, abi: VAULT_VIEW_ABI, functionName: "paused",                       query: { enabled } });
  const { data: treasury }        = useReadContract({ address: MIRROR_VAULT_BASE, abi: VAULT_VIEW_ABI, functionName: "treasury",                     query: { enabled } });
  const { data: pendingTreasury } = useReadContract({ address: MIRROR_VAULT_BASE, abi: VAULT_VIEW_ABI, functionName: "pendingTreasury",              query: { enabled } });
  const { data: pendingEffAt }    = useReadContract({ address: MIRROR_VAULT_BASE, abi: VAULT_VIEW_ABI, functionName: "pendingTreasuryEffectiveAt",   query: { enabled } });
  const { data: maxDeltaBps }     = useReadContract({ address: MIRROR_VAULT_BASE, abi: VAULT_VIEW_ABI, functionName: "maxCrossChainAssetsDeltaBps",  query: { enabled } });
  const { data: maxStaleness }    = useReadContract({ address: MIRROR_VAULT_BASE, abi: VAULT_VIEW_ABI, functionName: "crossChainAssetsMaxStaleness", query: { enabled } });

  const { data: hookOwner }    = useReadContract({ address: MIRROR_HOOK_BASE, abi: HOOK_VIEW_ABI, functionName: "owner",                          query: { enabled } });
  const { data: hookGuardian } = useReadContract({ address: MIRROR_HOOK_BASE, abi: HOOK_VIEW_ABI, functionName: "guardian",                       query: { enabled } });
  const { data: hookPaused }   = useReadContract({ address: MIRROR_HOOK_BASE, abi: HOOK_VIEW_ABI, functionName: "paused",                         query: { enabled } });
  const { data: oracleTol }    = useReadContract({ address: MIRROR_HOOK_BASE, abi: HOOK_VIEW_ABI, functionName: "oracleDeviationToleranceBps",    query: { enabled } });
  const { data: sisterCap }    = useReadContract({ address: MIRROR_HOOK_BASE, abi: HOOK_VIEW_ABI, functionName: "maxSisterDepthMultiple",          query: { enabled } });
  const { data: cooldown }     = useReadContract({ address: MIRROR_HOOK_BASE, abi: HOOK_VIEW_ABI, functionName: "dispatchCooldown",               query: { enabled } });

  const isOwner    = address && vaultOwner && address.toLowerCase() === vaultOwner.toLowerCase();
  const isGuardian = address && vaultGuardian && vaultGuardian !== "0x0000000000000000000000000000000000000000" && address.toLowerCase() === vaultGuardian.toLowerCase();

  return (
    <div className="pt-4">
      <header className="mb-10">
        <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">admin</h1>
        <p className="text-[16px] text-ink-soft max-w-[60ch]">
          live, owner-controlled state on the rc6 deployment. anyone can
          read this; only the owner / guardian can act. write actions
          (pause, propose new treasury, adjust bounds) land in v1.
        </p>
      </header>

      {!isConnected && (
        <section className="frame-outer p-6 mb-8">
          <p className="text-[14px] text-ink-soft mb-3">
            you can read this page without connecting. connect to see whether ur address has owner / guardian privileges.
          </p>
          <ConnectButton.Custom>
            {({ openConnectModal }) => (
              <button onClick={openConnectModal} className="btn-win95 text-[14px] px-5 py-2.5">
                connect wallet (optional)
              </button>
            )}
          </ConnectButton.Custom>
        </section>
      )}

      {isConnected && enabled && (
        <section className="frame-outer p-5 mb-8 bg-paper-warm">
          <p className="font-maru text-[13px] uppercase tracking-wider text-ink-faint mb-2">your role</p>
          <div className="flex flex-wrap gap-2">
            {isOwner    && <span className="stamp" style={{ color: "#ef48aa", transform: "rotate(-3deg)" }}>owner</span>}
            {isGuardian && <span className="stamp" style={{ color: "#3a2c3a", transform: "rotate(2deg)" }}>guardian</span>}
            {!isOwner && !isGuardian && <span className="text-[14px] text-ink-soft">read-only (not owner or guardian)</span>}
          </div>
        </section>
      )}

      <section className="mb-10">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">✿ MirrorVault (base sepolia)</h2>
        <div className="frame-outer p-5">
          <dl className="grid grid-cols-1 md:grid-cols-2 gap-x-8 gap-y-3 text-[14px]">
            <Row label="address"           value={shortAddr(MIRROR_VAULT_BASE)} />
            <Row label="owner"             value={shortAddr(vaultOwner)} />
            <Row label="guardian"          value={vaultGuardian ? (vaultGuardian === "0x0000000000000000000000000000000000000000" ? "(unset)" : shortAddr(vaultGuardian)) : "—"} />
            <Row label="paused"            value={vaultPaused === undefined ? "—" : (vaultPaused ? "yes ✗" : "no ✓")} />
            <Row label="treasury"          value={shortAddr(treasury)} />
            <Row label="pending treasury"  value={
              pendingTreasury && pendingTreasury !== "0x0000000000000000000000000000000000000000"
                ? `${shortAddr(pendingTreasury)} (effective ${pendingEffAt ? new Date(Number(pendingEffAt) * 1000).toLocaleString() : "?"})`
                : "(none pending)"
            } />
            <Row label="R-1 max delta"     value={maxDeltaBps !== undefined ? `${Number(maxDeltaBps) / 100}%` : "—"} />
            <Row label="R-3 max staleness" value={maxStaleness !== undefined ? `${Number(maxStaleness)}s` : "—"} />
          </dl>
        </div>
      </section>

      <section className="mb-10">
        <h2 className="font-maru text-[20px] font-semibold text-ink mb-5">❀ MirrorHook (base sepolia)</h2>
        <div className="frame-outer p-5 bg-paper-warm">
          <dl className="grid grid-cols-1 md:grid-cols-2 gap-x-8 gap-y-3 text-[14px]">
            <Row label="address"           value={shortAddr(MIRROR_HOOK_BASE)} />
            <Row label="owner"             value={shortAddr(hookOwner)} />
            <Row label="guardian"          value={hookGuardian ? (hookGuardian === "0x0000000000000000000000000000000000000000" ? "(unset)" : shortAddr(hookGuardian)) : "—"} />
            <Row label="paused"            value={hookPaused === undefined ? "—" : (hookPaused ? "yes ✗" : "no ✓")} />
            <Row label="R-11 oracle tol"   value={oracleTol !== undefined ? `${Number(oracleTol) / 100}%` : "—"} />
            <Row label="R-13 sister cap"   value={sisterCap !== undefined ? `${sisterCap.toString()}×` : "—"} />
            <Row label="dispatch cooldown" value={cooldown !== undefined ? `${Number(cooldown)}s` : "—"} />
          </dl>
        </div>
      </section>
    </div>
  );
}

function Row({ label, value }: { label: string; value?: string }) {
  return (
    <div className="flex justify-between gap-4 border-b border-dotted border-ink-soft/30 pb-2">
      <dt className="font-maru text-ink-faint text-[12px] uppercase tracking-wider">{label}</dt>
      <dd className="font-mono text-ink text-[13px] break-all text-right">{value ?? "—"}</dd>
    </div>
  );
}

function shortAddr(a: string | undefined): string {
  if (!a) return "—";
  if (a === "0x0000000000000000000000000000000000000000") return "(zero)";
  return `${a.slice(0, 6)}…${a.slice(-4)}`;
}
