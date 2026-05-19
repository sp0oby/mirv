"use client";

import dynamic from "next/dynamic";

// Pure server-component stub. The actual wagmi+RainbowKit-using form lives
// in ./_client.tsx and loads ONLY on the client (ssr: false). This means
// Next's server compile pass never touches the wagmi dep tree.

const DepositClient = dynamic(() => import("./_client"), {
  ssr: false,
  loading: () => (
    <div className="pt-4">
      <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">deposit</h1>
      <p className="text-[16px] text-ink-soft">loading wallet…</p>
    </div>
  ),
});

export default function DepositPage() {
  return <DepositClient />;
}
