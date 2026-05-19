"use client";

import dynamic from "next/dynamic";

const AdminClient = dynamic(() => import("./_client"), {
  ssr: false,
  loading: () => (
    <div className="pt-4">
      <h1 className="display-title text-[56px] md:text-[72px] leading-none mb-3">admin</h1>
      <p className="text-[16px] text-ink-soft">loading wallet…</p>
    </div>
  ),
});

export default function AdminPage() {
  return <AdminClient />;
}
