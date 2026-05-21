import { describe, it, expect, beforeEach, afterEach } from "vitest";
import {
  saveToRedis, loadFromRedis, appendCycleHistory, loadCycleHistory, disconnectRedis,
} from "../src/tools/redis.js";

// The Redis client is supposed to gracefully no-op when REDIS_URL is unset
// or points at a placeholder (e.g. the .env.example value). The agent's
// production cycles should never crash because Redis happens to be misconfigured.
//
// These tests verify that behavior by manipulating process.env.REDIS_URL
// to known-placeholder values before each test.

describe("Redis placeholder URL handling", () => {
  let originalUrl: string | undefined;

  beforeEach(() => {
    originalUrl = process.env.REDIS_URL;
  });

  afterEach(async () => {
    await disconnectRedis();
    if (originalUrl === undefined) delete process.env.REDIS_URL;
    else process.env.REDIS_URL = originalUrl;
  });

  it("saveToRedis silently no-ops when REDIS_URL is unset", async () => {
    delete process.env.REDIS_URL;
    await expect(saveToRedis("any", { v: 1 })).resolves.toBeUndefined();
  });

  it("saveToRedis silently no-ops when REDIS_URL is the env.example placeholder", async () => {
    process.env.REDIS_URL = "redis://default:password@host:6379";
    await expect(saveToRedis("any", { v: 1 })).resolves.toBeUndefined();
  });

  it("saveToRedis silently no-ops when REDIS_URL is literally 'redis://...'", async () => {
    process.env.REDIS_URL = "redis://...";
    await expect(saveToRedis("any", { v: 1 })).resolves.toBeUndefined();
  });

  it("loadFromRedis returns null without throwing on placeholder URL", async () => {
    process.env.REDIS_URL = "redis://default:password@host:6379";
    const result = await loadFromRedis("any");
    expect(result).toBeNull();
  });

  it("appendCycleHistory silently no-ops on placeholder URL", async () => {
    process.env.REDIS_URL = "redis://default:password@host:6379";
    await expect(appendCycleHistory({
      cycle: 1, timestamp: Date.now(), imbalancePct: 0, actionTaken: false,
    })).resolves.toBeUndefined();
  });

  it("loadCycleHistory returns empty array on placeholder URL", async () => {
    process.env.REDIS_URL = "redis://default:password@host:6379";
    const history = await loadCycleHistory();
    expect(history).toEqual([]);
  });

  it("disconnectRedis is safe to call when no client was ever created", async () => {
    delete process.env.REDIS_URL;
    await expect(disconnectRedis()).resolves.toBeUndefined();
  });
});
