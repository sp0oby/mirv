import Anthropic from "@anthropic-ai/sdk";

const client = new Anthropic({ apiKey: process.env.ANTHROPIC_API_KEY });

const MODEL = "claude-sonnet-4-6";

/**
 * Simple prompt → text response. Used by Rebalance / Coordinator / Risk agents.
 */
export async function callClaude(opts: {
  system: string;
  user: string;
  maxTokens?: number;
  agentLabel?: string;
}): Promise<string> {
  const label = opts.agentLabel ?? "claude";
  console.log(`  [${label}] invoking ${MODEL}...`);
  try {
    const res = await client.messages.create({
      model:       MODEL,
      max_tokens:  opts.maxTokens ?? 1024,
      temperature: 0,
      system:      opts.system,
      messages:    [{ role: "user", content: opts.user }],
    });

    const text = res.content
      .filter((b): b is Anthropic.Messages.TextBlock => b.type === "text")
      .map((b) => b.text)
      .join("\n");

    const usage = res.usage;
    console.log(`  [${label}] ✓ ${text.length} chars (in:${usage.input_tokens} out:${usage.output_tokens})`);
    return text;
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`  [${label}] ✗ ${msg}`);
    throw err;
  }
}

/**
 * Prompt + tools → tool-calling loop until the model produces a final text response.
 * Used by MonitorAgent.
 */
export async function callClaudeWithTools(opts: {
  system: string;
  user: string;
  tools: Anthropic.Messages.Tool[];
  toolHandlers: Record<string, (input: any) => Promise<unknown>>;
  maxTokens?: number;
  maxRounds?: number;
  agentLabel?: string;
}): Promise<string> {
  const label = opts.agentLabel ?? "claude-tools";
  const messages: Anthropic.Messages.MessageParam[] = [
    { role: "user", content: opts.user },
  ];
  const maxRounds = opts.maxRounds ?? 5;

  console.log(`  [${label}] invoking ${MODEL} with ${opts.tools.length} tools...`);

  for (let round = 0; round < maxRounds; round++) {
    const res = await client.messages.create({
      model:       MODEL,
      max_tokens:  opts.maxTokens ?? 1024,
      temperature: 0,
      system:      opts.system,
      tools:       opts.tools,
      messages,
    });

    if (res.stop_reason === "end_turn" || !res.content.some((b) => b.type === "tool_use")) {
      const text = res.content
        .filter((b): b is Anthropic.Messages.TextBlock => b.type === "text")
        .map((b) => b.text)
        .join("\n");
      console.log(`  [${label}] ✓ final response (${text.length} chars, round ${round + 1})`);
      return text;
    }

    // Append assistant turn (with tool_use blocks)
    messages.push({ role: "assistant", content: res.content });

    // Execute each tool call, append tool_result
    const toolResults: Anthropic.Messages.ToolResultBlockParam[] = [];
    for (const block of res.content) {
      if (block.type !== "tool_use") continue;
      const handler = opts.toolHandlers[block.name];
      let result: string;
      try {
        const out = handler ? await handler(block.input) : { error: `Unknown tool: ${block.name}` };
        result = JSON.stringify(out);
      } catch (err) {
        result = JSON.stringify({ error: err instanceof Error ? err.message : String(err) });
      }
      toolResults.push({
        type:        "tool_result",
        tool_use_id: block.id,
        content:     result,
      });
    }
    messages.push({ role: "user", content: toolResults });
  }

  throw new Error(`${label}: exceeded ${maxRounds} tool rounds without final response`);
}
