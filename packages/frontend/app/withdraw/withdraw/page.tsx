"use client";

import dynamic from "next/dynamic";

const WithdrawClient = dynamic(() => import("./_client"), {
  ssr: false,
  loading: () => (
    <div className="pt-4">
      <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">withdraw</h1>
      <p className="text-[16px] text-ink-soft">loading wallet…</p>
    </div>
  ),
});

export default function WithdrawPage() {
  return <WithdrawClient />;
}
