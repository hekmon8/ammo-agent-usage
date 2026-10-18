import assert from "node:assert/strict";
import test from "node:test";
import { dispatchPush } from "../src/push-dispatch.js";

test("alert-style dispatch forwards the alert style and keeps classification", async () => {
  const seen = [];
  const transport = { async send(token, environment, payload, style) { seen.push(style); return { status: 200 }; } };
  assert.deepEqual(await dispatchPush(transport, "synthetic-token", "production", { aps: { alert: { title: "t", body: "b" }, sound: "default" } }, "alert"), { kind: "sent" });
  assert.deepEqual(await dispatchPush(transport, "synthetic-token", "sandbox", { aps: { alert: {} } }, "alert"), { kind: "sent" });
  assert.deepEqual(seen, ["alert", "alert"]);
  // Default stays liveactivity so existing callers are unchanged.
  assert.deepEqual(await dispatchPush({ async send(_t, _e, _p, style) { assert.equal(style, "liveactivity"); return { status: 200 }; } }, "t", "sandbox", {}), { kind: "sent" });
});
