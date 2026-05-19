"use client";

import { useEffect } from "react";

// Recursive setTimeout (not setInterval) so the spawn cadence stays
// "semi-random", not metronomic — kawaii-motion §1 Ambient.
//
// Element budget: ONE petal at a time visible. Two at most during overlap.
// Kawaii-motion §1 explicitly calls out the "sparkle confetti everywhere"
// curse; we go subtle so the page reads as "alive", not "decorated".

const PETAL_SVGS = [
  // Tape-strip petal — cream-pink, low-saturation
  "M10 0 Q14 6 10 12 Q6 6 10 0 Z",
  // Round bit — softer
  "M10 1 C14 1 16 4 16 8 C16 12 14 16 10 16 C6 16 4 12 4 8 C4 4 6 1 10 1 Z",
];

const COLORS = ["#ffd1dc", "#bde0fe", "#ffd206", "#aaf0d1", "#ffb280"];

export function AmbientPetals() {
  useEffect(() => {
    const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduced) return;

    let cancelled = false;
    let layer: HTMLDivElement | null = document.createElement("div");
    layer.id = "petal-layer";
    layer.style.cssText = `
      position: fixed; inset: 0; pointer-events: none; z-index: 1;
      overflow: hidden;
    `;
    document.body.appendChild(layer);

    function spawn() {
      if (cancelled || document.hidden || !layer) {
        scheduleNext();
        return;
      }
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
      const d = PETAL_SVGS[Math.floor(Math.random() * PETAL_SVGS.length)];
      const c = COLORS[Math.floor(Math.random() * COLORS.length)];
      path.setAttribute("d", d);
      path.setAttribute("fill", c);
      path.setAttribute("stroke", "#3a2c3a");
      path.setAttribute("stroke-width", "0.6");
      path.setAttribute("opacity", "0.55");
      svg.setAttribute("viewBox", "0 0 20 18");
      svg.setAttribute("width", "14");
      svg.setAttribute("height", "14");
      svg.appendChild(path);

      const startX = Math.random() * window.innerWidth;
      const driftX = (Math.random() - 0.5) * 120;
      const rot    = Math.random() * 720 - 360;
      const dur    = 9000 + Math.random() * 6000;

      svg.style.cssText = `
        position: absolute; top: -20px; left: ${startX}px;
        transform: translate(0, 0) rotate(0deg);
        transition: transform ${dur}ms linear, opacity 600ms ease-out;
        opacity: 0;
      `;
      layer.appendChild(svg);

      // Two-frame trick to ensure the transform: ... transition kicks in.
      requestAnimationFrame(() => {
        svg.style.opacity = "0.55";
        svg.style.transform = `translate(${driftX}px, ${window.innerHeight + 30}px) rotate(${rot}deg)`;
      });
      setTimeout(() => svg.remove(), dur + 1000);
      scheduleNext();
    }

    function scheduleNext() {
      if (cancelled) return;
      setTimeout(spawn, 2200 + Math.random() * 3800);
    }

    // First petal lands 1.5s after mount so the page paints cleanly first.
    setTimeout(spawn, 1500);

    return () => {
      cancelled = true;
      layer?.remove();
      layer = null;
    };
  }, []);

  return null;
}
