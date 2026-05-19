import "./globals.css";
import type { Metadata, Viewport } from "next";
import { ShellHeader } from "@/components/ShellHeader";
import { ShellFooter } from "@/components/ShellFooter";
import { AmbientPetals } from "@/components/AmbientPetals";
import { WalletProviders } from "@/components/WalletProviders";

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
        <WalletProviders>
          <AmbientPetals />
          <ShellHeader />
          <main className="mx-auto max-w-[1200px] px-8 pb-24">{children}</main>
          <ShellFooter />
        </WalletProviders>
      </body>
    </html>
  );
}
