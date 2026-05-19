import type { Config } from "tailwindcss";

// Kawaiicore design tokens (sources: dark-chibi/SKILL.md + kawaiicore-design/SKILL.md).
// The palette deliberately picks Heisei pastel-on-cream as the base and reserves
// the wolf/dark register as accent-only — mirv is a financial product, not a
// player game, so the substrate stays warm + paper-like with the dark anchor
// providing legibility and gravitas.
//
// Why these specific values:
//   `paper`         — `#fff8e7`. Cream substrate (kawaiicore §Color §Pastel-on-cream).
//                     Replaces `#fff` everywhere; instantly leaves SaaS template land.
//   `paper-warm`    — `#fdf6e3`. Slightly cooler cream for nested frames.
//   `ink`           — `#3a2c3a`. Mauve-charcoal anchor; the dark text color.
//                     We never use #000.
//   `ink-soft`      — `#5a4858`. For secondary text + borders.
//   `pink`          — `#ffd1dc` / `#ffc1cc`. Warm pink (NOT the cool `pink-50` SaaS default).
//   `mizuiro`       — `#bde0fe` / `#a2d2ff`. Pale baby blue.
//   `mint`          — `#c8f7c5` / `#aaf0d1`. Pale mint for sister-chain accents.
//   `marigold`      — `#ffd206`. Heisei pop accent — used for "active" states + small
//                     stamps. Single saturated punch on the cream substrate.
//   `peach`         — `#ffb280`. Warm secondary accent.
//   `wolf-*`        — Tiny dark-chibi palette reserved for the agent-activity
//                     "predator pause -> sharp dispatch" register only. Never the dominant.
//   `border-image`  — Used by the lace/scallop nested border vocabulary.

export default {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        paper: {
          DEFAULT: "#fff8e7",
          warm: "#fdf6e3",
          deep: "#fff5d6",
        },
        ink: {
          DEFAULT: "#3a2c3a",
          soft: "#5a4858",
          faint: "#8b7a8b",
        },
        pink: {
          DEFAULT: "#ffd1dc",
          deep: "#ffc1cc",
          hot: "#ef48aa",
        },
        mizuiro: {
          DEFAULT: "#bde0fe",
          deep: "#a2d2ff",
        },
        mint: {
          DEFAULT: "#c8f7c5",
          deep: "#aaf0d1",
        },
        marigold: "#ffd206",
        peach: "#ffb280",
        // Reserved for agent-activity accent ONLY. Never the dominant palette.
        wolf: {
          dark: "#1a0d12",
          plum: "#2a1a26",
          blood: "#d63b5e",
        },
      },
      fontFamily: {
        // Display marker — heavy, hand-drawn, used for site title + section headers.
        display: ["Yusei Magic", "ui-serif", "Georgia", "serif"],
        // Maru Gothic — the canonical kawaii UI face. Rounded sans for nav, headings.
        maru: ["Klee One", "Zen Maru Gothic", "M PLUS Rounded 1c", "ui-sans-serif", "system-ui", "sans-serif"],
        // Body — Georgia is the period-correct fallback for personal-site era.
        body: ["Georgia", "ui-serif", "Cambria", "serif"],
        // Pixel font for stat readouts. MUST be sized at its native 10-11px,
        // never anti-aliased upward.
        pixel: ["Pixelify Sans", "monospace"],
        // Monospace for tx hashes / addresses / numeric stats.
        mono: ["JetBrains Mono", "ui-monospace", "Menlo", "monospace"],
      },
      borderRadius: {
        // Heisei-era bevels — softer than Tailwind defaults.
        sticker: "14px",
        polaroid: "4px",
        stamp: "2px",
      },
      keyframes: {
        // Idle channels — see /Users/brandonmccall/Desktop/here/SKILL.md §Ambient.
        // Periods are deliberately non-multiples so they don't sync up (one of
        // the AI-motion tells the kawaii-motion skill calls out).
        heartbeat: {
          "0%, 100%": { transform: "scale(1)" },
          "50%": { transform: "scale(1.035)" },
        },
        "breathe-bg": {
          "0%, 100%": { transform: "translateY(0)" },
          "50%": { transform: "translateY(-2px)" },
        },
        "kawaii-bob": {
          "0%, 100%": { transform: "translateY(0)" },
          "50%": { transform: "translateY(-3px)" },
        },
      },
      animation: {
        heartbeat: "heartbeat 1800ms ease-in-out infinite",
        "breathe-bg": "breathe-bg 7300ms ease-in-out infinite",
        "kawaii-bob": "kawaii-bob 1900ms ease-in-out infinite",
      },
    },
  },
  plugins: [],
} satisfies Config;
