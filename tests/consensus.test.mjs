// tests/consensus.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseArgs } from "../scripts/lib/args.mjs";
import { evaluateConsensus, proposalId } from "../scripts/consensus.mjs";

const run = promisify(execFile);
const GATE = fileURLToPath(new URL("../scripts/consensus.mjs", import.meta.url));
function tmp(name) { return path.join(fs.mkdtempSync(path.join(os.tmpdir(), "cc-")), name); }

test("parseArgs reads flags and values", () => {
  const out = parseArgs(
    ["--verbose", "--out", "x.json", "--round", "2"],
    { flags: ["verbose"], values: ["out", "round"] }
  );
  assert.equal(out.verbose, true);
  assert.equal(out.out, "x.json");
  assert.equal(out.round, "2");
});

test("parseArgs throws on unknown option", () => {
  assert.throws(() => parseArgs(["--nope"], { flags: [], values: [] }), /unknown option/i);
});

const proposal = { stance: "shared candidate" };
const accepted_proposal_id = proposalId(proposal);
const agree = { accepted_proposal_id, agrees_with_opponent: true, key_points: ["a", "b"] };
const disagree = { agrees_with_opponent: false, key_points: ["a", "c", "d"] };

test("consensus true only when BOTH sides agree", () => {
  const r = evaluateConsensus(agree, agree, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r.consensus, true);
  const r2 = evaluateConsensus(agree, disagree, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r2.consensus, false);
});

test("consensus is false for either asymmetric disagreement", () => {
  // Claude disagrees, Codex agrees -> NOT consensus (guards claude side)
  assert.equal(evaluateConsensus(disagree, agree, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 }).consensus, false);
  // Claude agrees, Codex disagrees -> NOT consensus (guards codex side)
  assert.equal(evaluateConsensus(agree, disagree, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 }).consensus, false);
});

test("divergence is symmetric-difference size over key_points", () => {
  const r = evaluateConsensus(agree, disagree, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 });
  // {a,b} vs {a,c,d} -> symmetric diff {b,c,d} = 3
  assert.equal(r.divergence, 3);
});

test("evaluateConsensus unwraps a codex-client wrapper on either side (Item A)", () => {
  const claudeRaw = { accepted_proposal_id, agrees_with_opponent: true, key_points: ["a", "b"] };
  // A codex-client WRAPPER: position fields live under `.structured`.
  const codexWrapper = {
    threadId: "t1",
    text: "...",
    structured: { accepted_proposal_id, agrees_with_opponent: true, key_points: ["a", "b"] },
    status: "completed"
  };
  const r = evaluateConsensus(claudeRaw, codexWrapper, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 });
  // Old top-level read: codexWrapper.agrees_with_opponent === undefined -> consensus false.
  // Unwrapped: structured.agrees_with_opponent === true on both sides -> consensus true.
  assert.equal(r.consensus, true);
  // Divergence must come from the STRUCTURED key_points {a,b} vs {a,b} = 0.
  // If the codex side were treated as empty (old bug), divergence would be 2.
  assert.equal(r.divergence, 0);

  // Mirror: the claude side is unwrapped too.
  const claudeWrapper = {
    threadId: "t2",
    text: "...",
    structured: { accepted_proposal_id, agrees_with_opponent: true, key_points: ["a", "b"] },
    status: "completed"
  };
  const r2 = evaluateConsensus(claudeWrapper, codexWrapper, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r2.consensus, true);
  assert.equal(r2.divergence, 0);
});

test("evaluateConsensus refuses a failed turn instead of scoring it", () => {
  // codex-client writes this marker when a turn dies. Scoring it yields
  // key_points=[] and agrees_with_opponent=undefined, which reads as a normal
  // "divergence N, continue" — a crashed Codex would silently become a debate
  // round. The gate must refuse it.
  const failed = { threadId: null, text: "", structured: null, status: "error", error: "boom" };
  assert.throws(() => evaluateConsensus(agree, failed, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 }),
    /codex .*(error|not usable)/i);
  assert.throws(() => evaluateConsensus(failed, agree, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 }),
    /claude .*(error|not usable)/i);
});

test("evaluateConsensus refuses a wrapper whose structured output is missing", () => {
  // status can be "completed" while the model returned unparseable JSON —
  // codex-client sets structured to null in that case too.
  const noStructured = { threadId: "t1", text: "not json", structured: null, status: "completed" };
  assert.throws(() => evaluateConsensus(agree, noStructured, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 }),
    /codex .*(structured|not usable)/i);
});

test("evaluateConsensus refuses a position missing the fields the gate scores", () => {
  // `structured: {}` or an array parses fine but has no agrees_with_opponent and
  // no key_points. Scored naively that is indistinguishable from an honest
  // disagreement, so a malformed round would quietly cost extra rounds.
  const empty = { threadId: "t1", text: "{}", structured: {}, status: "completed" };
  assert.throws(() => evaluateConsensus(agree, empty, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 }),
    /codex .*(agrees_with_opponent|key_points|not usable)/i);
  const arr = { threadId: "t1", text: "[]", structured: [], status: "completed" };
  assert.throws(() => evaluateConsensus(agree, arr, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 }),
    /codex .*not usable/i);
  assert.throws(() => evaluateConsensus({ key_points: ["a"] }, agree, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 }),
    /claude .*(agrees_with_opponent|not usable)/i);
});

test("evaluateConsensus still accepts a raw position with no wrapper fields", () => {
  // Guard against the refusal above over-reaching: a bare position object has
  // no `status` and no `structured`, and must keep working.
  const r = evaluateConsensus(agree, agree, { proposal, round: 1, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r.consensus, true);
});

test("consensus CLI exits 1 and overwrites --out with a stop marker on a failed turn", async () => {
  const claude = tmp("c.json"); fs.writeFileSync(claude, JSON.stringify(agree));
  const codex = tmp("x.json");
  fs.writeFileSync(codex, JSON.stringify({ threadId: null, text: "", structured: null, status: "error", error: "boom" }));
  const out = tmp("o.json");
  // A PRIOR round's verdict sits at --out; it must not survive a failed run.
  fs.writeFileSync(out, JSON.stringify({ consensus: true, divergence: 0, capReached: false, reason: "both sides agree" }));
  let err;
  try {
    await run(process.execPath, [GATE, "--claude", claude, "--codex", codex, "--round", "1",
      "--default-rounds", "3", "--max-extra", "2", "--out", out], { timeout: 10000 });
  } catch (e) { err = e; }
  assert.ok(err, "consensus should exit non-zero when a side is unusable");
  assert.equal(err.code, 1);
  const res = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.equal(res.status, "error");
  assert.match(res.error, /boom/);
  // A round that cannot be scored must stop the loop, not read as "continue".
  assert.equal(res.consensus, false);
  assert.equal(res.capReached, true);
});

test("cap is default + min(extra,2), clamped", () => {
  // round 5 with defaultRounds 3, maxExtra 2 => cap 5 => capReached true
  const r = evaluateConsensus(disagree, disagree, { proposal, round: 5, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r.capReached, true);
  // maxExtra 9 must clamp to 2 => cap still 5
  const r2 = evaluateConsensus(disagree, disagree, { proposal, round: 5, defaultRounds: 3, maxExtra: 9 });
  assert.equal(r2.capReached, true);
  // round 4 under cap 5 => not reached
  const r3 = evaluateConsensus(disagree, disagree, { proposal, round: 4, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r3.capReached, false);
});

test("swapping old positions cannot establish consensus without a shared candidate vote", () => {
  const a = { stance: "B", agrees_with_opponent: true, key_points: ["B"] };
  const b = { stance: "A", agrees_with_opponent: true, key_points: ["A"] };
  assert.equal(evaluateConsensus(a, b, { round: 2, defaultRounds: 3, maxExtra: 2 }).consensus, false);
  assert.equal(evaluateConsensus(a, b, { proposal, round: 2, defaultRounds: 3, maxExtra: 2 }).consensus, false);
});

test("votes on distinct or changed candidates cannot establish consensus", () => {
  const opts = { proposal, round: 2, defaultRounds: 3, maxExtra: 2 };
  assert.equal(evaluateConsensus(agree, { ...agree, accepted_proposal_id: "other" }, opts).consensus, false);
  assert.equal(evaluateConsensus(agree, agree, { ...opts, proposal: { stance: "changed" } }).consensus, false);
  assert.equal(proposalId({ a: 1, b: 2 }), proposalId({ b: 2, a: 1 }));
});

test("interrupted and failed wrappers are unusable even with complete structured output", () => {
  for (const status of ["interrupted", "failed", undefined]) {
    assert.throws(() => evaluateConsensus(agree, { status, structured: agree }, { proposal, round: 2, defaultRounds: 3 }), /not usable/);
  }
});

test("invalid numeric round limits are rejected", () => {
  for (const round of [NaN, Infinity, 0, -1, 1.5]) {
    assert.throws(() => evaluateConsensus(disagree, disagree, { round, defaultRounds: 3 }), /integer/);
  }
  assert.throws(() => evaluateConsensus(disagree, disagree, { round: 1, defaultRounds: NaN }), /integer/);
});
