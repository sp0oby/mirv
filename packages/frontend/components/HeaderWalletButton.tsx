"use client";

import dynamic from "next/dynamic";

const ConnectButton = dynamic(
  () => import("@rainbow-me/rainbowkit").then((m) => m.ConnectButton),
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
    <ConnectButton
      accountStatus={{ smallScreen: "avatar", largeScreen: "address" }}
      chainStatus={{ smallScreen: "icon", largeScreen: "full" }}
      showBalance={{ smallScreen: false, largeScreen: false }}
      label="connect wallet"
    />
  );
}
