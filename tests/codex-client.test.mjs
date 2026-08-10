// tests/codex-client.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const run = promisify(execFile);
const CLIENT = fileURLToPath(new URL("../scripts/codex-client.mjs", import.meta.url));
const FAKE = fileURLToPath(new URL("./fake-app-server.mjs", import.meta.url));

function tmp(name) { return path.join(fs.mkdtempSync(path.join(os.tmpdir(), "cc-")), name); }
function fakeEnv(extra = {}) {
  return { ...process.env, CODEX_COLLAB_COMMAND: process.execPath, CODEX_COLLAB_ARGS: JSON.stringify([FAKE]), ...extra };
}

test("turn writes threadId and text to --out", async () => {
  const promptFile = tmp("p.txt"); fs.writeFileSync(promptFile, "hi");
  const out = tmp("o.json");
  await run(process.execPath, [CLIENT, "turn", "--sandbox", "read-only", "--prompt-file", promptFile, "--out", out],
    { env: fakeEnv({ FAKE_TURN_TEXT: "answer" }) });
  const res = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.equal(res.text, "answer");
  assert.match(res.threadId, /^thread-/);
});

test("turn with --schema parses structured output", async () => {
  const promptFile = tmp("p.txt"); fs.writeFileSync(promptFile, "hi");
  const schema = tmp("s.json"); fs.writeFileSync(schema, '{"type":"object"}');
  const out = tmp("o.json");
  await run(process.execPath, [CLIENT, "turn", "--sandbox", "read-only", "--prompt-file", promptFile, "--schema", schema, "--out", out],
    { env: fakeEnv({ FAKE_STRUCTURED: '{"stance":"yes"}' }) });
  const res = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.deepEqual(res.structured, { stance: "yes" });
});

test("check reports ok against a working server", async () => {
  const out = tmp("o.json");
  await run(process.execPath, [CLIENT, "check", "--out", out], { env: fakeEnv() });
  const res = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.equal(res.ok, true);
});

test("check records phase=turn-completed on success (Item C)", async () => {
  const out = tmp("o.json");
  await run(process.execPath, [CLIENT, "check", "--out", out], { env: fakeEnv() });
  const res = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.equal(res.ok, true);
  assert.equal(res.phase, "turn-completed");
});

test("check records how far it got on a turn error: phase + ok:false (Item C)", async () => {
  const out = tmp("o.json");
  let err;
  try {
    await run(process.execPath, [CLIENT, "check", "--out", out],
      { env: fakeEnv({ FAKE_TURN_ERROR: "boom" }), timeout: 10000 });
  } catch (e) { err = e; }
  assert.ok(err, "check should exit non-zero on a turn error");
  const res = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.equal(res.ok, false);
  // The handshake WAS reached (initialize + thread/start succeeded); only the
  // turn failed -> phase reflects how far it got, not "spawned".
  assert.equal(res.phase, "thread-started");
  assert.match(res.error, /boom/);
});

test("turn writes an error marker to --out on turn failure and exits 1 (Item E)", async () => {
  const promptFile = tmp("p.txt"); fs.writeFileSync(promptFile, "hi");
  const out = tmp("o.json");
  // Pre-seed with a PRIOR round's result — the marker must overwrite it, not leave it stale.
  fs.writeFileSync(out, JSON.stringify({ threadId: "STALE", text: "old answer", structured: { x: 1 }, status: "completed" }));
  let err;
  try {
    await run(process.execPath, [CLIENT, "turn", "--sandbox", "read-only", "--prompt-file", promptFile, "--out", out],
      { env: fakeEnv({ FAKE_TURN_ERROR: "boom" }), timeout: 10000 });
  } catch (e) { err = e; }
  assert.ok(err, "turn should exit non-zero on a turn error");
  assert.ok(!err.killed, `turn must not be killed by timeout (it hung): signal=${err.signal}`);
  assert.equal(err.code, 1, `expected exit code 1, got code=${err.code} killed=${err.killed} signal=${err.signal}`);
  const res = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.equal(res.status, "error");
  assert.equal(res.structured, null);
  assert.match(res.error, /boom/);
});

test("check closes the client and exits promptly on a server error", async () => {
  const out = tmp("o.json");
  let err;
  try {
    await run(process.execPath, [CLIENT, "check", "--out", out],
      { env: fakeEnv({ FAKE_TURN_ERROR: "boom" }), timeout: 10000 });
  } catch (e) { err = e; }
  // With the bug (client never closed on the error path) the child stays alive,
  // the parent event loop never empties, and execFile kills it after `timeout`
  // → err.killed === true / SIGTERM. With the fix, close() runs in `finally`,
  // the process exits 1 quickly → err.code === 1, not killed.
  assert.ok(err, "check should exit non-zero on a server error");
  assert.ok(!err.killed, `check must not be killed by timeout (it hung): signal=${err.signal}`);
  assert.equal(err.code, 1, `expected exit code 1, got code=${err.code} killed=${err.killed} signal=${err.signal}`);
  const res = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.equal(res.ok, false);
  assert.match(res.error, /boom/);
});
