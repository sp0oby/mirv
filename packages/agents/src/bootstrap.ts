// Side-effect-only module: loads the repo-root .env BEFORE any other static
// import resolves. Must be the first `import` in src/index.ts so its top-level
// code runs before agents/monitor.ts (and similar) read process.env at module
// load time. Resolving the path relative to this file makes it cwd-independent
// — earlier we tried `import "dotenv/config"` which defaults to process.cwd(),
// silently loaded nothing when run from packages/agents, and left every
// downstream module with undefined env vars.
import { config as dotenvConfig } from "dotenv";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
dotenvConfig({ path: resolve(__dirname, "../../../.env") });
