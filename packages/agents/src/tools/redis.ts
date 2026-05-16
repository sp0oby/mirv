import { Redis } from "ioredis";
import type { CycleRecord } from "../state.js";

let _redis: Redis | null = null;
let _redisAvailable = true;

function isPlaceholderUrl(url: string | undefined): boolean {
  if (!url) return true;
  return url.includes("password@host") || url === "" || url === "redis://...";
}

function getRedis(): Redis | null {
  if (!_redisAvailable) return null;
  if (_redis) return _redis;

  const url = process.env.REDIS_URL;
  if (isPlaceholderUrl(url)) {
    console.warn("[Redis] REDIS_URL not configured — history tracking disabled");
    _redisAvailable = false;
    return null;
  }

  try {
    _redis = new Redis(url!, {
      maxRetriesPerRequest: 1,
      lazyConnect: false,
      connectTimeout: 2000,
    });
    _redis.on("error", (err: Error) => {
      console.warn("[Redis] connection error:", err.message);
      _redisAvailable = false;
    });
    return _redis;
  } catch (err) {
    console.warn("[Redis] failed to connect:", err instanceof Error ? err.message : err);
    _redisAvailable = false;
    return null;
  }
}

const CYCLE_HISTORY_KEY = "mirror:cycle_history";
const MAX_HISTORY = 100;

export async function saveToRedis(key: string, value: unknown): Promise<void> {
  const r = getRedis();
  if (!r) return;
  try { await r.set(`mirror:${key}`, JSON.stringify(value)); } catch {}
}

export async function loadFromRedis<T>(key: string): Promise<T | null> {
  const r = getRedis();
  if (!r) return null;
  try {
    const raw = await r.get(`mirror:${key}`);
    return raw ? (JSON.parse(raw) as T) : null;
  } catch { return null; }
}

export async function appendCycleHistory(record: CycleRecord): Promise<void> {
  const r = getRedis();
  if (!r) return;
  try {
    await r.lpush(CYCLE_HISTORY_KEY, JSON.stringify(record));
    await r.ltrim(CYCLE_HISTORY_KEY, 0, MAX_HISTORY - 1);
  } catch {}
}

export async function loadCycleHistory(): Promise<CycleRecord[]> {
  const r = getRedis();
  if (!r) return [];
  try {
    const raw = await r.lrange(CYCLE_HISTORY_KEY, 0, -1);
    return raw.map((s: string) => JSON.parse(s) as CycleRecord);
  } catch { return []; }
}

export async function disconnectRedis(): Promise<void> {
  if (_redis) {
    try { await _redis.quit(); } catch {}
    _redis = null;
  }
}
