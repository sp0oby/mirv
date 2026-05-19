"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { useState } from "react";
import { WagmiProvider, createConfig } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider, connectorsForWallets, lightTheme } from "@rainbow-me/rainbowkit";
import {
  metaMaskWallet,
  rabbyWallet,
  coinbaseWallet,
  injectedWallet,
} from "@rainbow-me/rainbowkit/wallets";
import { base, baseSepolia, mainnet, sepolia } from "wagmi/chains";
import { http } from "viem";

// Hand-rolled wallet list. We INTENTIONALLY EXCLUDE walletConnectWallet
// because RainbowKit's default WalletConnect connector pulls in
// `@walletconnect/ethereum-provider` -> `@reown/appkit`, which together
// have ~5000+ modules and make Next 15's bundler stall indefinitely on
// this machine (verified twice — once in `next dev`, once in `next build`).
//
// Trade-off: mobile users can't QR-pair to mirv from a phone wallet
// browser. They CAN still use MetaMask Mobile / Coinbase Wallet via
// the wallet's built-in browser. For testnet+audit-prep this is fine.
// At mainnet we can revisit by either:
//   (a) waiting for the bundler issue to clear with a Next.js update
//   (b) running prod builds on a beefier machine (Vercel build runners)
//   (c) using a different mobile-pairing solution

const connectors = connectorsForWallets(
  [
    {
      groupName: "popular",
      wallets: [metaMaskWallet, rabbyWallet, coinbaseWallet, injectedWallet],
    },
  ],
  {
    appName: "mirv",
    projectId: process.env.NEXT_PUBLIC_WC_PROJECT_ID ?? "mirv_dev_placeholder",
  }
);

// Explicit RPC URLs — viem's default for mainnet is eth.merkle.io, which
// intermittently fails (POST eth.merkle.io ERR_FAILED in console). Use known
// stable public endpoints. Mainnet RPC is still needed for ENS resolution
// even though the protocol only operates on Sepolia chains today.
const config = createConfig({
  connectors,
  chains: [baseSepolia, sepolia, base, mainnet],
  transports: {
    [baseSepolia.id]: http("https://sepolia.base.org"),
    [sepolia.id]:     http("https://ethereum-sepolia.publicnode.com"),
    [base.id]:        http("https://mainnet.base.org"),
    [mainnet.id]:     http("https://ethereum.publicnode.com"),
  },
  ssr: false, // explicit — we only mount client-side via dynamic()
});

export function WalletProviders({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
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
