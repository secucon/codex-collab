import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { initRun, debateRound } from "../scripts/workflow.mjs";

const fake = fileURLToPath(new URL("./fake-app-server.mjs", import.meta.url));
const position = { stance: "candidate", reasoning: "evidence", key_points: ["point"], agrees_with_opponent: false, accepted_proposal_id: null, proposed_change: null };
function setup(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "collab-workflow-"));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const original = { ...process.env };
  process.env.CODEX_COLLAB_COMMAND = process.execPath;
  process.env.CODEX_COLLAB_ARGS = JSON.stringify([fake]);
  t.after(() => {
    for (const k of ["CODEX_COLLAB_COMMAND", "CODEX_COLLAB_ARGS", "FAKE_STRUCTURED", "FAKE_STATUS", "FAKE_REQUIRE_RESUME"]) {
      if (original[k] === undefined) delete process.env[k]; else process.env[k] = original[k];
    }
  });
  return root;
}
const put = (file, value) => fs.writeFileSync(file, JSON.stringify(value));

test("run allocation isolates concurrent invocations", t => {
  const root = setup(t);
  const a = initRun("ask", root), b = initRun("ask", root);
  assert.notEqual(a.runId, b.runId);
  assert.notEqual(a.dir, b.dir);
});

test("debate persists a blind round, resumes, and commits an explicitly shared proposal", async t => {
  const root = setup(t), { dir } = initRun("debate", root);
  fs.writeFileSync(path.join(dir, "topic.txt"), "Choose a design.");
  put(path.join(dir, "round-1-claude.json"), position);
  process.env.FAKE_STRUCTURED = JSON.stringify(position);
  const first = await debateRound(dir);
  assert.equal(first.status, "ready");
  assert.equal(first.consensus.consensus, false);
  const blind = fs.readFileSync(path.join(dir, "round-1-prompt.txt"), "utf8");
  assert.ok(!blind.includes(position.reasoning));
  const vote = { ...position, agrees_with_opponent: true, accepted_proposal_id: first.nextProposalId };
  put(path.join(dir, "round-2-claude.json"), vote);
  process.env.FAKE_STRUCTURED = JSON.stringify(vote);
  process.env.FAKE_REQUIRE_RESUME = "1";
  const second = await debateRound(dir);
  assert.equal(second.status, "completed");
  assert.equal(second.consensus.consensus, true);
  assert.deepEqual(second.agreedProposal, first.nextProposal);
  const state = JSON.parse(fs.readFileSync(path.join(dir, "state.json")));
  assert.equal(state.rounds.length, 2);
  assert.equal(state.threadId, "thread-1");
  await assert.rejects(debateRound(dir), /not ready/);
});

test("a failed turn stops the workflow without counting a round", async t => {
  const root = setup(t), { dir } = initRun("debate", root);
  fs.writeFileSync(path.join(dir, "topic.txt"), "Topic");
  put(path.join(dir, "round-1-claude.json"), position);
  process.env.FAKE_STRUCTURED = JSON.stringify(position);
  process.env.FAKE_STATUS = "interrupted";
  await assert.rejects(debateRound(dir), /interrupted/);
  const state = JSON.parse(fs.readFileSync(path.join(dir, "state.json")));
  assert.equal(state.status, "error");
  assert.equal(state.round, 0);
  await assert.rejects(debateRound(dir), /not ready/);
});

test("a held round lock prevents another invocation", async t => {
  const root = setup(t), { dir } = initRun("debate", root);
  fs.writeFileSync(path.join(dir, "round.lock"), "held");
  await assert.rejects(debateRound(dir), /EEXIST/);
  assert.equal(fs.readFileSync(path.join(dir, "round.lock"), "utf8"), "held");
});

test("five non-consensus rounds stop and are all persisted", async t => {
  const root = setup(t), { dir } = initRun("debate", root);
  fs.writeFileSync(path.join(dir, "topic.txt"), "Topic");
  process.env.FAKE_STRUCTURED = JSON.stringify(position);
  let result;
  for (let n = 1; n <= 5; n++) {
    put(path.join(dir, `round-${n}-claude.json`), position);
    result = await debateRound(dir);
  }
  assert.equal(result.status, "completed");
  assert.equal(result.consensus.consensus, false);
  assert.equal(result.consensus.capReached, true);
  assert.equal(result.agreedProposal, null);
  assert.equal(JSON.parse(fs.readFileSync(path.join(dir, "state.json"))).rounds.length, 5);
  await assert.rejects(debateRound(dir), /not ready/);
});
