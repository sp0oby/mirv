import { describe, it, expect, beforeEach } from "vitest";
import {
  recordRecenter, wasRecentRecenter, lastRecenterAt,
  RECENTER_COOLDOWN_SECONDS, _resetForTests,
} from "../src/recenter-cooldown.js";

describe("recenter-cooldown — per-chain throttle", () => {
  beforeEach(() => {
    _resetForTests();
  });

  it("returns false initially (no recenter recorded)", () => {
    expect(wasRecentRecenter("base")).toBe(false);
  });

  it("lastRecenterAt is undefined initially", () => {
    expect(lastRecenterAt("base")).toBeUndefined();
  });

  it("records + returns true immediately after a recenter", () => {
    recordRecenter("base");
    expect(wasRecentRecenter("base")).toBe(true);
  });

  it("lastRecenterAt returns the recorded timestamp", () => {
    const now = Date.now();
    recordRecenter("base", now);
    expect(lastRecenterAt("base")).toBe(now);
  });

  it("returns false after the default cooldown elapses", () => {
    const past = Date.now() - (RECENTER_COOLDOWN_SECONDS + 10) * 1000;
    recordRecenter("base", past);
    expect(wasRecentRecenter("base")).toBe(false);
  });

  it("respects a custom cooldown override", () => {
    // 30s cooldown, record 60s ago — should NOT be in cooldown
    const past = Date.now() - 60 * 1000;
    recordRecenter("base", past);
    expect(wasRecentRecenter("base", 30)).toBe(false);

    // 90s cooldown, record 60s ago — should be in cooldown
    expect(wasRecentRecenter("base", 90)).toBe(true);
  });

  it("tracks per-chain independently — recenter on base doesn't block ethereum", () => {
    recordRecenter("base");
    expect(wasRecentRecenter("base")).toBe(true);
    expect(wasRecentRecenter("ethereum")).toBe(false);
  });

  it("treats nowMs as injectable for deterministic testing", () => {
    const recordTime = 1_000_000;
    recordRecenter("base", recordTime);

    // 100 seconds later — within cooldown
    expect(wasRecentRecenter("base", 300, recordTime + 100 * 1000)).toBe(true);

    // 500 seconds later — past cooldown
    expect(wasRecentRecenter("base", 300, recordTime + 500 * 1000)).toBe(false);
  });

  it("boundary: exactly at the cooldown edge returns false", () => {
    const recordTime = 1_000_000;
    recordRecenter("base", recordTime);
    // Exactly cooldown seconds later — age = cooldown, NOT less than
    expect(wasRecentRecenter("base", 300, recordTime + 300_000)).toBe(false);
  });

  it("default cooldown is 300 seconds (5 minutes)", () => {
    expect(RECENTER_COOLDOWN_SECONDS).toBe(300);
  });

  it("recording twice updates the timestamp", () => {
    const first  = 1_000_000;
    const second = 1_500_000;
    recordRecenter("base", first);
    recordRecenter("base", second);
    expect(lastRecenterAt("base")).toBe(second);
  });
});
