// tests/consensus.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseArgs } from "../scripts/lib/args.mjs";
import { evaluateConsensus } from "../scripts/consensus.mjs";

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
