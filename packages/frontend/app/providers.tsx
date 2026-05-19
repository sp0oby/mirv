"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { RainbowKitProvider, getDefaultConfig, lightTheme } from "@rainbow-me/rainbowkit";
import { WagmiProvider } from "wagmi";
import { base, baseSepolia, mainnet, sepolia } from "wagmi/chains";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { http } from "viem";
import { useState } from "react";

// One QueryClient per browser session. Created inside the component tree so
// Next's Server Components don't try to instantiate a stateful client at
// build time.
//
// Chains are wired symmetric to the contract layer's `NETWORK=mainnet|sepolia`
// flag — at testnet we light up baseSepolia + sepolia; mainnet pairs Base
// with Ethereum. WalletConnect projectId comes from env at deploy time;
// the dev placeholder lets local builds compile.
const config = getDefaultConfig({
  appName: "mirv",
  projectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID ?? "mirv_dev_placeholder",
  chains: [baseSepolia, sepolia, base, mainnet],
  transports: {
    [baseSepolia.id]: http(),
    [sepolia.id]:     http(),
    [base.id]:        http(),
    [mainnet.id]:     http(),
  },
  ssr: true,
});

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());

  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        {/* RainbowKit's lightTheme retunes to our cream/ink palette so the
         * connect modal doesn't look like Web3 default. */}
        <RainbowKitProvider
          theme={lightTheme({
            accentColor: "#ffd206",
            accentColorForeground: "#3a2c3a",
            borderRadius: "medium",
            fontStack: "system",
            overlayBlur: "small",
          })}
        >
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
