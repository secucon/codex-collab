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
import { evaluateConsensus } from "../scripts/consensus.mjs";

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

const agree = { agrees_with_opponent: true, key_points: ["a", "b"] };
const disagree = { agrees_with_opponent: false, key_points: ["a", "c", "d"] };

test("consensus true only when BOTH sides agree", () => {
  const r = evaluateConsensus(agree, agree, { round: 1, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r.consensus, true);
  const r2 = evaluateConsensus(agree, disagree, { round: 1, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r2.consensus, false);
});

test("consensus is false for either asymmetric disagreement", () => {
  // Claude disagrees, Codex agrees -> NOT consensus (guards claude side)
  assert.equal(evaluateConsensus(disagree, agree, { round: 1, defaultRounds: 3, maxExtra: 2 }).consensus, false);
  // Claude agrees, Codex disagrees -> NOT consensus (guards codex side)
  assert.equal(evaluateConsensus(agree, disagree, { round: 1, defaultRounds: 3, maxExtra: 2 }).consensus, false);
});

test("divergence is symmetric-difference size over key_points", () => {
  const r = evaluateConsensus(agree, disagree, { round: 1, defaultRounds: 3, maxExtra: 2 });
  // {a,b} vs {a,c,d} -> symmetric diff {b,c,d} = 3
  assert.equal(r.divergence, 3);
});

test("evaluateConsensus unwraps a codex-client wrapper on either side (Item A)", () => {
  const claudeRaw = { agrees_with_opponent: true, key_points: ["a", "b"] };
  // A codex-client WRAPPER: position fields live under `.structured`.
  const codexWrapper = {
    threadId: "t1",
    text: "...",
    structured: { agrees_with_opponent: true, key_points: ["a", "b"] },
    status: "completed"
  };
  const r = evaluateConsensus(claudeRaw, codexWrapper, { round: 1, defaultRounds: 3, maxExtra: 2 });
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
    structured: { agrees_with_opponent: true, key_points: ["a", "b"] },
    status: "completed"
  };
  const r2 = evaluateConsensus(claudeWrapper, codexWrapper, { round: 1, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r2.consensus, true);
  assert.equal(r2.divergence, 0);
});

test("evaluateConsensus refuses a failed turn instead of scoring it", () => {
  // codex-client writes this marker when a turn dies. Scoring it yields
  // key_points=[] and agrees_with_opponent=undefined, which reads as a normal
  // "divergence N, continue" — a crashed Codex would silently become a debate
  // round. The gate must refuse it.
  const failed = { threadId: null, text: "", structured: null, status: "error", error: "boom" };
  assert.throws(() => evaluateConsensus(agree, failed, { round: 1, defaultRounds: 3, maxExtra: 2 }),
    /codex .*(error|not usable)/i);
  assert.throws(() => evaluateConsensus(failed, agree, { round: 1, defaultRounds: 3, maxExtra: 2 }),
    /claude .*(error|not usable)/i);
});

test("evaluateConsensus refuses a wrapper whose structured output is missing", () => {
  // status can be "completed" while the model returned unparseable JSON —
  // codex-client sets structured to null in that case too.
  const noStructured = { threadId: "t1", text: "not json", structured: null, status: "completed" };
  assert.throws(() => evaluateConsensus(agree, noStructured, { round: 1, defaultRounds: 3, maxExtra: 2 }),
    /codex .*(structured|not usable)/i);
});

test("evaluateConsensus refuses a position missing the fields the gate scores", () => {
  // `structured: {}` or an array parses fine but has no agrees_with_opponent and
  // no key_points. Scored naively that is indistinguishable from an honest
  // disagreement, so a malformed round would quietly cost extra rounds.
  const empty = { threadId: "t1", text: "{}", structured: {}, status: "completed" };
  assert.throws(() => evaluateConsensus(agree, empty, { round: 1, defaultRounds: 3, maxExtra: 2 }),
    /codex .*(agrees_with_opponent|key_points|not usable)/i);
  const arr = { threadId: "t1", text: "[]", structured: [], status: "completed" };
  assert.throws(() => evaluateConsensus(agree, arr, { round: 1, defaultRounds: 3, maxExtra: 2 }),
    /codex .*not usable/i);
  assert.throws(() => evaluateConsensus({ key_points: ["a"] }, agree, { round: 1, defaultRounds: 3, maxExtra: 2 }),
    /claude .*(agrees_with_opponent|not usable)/i);
});

test("evaluateConsensus still accepts a raw position with no wrapper fields", () => {
  // Guard against the refusal above over-reaching: a bare position object has
  // no `status` and no `structured`, and must keep working.
  const r = evaluateConsensus(agree, agree, { round: 1, defaultRounds: 3, maxExtra: 2 });
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
  const r = evaluateConsensus(disagree, disagree, { round: 5, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r.capReached, true);
  // maxExtra 9 must clamp to 2 => cap still 5
  const r2 = evaluateConsensus(disagree, disagree, { round: 5, defaultRounds: 3, maxExtra: 9 });
  assert.equal(r2.capReached, true);
  // round 4 under cap 5 => not reached
  const r3 = evaluateConsensus(disagree, disagree, { round: 4, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r3.capReached, false);
});
