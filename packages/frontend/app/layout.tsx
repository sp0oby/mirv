import "./globals.css";
import type { Metadata, Viewport } from "next";
import { ShellHeader } from "@/components/ShellHeader";
import { ShellFooter } from "@/components/ShellFooter";
import { AmbientPetals } from "@/components/AmbientPetals";

// v0 — design-first. wagmi + RainbowKit providers are wired separately and
// only mounted on routes that need wallet (deposit, positions, withdraw,
// admin). landing / dashboard / activity are read-only from public RPCs
// or static data, so they don't need the heavy provider tree.

export const metadata: Metadata = {
  title: "mirv — cross-chain liquidity mirror",
  description: "deposit on base. agents mirror across chains. you keep the extra.",
};

export const viewport: Viewport = {
  themeColor: "#fff8e7",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <AmbientPetals />
        <ShellHeader />
        <main className="mx-auto max-w-[1200px] px-8 pb-24">{children}</main>
        <ShellFooter />
      </body>
    </html>
  );
}
