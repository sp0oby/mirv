import { describe, it, expect, beforeEach } from "vitest";
import {
  recordUnwindInitiated, getInProgressUnwind, clearUnwind, inProgressCount,
  UNWIND_TIMEOUT_MS, _resetForTests,
} from "../src/unwind-state.js";

describe("unwind-state — in-progress CCTP unwind tracker", () => {
  beforeEach(() => {
    _resetForTests();
  });

  it("returns undefined for an unknown request", () => {
    expect(getInProgressUnwind("42")).toBeUndefined();
  });

  it("count is 0 initially", () => {
    expect(inProgressCount()).toBe(0);
  });

  it("records + retrieves in-progress unwinds", () => {
    recordUnwindInitiated("42", "ethereum", 1_000_000n);
    const rec = getInProgressUnwind("42");
    expect(rec).toBeDefined();
    expect(rec?.chain).toBe("ethereum");
    expect(rec?.amountUsdc).toBe(1_000_000n);
  });

  it("inProgressCount tracks records", () => {
    recordUnwindInitiated("42", "ethereum", 1_000_000n);
    recordUnwindInitiated("43", "bnb",      2_000_000n);
    expect(inProgressCount()).toBe(2);
  });

  it("clearUnwind removes a tracked record", () => {
    recordUnwindInitiated("42", "ethereum", 1_000_000n);
    expect(inProgressCount()).toBe(1);
    clearUnwind("42");
    expect(inProgressCount()).toBe(0);
    expect(getInProgressUnwind("42")).toBeUndefined();
  });

  it("auto-evicts past the timeout window", () => {
    const t0 = 1_000_000;
    recordUnwindInitiated("42", "ethereum", 1_000_000n, t0);
    // 1 minute past timeout
    const later = t0 + UNWIND_TIMEOUT_MS + 60_000;
    expect(getInProgressUnwind("42", later)).toBeUndefined();
    // Auto-eviction also reduces the count
    expect(inProgressCount()).toBe(0);
  });

  it("still returns the record at the exact timeout boundary (>, not >=)", () => {
    const t0 = 1_000_000;
    recordUnwindInitiated("42", "ethereum", 1_000_000n, t0);
    // Exactly at the boundary — still valid
    const atBoundary = t0 + UNWIND_TIMEOUT_MS;
    expect(getInProgressUnwind("42", atBoundary)).toBeDefined();
  });

  it("UNWIND_TIMEOUT_MS is 30 minutes (CCTP attestation + buffer)", () => {
    expect(UNWIND_TIMEOUT_MS).toBe(30 * 60 * 1000);
  });

  it("expectedFulfillByMs is initiatedAtMs + timeout", () => {
    const t0 = 5_000_000;
    recordUnwindInitiated("42", "ethereum", 1_000_000n, t0);
    const rec = getInProgressUnwind("42", t0)!;
    expect(rec.initiatedAtMs).toBe(t0);
    expect(rec.expectedFulfillByMs).toBe(t0 + UNWIND_TIMEOUT_MS);
  });

  it("records per request id — different ids tracked independently", () => {
    recordUnwindInitiated("42", "ethereum", 1_000_000n);
    recordUnwindInitiated("43", "ethereum", 2_000_000n);
    expect(getInProgressUnwind("42")?.amountUsdc).toBe(1_000_000n);
    expect(getInProgressUnwind("43")?.amountUsdc).toBe(2_000_000n);
  });

  it("overwriting an existing record updates its fields", () => {
    recordUnwindInitiated("42", "ethereum", 1_000_000n, 1000);
    recordUnwindInitiated("42", "bnb",       5_000_000n, 2000);
    const rec = getInProgressUnwind("42", 2000)!;
    expect(rec.chain).toBe("bnb");
    expect(rec.amountUsdc).toBe(5_000_000n);
    expect(rec.initiatedAtMs).toBe(2000);
  });
});
