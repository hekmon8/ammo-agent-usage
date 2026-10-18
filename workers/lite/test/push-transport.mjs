import assert from "node:assert/strict";
import test from "node:test";
import { buildActivityPayload, dispatchPush } from "../src/push-dispatch.js";

test("PushTransport is injectable and classifies APNs terminal/backoff results", async () => {
  const statuses = [410, 429, 200, 401, 503];
  const transport = { async send(token, environment, payload) { assert.equal(token, "synthetic-token"); assert.equal(environment, "sandbox"); assert.equal(payload.aps.event, "update"); return { status: statuses.shift() }; } };
  assert.deepEqual(await dispatchPush(transport, "synthetic-token", "sandbox", { aps: { event: "update" } }), { kind: "disabled" });
  assert.deepEqual(await dispatchPush(transport, "synthetic-token", "sandbox", { aps: { event: "update" } }), { kind: "backoff" });
  assert.deepEqual(await dispatchPush(transport, "synthetic-token", "sandbox", { aps: { event: "update" } }), { kind: "sent" });
  assert.deepEqual(await dispatchPush(transport, "synthetic-token", "sandbox", { aps: { event: "update" } }), { kind: "failed" });
  assert.deepEqual(await dispatchPush(transport, "synthetic-token", "sandbox", { aps: { event: "update" } }), { kind: "failed" });
  assert.deepEqual(await dispatchPush({ async send() { return null; } }, "synthetic-token", "sandbox", {}), { kind: "unavailable" });
});

test("activity payload matches native content-state fields and clamps stale date", () => {
  const payload = buildActivityPayload({ windowId: "ignored", remainingBps: 6800, displayState: "fresh", observedAt: "2026-09-05T00:01:00.000Z", staleAt: "2026-09-05T00:10:00.000Z", resetsAt: "2026-09-05T03:00:00.000Z", label: "Codex · 5h", sequence: 42 }, "2026-09-05T00:05:00.000Z", 1788572400);
  assert.deepEqual(payload, { aps: { timestamp: 1788572400, event: "update", "content-state": { remainingBps: 6800, displayState: "fresh", observedAt: 1788566460, staleAt: 1788567000, resetsAt: 1788577200, label: "Codex · 5h", sequence: 42 }, "stale-date": 1788566700 } });
});
