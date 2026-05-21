import { describe, it, expect } from "vitest";
import { extractJson } from "../src/utils/parseJson.js";

interface Sample { action: string; reasoning: string }

describe("extractJson — LLM response parser", () => {
  it("parses a clean JSON-only response", () => {
    const out = extractJson<Sample>(`{"action":"rebalance","reasoning":"ok"}`);
    expect(out.action).toBe("rebalance");
    expect(out.reasoning).toBe("ok");
  });

  it("parses JSON with leading prose", () => {
    const out = extractJson<Sample>(
      `Here's my decision:\n{"action":"none","reasoning":"steady"}`
    );
    expect(out.action).toBe("none");
  });

  it("parses JSON with trailing prose", () => {
    const out = extractJson<Sample>(
      `{"action":"rebalance","reasoning":"shift"}\nDone — anything else?`
    );
    expect(out.action).toBe("rebalance");
  });

  it("parses JSON wrapped in a markdown fence", () => {
    const out = extractJson<Sample>(
      "```json\n{\"action\":\"recenter\",\"reasoning\":\"drift\"}\n```"
    );
    expect(out.action).toBe("recenter");
  });

  it("parses JSON wrapped in a plain fence (no language tag)", () => {
    const out = extractJson<Sample>(
      "```\n{\"action\":\"none\",\"reasoning\":\"meh\"}\n```"
    );
    expect(out.action).toBe("none");
  });

  it("handles nested JSON objects", () => {
    interface Nested { outer: { inner: { value: number } } }
    const out = extractJson<Nested>(`{"outer":{"inner":{"value":42}}}`);
    expect(out.outer.inner.value).toBe(42);
  });

  it("preserves stringified bigints (the rebalance proposal pattern)", () => {
    interface Prop { deltaToken0: string; deltaToken1: string }
    const out = extractJson<Prop>(
      `{"deltaToken0":"1000000000000000000","deltaToken1":"-500000"}`
    );
    expect(out.deltaToken0).toBe("1000000000000000000");
    expect(out.deltaToken1).toBe("-500000");
  });

  it("throws a clear error when there is no JSON at all", () => {
    expect(() => extractJson(
      "Sorry, I cannot answer this question."
    )).toThrow(/No parseable JSON found/);
  });

  it("throws when the captured block isn't valid JSON", () => {
    expect(() => extractJson(
      "{this is not JSON, missing quotes around keys}"
    )).toThrow(/No parseable JSON found/);
  });

  it("truncates long inputs in error message (avoids log spam)", () => {
    const huge = "x".repeat(5000);
    try {
      extractJson(huge);
      expect.fail("should have thrown");
    } catch (e) {
      expect((e as Error).message.length).toBeLessThan(400);
    }
  });
});
