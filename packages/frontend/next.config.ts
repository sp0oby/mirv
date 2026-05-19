import type { NextConfig } from "next";

// Pinned to App Router; Turbopack dev for fast iteration on slower systems.
// Image optimizer disabled — every UI asset on this site is hand-placed SVG
// or a custom mascot; Next's auto-jpg-resampling pipeline buys us nothing
// and adds build cost.
const nextConfig: NextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  images: { unoptimized: true },
  experimental: {
    viewTransition: true,
  },
};

export default nextConfig;
