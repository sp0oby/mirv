import { describe, it, expect } from "vitest";
import { decideFulfillment } from "../src/withdrawal-fulfiller.js";

const req = (overrides: Partial<{ shares: bigint; fulfilled: boolean; cancelled: boolean }> = {}) => ({
  shares: 100n * 10n ** 6n,
  fulfilled: false,
  cancelled: false,
  ...overrides,
});

describe("decideFulfillment — withdrawal sweep decision logic", () => {
  it("returns 'fulfill' when vault has enough USDC and request is open", () => {
    const r = req();
    expect(decideFulfillment(r, 200n * 10n ** 6n, 100n * 10n ** 6n)).toBe("fulfill");
  });

  it("returns 'skip-already-fulfilled' when fulfilled flag is true (idempotency)", () => {
    const r = req({ fulfilled: true });
    expect(decideFulfillment(r, 200n * 10n ** 6n, 100n * 10n ** 6n)).toBe("skip-already-fulfilled");
  });

  it("returns 'skip-cancelled' when cancelled flag is true", () => {
    const r = req({ cancelled: true });
    expect(decideFulfillment(r, 200n * 10n ** 6n, 100n * 10n ** 6n)).toBe("skip-cancelled");
  });

  it("returns 'skip-zero-shares' when shares == 0 (defensive — invalid request)", () => {
    const r = req({ shares: 0n });
    expect(decideFulfillment(r, 200n * 10n ** 6n, 100n * 10n ** 6n)).toBe("skip-zero-shares");
  });

  it("returns 'needs-cross-chain-unwind' when vault USDC is short of assetsOwed", () => {
    const r = req();
    expect(decideFulfillment(r, 50n * 10n ** 6n, 100n * 10n ** 6n)).toBe("needs-cross-chain-unwind");
  });

  it("returns 'fulfill' at the exact-match boundary (balance == owed)", () => {
    const r = req();
    expect(decideFulfillment(r, 100n * 10n ** 6n, 100n * 10n ** 6n)).toBe("fulfill");
  });

  it("returns 'needs-cross-chain-unwind' when off-by-one-wei short", () => {
    const r = req();
    expect(decideFulfillment(r, 100n * 10n ** 6n - 1n, 100n * 10n ** 6n)).toBe("needs-cross-chain-unwind");
  });

  it("prioritizes fulfilled over cancelled (sanity: both true is technically impossible but logic must short-circuit)", () => {
    const r = req({ fulfilled: true, cancelled: true });
    expect(decideFulfillment(r, 200n * 10n ** 6n, 100n * 10n ** 6n)).toBe("skip-already-fulfilled");
  });

  it("prioritizes cancelled over shares==0", () => {
    const r = req({ cancelled: true, shares: 0n });
    expect(decideFulfillment(r, 200n * 10n ** 6n, 100n * 10n ** 6n)).toBe("skip-cancelled");
  });

  it("handles realistic large mainnet amounts (1M USDC = 1e12 raw)", () => {
    const r = req({ shares: 1_000_000n * 10n ** 6n });
    expect(decideFulfillment(r, 2_000_000n * 10n ** 6n, 1_000_000n * 10n ** 6n)).toBe("fulfill");
  });
});
