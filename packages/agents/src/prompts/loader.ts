import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));

/// Load a prompt file from this directory. Cached at module load time.
function load(name: string): string {
  return readFileSync(join(__dirname, `${name}.md`), "utf-8");
}

export const MONITOR_PROMPT     = load("monitor");
export const REBALANCE_PROMPT   = load("rebalance");
export const COORDINATOR_PROMPT = load("coordinator");
export const RISK_PROMPT        = load("risk");
