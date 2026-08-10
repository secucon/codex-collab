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
