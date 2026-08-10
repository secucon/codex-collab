// tests/fake-app-server.mjs
// A minimal executable that speaks the codex app-server JSONL protocol on stdio.
// Behavior is scripted via env:
//   FAKE_TURN_TEXT   - text returned as the final agentMessage
//   FAKE_TURN_ERROR  - if set, emit an `error` notification instead of completing
//   FAKE_STRUCTURED  - if set (JSON string), echoed as final agentMessage text
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
let threadSeq = 0;
let turnSeq = 0;

rl.on("line", (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  if (msg.method === "initialize") {
    if (process.env.FAKE_NO_INIT_RESPONSE) return; // wedged at handshake
    return send({ id: msg.id, result: { } });
  }
  if (msg.method === "initialized") return;
  if (msg.method === "thread/start" || msg.method === "thread/resume") {
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
      send({ method: "error", params: { error: { message: process.env.FAKE_TURN_ERROR } } });
      return;
    }
    const text = process.env.FAKE_STRUCTURED ?? process.env.FAKE_TURN_TEXT ?? "ok";
    send({ method: "item/completed", params: { threadId, item: { type: "agentMessage", phase: "final_answer", text } } });
    send({ method: "turn/completed", params: { threadId, turn: { id: turnId, status: "completed" } } });
    return;
  }
});
