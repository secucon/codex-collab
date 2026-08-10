// tests/app-server.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { CodexAppServerClient } from "../scripts/lib/app-server.mjs";

const FAKE = fileURLToPath(new URL("./fake-app-server.mjs", import.meta.url));
function connectFake(env = {}) {
  return CodexAppServerClient.connect(process.cwd(), {
    command: process.execPath, args: [FAKE], env: { ...process.env, ...env }
  });
}

test("start thread then run a turn returns final text", async () => {
  const client = await connectFake({ FAKE_TURN_TEXT: "hello from codex" });
  const threadId = await client.startThread({ sandbox: "read-only" });
  assert.match(threadId, /^thread-/);
  const res = await client.runTurn(threadId, { prompt: "hi" });
  assert.equal(res.text, "hello from codex");
  assert.equal(res.status, "completed");
  await client.close();
});

test("resume reuses the given thread id", async () => {
  const client = await connectFake();
  const id = await client.resumeThread("thread-xyz", { sandbox: "read-only" });
  assert.equal(id, "thread-xyz");
  await client.close();
});

test("an error notification rejects the turn", async () => {
  const client = await connectFake({ FAKE_TURN_ERROR: "boom" });
  const threadId = await client.startThread({ sandbox: "read-only" });
  await assert.rejects(() => client.runTurn(threadId, { prompt: "x" }), /boom/);
  await client.close();
});

test("structured output is parsed when text is valid JSON", async () => {
  const client = await connectFake({ FAKE_STRUCTURED: '{"stance":"yes"}' });
  const threadId = await client.startThread({ sandbox: "read-only" });
  const res = await client.runTurn(threadId, { prompt: "x", outputSchema: { type: "object" } });
  assert.deepEqual(res.structured, { stance: "yes" });
  await client.close();
});
