import { test } from "node:test";
import assert from "node:assert/strict";
import { canaryPasses } from "../scripts/check-canary.mjs";

test("canary only tolerates explicit post-handshake authentication failures", () => {
  assert.equal(canaryPasses({ ok: true, phase: "turn-completed" }), true);
  assert.equal(canaryPasses({ ok: false, phase: "thread-started", codexErrorInfo: "Unauthorized" }), true);
  assert.equal(canaryPasses({ ok: false, phase: "initialized", error: "Not logged in" }), true);
  for (const phase of ["initialized", "thread-started", "spawned"]) {
    assert.equal(canaryPasses({ ok: false, phase, error: "Invalid params" }), false);
    assert.equal(canaryPasses({ ok: false, phase, error: "turn timed out" }), false);
  }
  assert.equal(canaryPasses({ ok: false, phase: "spawned", codexErrorInfo: "Unauthorized" }), false);
});
