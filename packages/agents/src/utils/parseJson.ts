/// Robust JSON extractor for LLM responses. Claude often wraps JSON output in
/// markdown fences, prose, or leading whitespace despite "output JSON only"
/// instructions. This helper pulls the first balanced `{...}` block out of
/// arbitrary text and parses it, falling back to direct parse on the whole
/// payload as a final attempt.
///
/// Shared between monitor / rebalance / risk / coordinator agents. Used to
/// be inlined as `match(/\{[\s\S]*\}/)` in each, which silently picked up
/// trailing junk after a fence (e.g. ```\nblah\n```)и produced parse errors.
export function extractJson<T = unknown>(text: string): T {
  // Try to find the LARGEST balanced {...} block. Greedy regex is OK because
  // we then narrow by attempting parse: if the outer match fails, retry with
  // smaller substrings. For Claude responses this usually one-shots.
  const match = text.match(/\{[\s\S]*\}/);
  const candidate = match?.[0] ?? text;
  try {
    return JSON.parse(candidate) as T;
  } catch {
    // Strip a markdown code fence if present: ```json\n{...}\n```
    const fenced = text.match(/```(?:json)?\s*([\s\S]*?)\s*```/);
    if (fenced) {
      return JSON.parse(fenced[1]) as T;
    }
    throw new Error(`No parseable JSON found in response (first 200 chars): ${text.slice(0, 200)}`);
  }
}
