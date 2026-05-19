import { ImageResponse } from "next/og";

export const runtime = "edge";
export const alt = "mirv — cross-chain liquidity mirror";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default async function OG() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          alignItems: "flex-start",
          padding: "100px",
          background: "#fff8e7",
          fontFamily: "ui-rounded, system-ui, sans-serif",
        }}
      >
        <div
          style={{
            fontSize: 28,
            color: "#ef48aa",
            marginBottom: 24,
            letterSpacing: "0.05em",
          }}
        >
          ✿ deposit once, mirror everywhere
        </div>
        <div
          style={{
            fontSize: 144,
            color: "#3a2c3a",
            fontWeight: 800,
            lineHeight: 1,
            letterSpacing: "-0.03em",
          }}
        >
          cross-chain
        </div>
        <div
          style={{
            fontSize: 144,
            color: "#ef48aa",
            fontWeight: 800,
            lineHeight: 1,
            letterSpacing: "-0.03em",
            marginBottom: 32,
          }}
        >
          liquidity mirror.
        </div>
        <div
          style={{
            fontSize: 32,
            color: "#3a2c3a",
            opacity: 0.75,
            maxWidth: 900,
            lineHeight: 1.3,
          }}
        >
          deposit usdc on base. agents move your money where it earns more, across base + ethereum.
        </div>
        <div
          style={{
            position: "absolute",
            bottom: 80,
            right: 100,
            display: "flex",
            alignItems: "center",
            gap: 16,
            fontSize: 22,
            color: "#3a2c3a",
            opacity: 0.6,
          }}
        >
          <div
            style={{
              width: 14,
              height: 14,
              borderRadius: 7,
              background: "#aaf0d1",
            }}
          />
          live on testnet · mirv-frontend.vercel.app
        </div>
      </div>
    ),
    { ...size }
  );
}
