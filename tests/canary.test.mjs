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

test("real CLI 401 credential error is tolerated, unrelated failures are not", () => {
  const error = "unexpected status 401 Unauthorized: Missing bearer or basic authentication in header, url: https://api.openai.com/v1/responses, cf-ray: a38be1fd5c6f2096-IAD, request id: req_example";
  const result = { ok: false, phase: "thread-started", codexErrorInfo: "other", error };
  assert.equal(canaryPasses(result), true);
  for (const replacement of [
    error.replace("401", "403"), error.replace("401", "500"),
    error.replace("Missing bearer or basic authentication in header", "Invalid request schema"),
    "turn timed out after an earlier " + error,
    error.replace("https://api.openai.com", "https://unrelated.example"),
  ]) assert.equal(canaryPasses({ ...result, error: replacement }), false);
  assert.equal(canaryPasses({ ...result, phase: "spawned" }), false);
});
