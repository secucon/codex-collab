// tests/fake-app-server.mjs
// A minimal executable that speaks the codex app-server JSONL protocol on stdio.
// Behavior is scripted via env:
//   FAKE_TURN_TEXT   - text returned as the final agentMessage
//   FAKE_TURN_ERROR  - if set, emit an `error` notification instead of completing
//   FAKE_STRUCTURED  - if set (JSON string), echoed as final agentMessage text
//   FAKE_ECHO_SCHEMA - if set, the final agentMessage text is the turn/start
//                      `outputSchema` param exactly as received, so a test can
//                      assert what the client actually sent to Codex
//   FAKE_EXIT_ON_TURN- if set, on turn/start the process exits WITHOUT a
//                      response, simulating codex crashing mid-turn
//   FAKE_STDOUT_BANNER- if set, print a non-JSON banner line to stdout BEFORE
//                      any protocol message, simulating a real CLI warning/banner
//   FAKE_NO_INIT_RESPONSE- if set, never answer `initialize`, simulating an
//                      unresponsive/wedged app-server at handshake
//   FAKE_HANG_TURN   - if set, ack turn/start but never send item/completed or
//                      turn/completed, simulating a turn that hangs forever
import readline from "node:readline";

function send(obj) { process.stdout.write(JSON.stringify(obj) + "\n"); }

// A stray non-JSON line on stdout must not break the protocol (skipped by the client).
if (process.env.FAKE_STDOUT_BANNER) process.stdout.write("warning: something non-JSON\n");

const rl = readline.createInterface({ input: process.stdin });
if (process.env.FAKE_IGNORE_TERM) {
  process.on("SIGTERM", () => {});
  setInterval(() => {}, 1000);
}
let threadSeq = 0;
let turnSeq = 0;
let finishRequest;
let threadOptions;

rl.on("line", (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  if (msg.id === "server-request" && !msg.method) {
    if (!msg.result && !msg.error) throw new Error("missing server request response");
    finishRequest?.(JSON.stringify(msg));
    return;
  }
  if (msg.method === "initialize") {
    if (process.env.FAKE_NO_INIT_RESPONSE) return; // wedged at handshake
    return send({ id: msg.id, result: { } });
  }
  if (msg.method === "initialized") return;
  if (msg.method === "turn/interrupt") return send({ id: msg.id, result: {} });
  if (msg.method === "thread/start" || msg.method === "thread/resume") {
    if (process.env.FAKE_REQUIRE_RESUME && msg.method !== "thread/resume") return send({ id: msg.id, error: { message: "expected thread/resume" } });
    threadOptions = msg.params;
    const id = msg.params.threadId ?? `thread-${++threadSeq}`;
    return send({ id: msg.id, result: { thread: { id } } });
  }
  if (msg.method === "turn/start") {
    if (process.env.FAKE_EXIT_ON_TURN) {
      // Crash mid-turn: exit WITHOUT sending the turn/start response.
      process.exit(1);
    }
    const threadId = msg.params.threadId;
    const turnId = `turn-${++turnSeq}`;
    send({ id: msg.id, result: { turn: { id: turnId } } });
    send({ method: "turn/started", params: { threadId, turn: { id: turnId } } });
    if (process.env.FAKE_HANG_TURN) return; // acked, then silence forever
    if (process.env.FAKE_TURN_ERROR) {
      send({ method: "error", params: { threadId, turnId, error: { message: process.env.FAKE_TURN_ERROR } } });
      return;
    }
    if (process.env.FAKE_RETRY_ERROR) send({ method: "error", params: { threadId, turnId, willRetry: true, error: { message: "retrying" } } });
    if (process.env.FAKE_UNRELATED) {
      send({ method: "item/completed", params: { threadId: "other", turnId, item: { type: "agentMessage", text: "wrong" } } });
      send({ method: "turn/completed", params: { threadId, turn: { id: "old-turn", status: "interrupted" } } });
    }
    const text = process.env.FAKE_ECHO_OPTIONS ? JSON.stringify({ model: threadOptions.model, sandbox: threadOptions.sandbox, effort: msg.params.effort })
      : process.env.FAKE_ECHO_SCHEMA ? JSON.stringify(msg.params.outputSchema)
      : process.env.FAKE_STRUCTURED ?? process.env.FAKE_TURN_TEXT ?? "ok";
    const finish = (answer = text) => {
      send({ method: "thread/tokenUsage/updated", params: { threadId, tokenUsage: { total: { totalTokens: 123 } } } });
      send({ method: "item/completed", params: { threadId, turnId, item: { type: "agentMessage", phase: "final_answer", text: answer } } });
      if (process.env.FAKE_COMMENTARY) send({ method: "item/completed", params: { threadId, turnId, item: { type: "agentMessage", phase: "commentary", text: "not the answer" } } });
      send({ method: "turn/completed", params: { threadId, turn: { id: turnId, status: process.env.FAKE_STATUS ?? "completed" } } });
    };
    if (process.env.FAKE_SERVER_REQUEST) {
      finishRequest = finish;
      send({ id: "server-request", method: process.env.FAKE_SERVER_REQUEST, params: { threadId, turnId } });
    } else finish();
    return;
  }
});
