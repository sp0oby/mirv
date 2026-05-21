import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
    // Tests run against the same TypeScript source the runtime uses (no
    // separate compile step). Match the agent's own ESM/.js extension
    // convention so module resolution lines up.
    typecheck: {
      tsconfig: "./tsconfig.json",
    },
  },
});
