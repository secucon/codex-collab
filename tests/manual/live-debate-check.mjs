// Opt-in integration check: two authenticated read-only model turns, no file
// editing by Codex. The Claude-side position is a deterministic test fixture.
// Run: node tests/manual/live-debate-check.mjs
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { initRun, debateRound } from "../../scripts/workflow.mjs";
import { CodexAppServerClient } from "../../scripts/lib/app-server.mjs";

if (process.env.CODEX_COLLAB_COMMAND) throw new Error("Remove CODEX_COLLAB_COMMAND: this check must use the real Codex CLI");
process.env.CODEX_COLLAB_TURN_TIMEOUT_MS ??= "90000";
const root = fs.mkdtempSync(path.join(os.tmpdir(), "collab-live-debate-"));
process.chdir(root);
const version = execFileSync("codex", ["--version"], { encoding: "utf8" }).trim();
const events = new Set();
const original = CodexAppServerClient.prototype._handleNotification;
CodexAppServerClient.prototype._handleNotification = function (msg) {
  if (["item/completed", "turn/completed", "error", "thread/tokenUsage/updated"].includes(msg.method)) {
    events.add(JSON.stringify({ method: msg.method, threadId: typeof msg.params?.threadId,
      turnId: typeof (msg.params?.turnId ?? msg.params?.turn?.id), itemType: msg.params?.item?.type,
      phase: msg.params?.item?.phase, status: msg.params?.turn?.status, willRetry: msg.params?.willRetry }));
  }
  return original.call(this, msg);
};
const { dir } = initRun("debate");
const fixture = { stance: "Two plus two equals four.", reasoning: "Integer addition gives 2 + 2 = 4.", key_points: ["2 + 2 = 4"], proposed_change: null, agrees_with_opponent: false, accepted_proposal_id: null };
const write = (name, value) => fs.writeFileSync(path.join(dir, name), JSON.stringify(value, null, 2));
try {
  fs.writeFileSync(path.join(dir, "topic.txt"), "Evaluate only the mathematical claim: two plus two equals four. No repository work or tools are needed. Keep the response short; no file changes are proposed.");
  write("round-1-claude.json", fixture);
  const first = await debateRound(dir, { effort: "low" });
  assert.equal(first.status, "ready");
  const firstThread = JSON.parse(fs.readFileSync(path.join(dir, "state.json"))).threadId;
  write("round-2-claude.json", { ...fixture, agrees_with_opponent: true, accepted_proposal_id: first.nextProposalId });
  const second = await debateRound(dir, { effort: "low" });
  assert.equal(second.consensus.consensus, true);
  const state = JSON.parse(fs.readFileSync(path.join(dir, "state.json")));
  assert.equal(state.threadId, firstThread);
  assert.equal(state.rounds.length, 2);
  console.log(JSON.stringify({ ok: true, version, dir, rounds: 2, resumedSameThread: true, consensus: true }));
} finally {
  write("protocol-events.json", [...events].map(JSON.parse));
  console.log(JSON.stringify({ eventShapes: [...events].map(JSON.parse), artifacts: dir }));
  CodexAppServerClient.prototype._handleNotification = original;
}
