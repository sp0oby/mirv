import "./globals.css";
import type { Metadata, Viewport } from "next";
import { ShellHeader } from "@/components/ShellHeader";
import { ShellFooter } from "@/components/ShellFooter";
import { AmbientPetals } from "@/components/AmbientPetals";
import { WalletProviders } from "@/components/WalletProviders";

export const metadata: Metadata = {
  metadataBase: new URL("https://mirv-frontend.vercel.app"),
  title: {
    default: "mirv — cross-chain liquidity mirror",
    template: "%s · mirv",
  },
  description:
    "deposit usdc on base. agents move your money across base + ethereum to chase whichever side pays more in swap fees. you keep 85% of the extra.",
  keywords: [
    "uniswap v4",
    "cross-chain liquidity",
    "hyperlane",
    "circle cctp",
    "liquidity mirror",
    "v4 hooks",
    "ai agents defi",
    "mirv",
  ],
  authors: [{ name: "sp0oby", url: "https://github.com/sp0oby" }],
  creator: "sp0oby",
  openGraph: {
    title: "mirv — cross-chain liquidity mirror",
    description:
      "deposit usdc on base. agents move your money across base + ethereum. you keep 85% of the extra.",
    url: "https://mirv-frontend.vercel.app",
    siteName: "mirv",
    locale: "en_US",
    type: "website",
  },
  twitter: {
    card: "summary_large_image",
    title: "mirv — cross-chain liquidity mirror",
    description:
      "one deposit. liquidity working across base + ethereum, rebalanced by an AI swarm. you keep 85% of the extra yield.",
    creator: "@sp0oby",
  },
  robots: {
    index: true,
    follow: true,
    googleBot: { index: true, follow: true },
  },
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
