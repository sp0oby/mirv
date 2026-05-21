import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { recordHeartbeat, startHeartbeatServer } from "../src/heartbeat.js";
import type { Server } from "node:http";

// Pick a high random-ish port so two parallel test files don't collide.
const PORT = 19_876;

async function fetchJson(path: string): Promise<{ status: number; body: any }> {
  const res = await fetch(`http://127.0.0.1:${PORT}${path}`);
  const body = await res.json();
  return { status: res.status, body };
}

describe("heartbeat /health endpoint", () => {
  let server: Server;

  beforeEach(() => {
    server = startHeartbeatServer(PORT);
  });

  afterEach(async () => {
    await new Promise<void>((resolve) => server.close(() => resolve()));
  });

  it("returns 200 booting in the first 2 minutes after start, before any cycle landed", async () => {
    const { status, body } = await fetchJson("/health");
    expect(status).toBe(200);
    expect(body.status).toBe("booting");
    expect(typeof body.bootAgeMs).toBe("number");
  });

  it("returns 200 ok after a fresh heartbeat is recorded", async () => {
    recordHeartbeat({ cycle: 1, maxImbalancePct: 0.5, actionTaken: false, errors: 0 });
    const { status, body } = await fetchJson("/health");
    expect(status).toBe(200);
    expect(body.status).toBe("ok");
    expect(body.lastCycle.cycle).toBe(1);
    expect(typeof body.ageMs).toBe("number");
    expect(body.ageMs).toBeLessThan(5000);
  });

  it("/ returns a full snapshot including bootedAt + uptime", async () => {
    recordHeartbeat({ cycle: 7, maxImbalancePct: 1.2, actionTaken: true, lastTxHash: "0xdeadbeef", errors: 0 });
    const { status, body } = await fetchJson("/");
    expect(status).toBe(200);
    expect(body.service).toBe("mirv agent swarm");
    expect(typeof body.bootedAt).toBe("number");
    expect(typeof body.uptimeMs).toBe("number");
    expect(body.lastCycle.cycle).toBe(7);
    expect(body.lastCycle.lastTxHash).toBe("0xdeadbeef");
    expect(body.lastCycle.actionTaken).toBe(true);
  });

  it("/status alias works", async () => {
    const { status, body } = await fetchJson("/status");
    expect(status).toBe(200);
    expect(body.service).toBe("mirv agent swarm");
  });

  it("unknown paths 404", async () => {
    const res = await fetch(`http://127.0.0.1:${PORT}/nope`);
    expect(res.status).toBe(404);
  });
});
