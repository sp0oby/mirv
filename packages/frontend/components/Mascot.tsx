"use client";

import { useEffect, useRef } from "react";
import { motion } from "framer-motion";
import clsx from "clsx";

// `miri` — the mirv mascot. A small bookish round creature holding a hand
// mirror. Sleepy librarian energy, not flashy. Lives in: header (small),
// footer (small + interactive), 404, empty states, loading.
//
// Design lineage (kawaiicore-design §Mascot Integration):
//   - Round head, baby proportions
//   - Tiny round glasses ("the librarian" — bookish, calm, competent)
//   - Holds a small hand mirror (literally the protocol's name: mir-v -> mirror)
//   - Soft leaf-ear shape (not bunny, not sheep — protocol-flavored)
//   - 3 shades per color so a 64x64 sprite still reads as shaded, not flat
//     (kawaiicore-design §Animation §Tamagotchi feel)
//
// Idle motion follows kawaii-motion §1 Ambient:
//   - Tiny bob (1-2px) on a non-multiple-of-other-channels period
//   - Random blink every 4-8s (semi-random, never metronome)
//   - prefers-reduced-motion swaps to a single mount-time blink + static pose
//
// The component is intentionally self-contained — no external SVG assets —
// so the first paint is one round-trip and we can tweak the sprite by editing
// path data inline. If we ever want a "doodle" version (rough pen lines for
// the about page) it'll be a sibling component, not a prop on this one.

type Props = {
  size?: number;
  className?: string;
  /** When true, suppresses idle motion (use for static contexts like favicons-as-img). */
  static?: boolean;
};

export function Mascot({ size = 80, className, static: isStatic = false }: Props) {
  const leftEyeRef  = useRef<SVGEllipseElement | null>(null);
  const rightEyeRef = useRef<SVGEllipseElement | null>(null);

  useEffect(() => {
    if (isStatic) return;
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    // Recursive setTimeout (not setInterval) so each cycle's gap can be
    // independently random — see kawaii-motion §1 Ambient: "Random gaps,
    // not metronomes". Eyes desync by ~80ms so they don't blink in lockstep.
    let cancelled = false;
    const scheduleBlink = (eye: SVGEllipseElement | null, delay: number) => {
      if (cancelled || !eye) return;
      const next = 3200 + Math.random() * 5800;
      setTimeout(() => {
        if (cancelled || !eye) return;
        eye.style.transition = "transform 110ms ease-out";
        eye.style.transformOrigin = "center";
        eye.style.transform = "scaleY(0.05)";
        setTimeout(() => {
          if (!eye) return;
          eye.style.transform = "scaleY(1)";
          scheduleBlink(eye, next);
        }, 110);
      }, delay);
    };
    scheduleBlink(leftEyeRef.current, 1200);
    scheduleBlink(rightEyeRef.current, 1280);
    return () => { cancelled = true; };
  }, [isStatic]);

  return (
    <motion.span
      className={clsx("inline-block align-middle", className)}
      style={{ width: size, height: size }}
      animate={isStatic ? undefined : { y: [0, -2, 0] }}
      transition={isStatic ? undefined : { duration: 1.9, repeat: Infinity, ease: "easeInOut" }}
    >
      <svg viewBox="0 0 80 80" width={size} height={size} aria-hidden="true">
        {/* Shadow disc — keeps the bob from feeling rootless */}
        <ellipse cx="40" cy="72" rx="22" ry="3" fill="#3a2c3a" opacity="0.14" />

        {/* Body — cream sphere with a darker rim for shading */}
        <circle cx="40" cy="42" r="26" fill="#fdf6e3" stroke="#3a2c3a" strokeWidth="2" />
        {/* Inner shadow rim — bottom 30% */}
        <path
          d="M14 42a26 26 0 0 0 52 0"
          fill="none"
          stroke="#3a2c3a"
          strokeWidth="2"
          strokeLinecap="round"
          strokeDasharray="0 0"
          opacity="0.08"
          transform="translate(0,4)"
        />

        {/* Soft leaf ears — not bunny, not sheep */}
        <path d="M20 24c-4-2-7-7-5-12 4 0 9 4 9 9z" fill="#ffd1dc" stroke="#3a2c3a" strokeWidth="1.5" />
        <path d="M60 24c4-2 7-7 5-12-4 0-9 4-9 9z" fill="#ffd1dc" stroke="#3a2c3a" strokeWidth="1.5" />

        {/* Cheek blush */}
        <ellipse cx="25" cy="46" rx="4" ry="2.5" fill="#ffb280" opacity="0.7" />
        <ellipse cx="55" cy="46" rx="4" ry="2.5" fill="#ffb280" opacity="0.7" />

        {/* Tiny round glasses — bookish/librarian energy */}
        <g stroke="#3a2c3a" strokeWidth="1.5" fill="none">
          <circle cx="31" cy="40" r="5" />
          <circle cx="49" cy="40" r="5" />
          <line x1="36" y1="40" x2="44" y2="40" />
          <line x1="26" y1="40" x2="22" y2="38" />
          <line x1="54" y1="40" x2="58" y2="38" />
        </g>

        {/* Eyes — under the glasses, blink targets */}
        <ellipse ref={leftEyeRef}  cx="31" cy="40" rx="1.6" ry="1.8" fill="#3a2c3a" />
        <ellipse ref={rightEyeRef} cx="49" cy="40" rx="1.6" ry="1.8" fill="#3a2c3a" />

        {/* Small mouth — gentle u-curve, not a smile-line */}
        <path d="M37 50c1.5 1.5 4.5 1.5 6 0" stroke="#3a2c3a" strokeWidth="1.5" fill="none" strokeLinecap="round" />

        {/* Hand mirror — the protocol-name reference. Held lower-right.
         * The mirror surface uses mizuiro so it reads as "reflecting". */}
        <g transform="translate(50, 56) rotate(13)">
          <ellipse cx="0" cy="0" rx="6" ry="7" fill="#bde0fe" stroke="#3a2c3a" strokeWidth="1.5" />
          <ellipse cx="-1.4" cy="-1.6" rx="2.2" ry="2.6" fill="#fff8e7" opacity="0.7" />
          <rect x="-1.2" y="6" width="2.4" height="6" rx="1" fill="#ffd206" stroke="#3a2c3a" strokeWidth="1.2" />
        </g>
      </svg>
    </motion.span>
  );
}
