"use client";

import dynamic from "next/dynamic";

// RainbowKit's ConnectButton.Custom is a render-prop component — wrap it
// in dynamic({ssr:false}) so the wagmi-aware modal logic never touches SSR.
const RkCustom = dynamic(
  () => import("@rainbow-me/rainbowkit").then((m) => m.ConnectButton.Custom),
  {
    ssr: false,
    loading: () => (
      <button className="btn-win95 btn-win95-secondary text-[13px]" disabled>
        connect wallet
      </button>
    ),
  }
);

export function HeaderWalletButton() {
  return (
    <RkCustom>
      {({ account, chain, openAccountModal, openConnectModal, openChainModal, mounted }) => {
        const ready = mounted;
        const connected = ready && account && chain;

        if (!ready) return null;

        if (!connected) {
          return (
            <button
              onClick={openConnectModal}
              className="btn-win95 btn-win95-secondary text-[13px]"
            >
              connect wallet
            </button>
          );
        }

        // Wrong-network state — same Win95 chrome, pink ink to flag it.
        // Tapping opens the chain switcher so the user can fix it from any page.
        if (chain.unsupported) {
          return (
            <button
              onClick={openChainModal}
              className="btn-win95 btn-win95-secondary text-[13px]"
              style={{ color: "#ef48aa" }}
            >
              wrong network
            </button>
          );
        }

        // Connected, supported chain — just the address (or ENS), in our chrome.
        return (
          <button
            onClick={openAccountModal}
            className="btn-win95 btn-win95-secondary text-[13px] font-mono"
          >
            {account.displayName}
          </button>
        );
      }}
    </RkCustom>
  );
}
