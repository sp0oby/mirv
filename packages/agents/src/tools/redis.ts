import { Redis } from "ioredis";
import type { CycleRecord } from "../state.js";

let _redis: Redis | null = null;

function getRedis(): Redis {
  if (!_redis) {
    _redis = new Redis(process.env.REDIS_URL!, { maxRetriesPerRequest: 3, lazyConnect: false });
    _redis.on("error", (err: Error) => console.error("[Redis]", err.message));
  }
  return _redis;
}

const CYCLE_HISTORY_KEY = "mirror:cycle_history";
const MAX_HISTORY       = 100;

export async function saveToRedis(key: string, value: unknown): Promise<void> {
  await getRedis().set(`mirror:${key}`, JSON.stringify(value));
}

export async function loadFromRedis<T>(key: string): Promise<T | null> {
  const raw = await getRedis().get(`mirror:${key}`);
  return raw ? (JSON.parse(raw) as T) : null;
}

export async function appendCycleHistory(record: CycleRecord): Promise<void> {
  const redis = getRedis();
  await redis.lpush(CYCLE_HISTORY_KEY, JSON.stringify(record));
  await redis.ltrim(CYCLE_HISTORY_KEY, 0, MAX_HISTORY - 1);
}

export async function loadCycleHistory(): Promise<CycleRecord[]> {
  const raw = await getRedis().lrange(CYCLE_HISTORY_KEY, 0, -1);
  return raw.map((r: string) => JSON.parse(r) as CycleRecord);
}

export async function disconnectRedis(): Promise<void> {
  if (_redis) {
    await _redis.quit();
    _redis = null;
  }
}
