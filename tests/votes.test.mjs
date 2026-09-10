import { test } from "node:test";
import assert from "node:assert/strict";
import { normalizePositionVote } from "../scripts/lib/contracts.mjs";

const id = "a".repeat(64);
const body = { stance: "A", reasoning: "evidence", key_points: ["A"], proposed_change: null };
test("malformed, inconsistent and stale votes become explicit non-acceptance without mutating originals", () => {
  for (const vote of [
    { agrees_with_opponent: true, accepted_proposal_id: null },
    { agrees_with_opponent: true, accepted_proposal_id: "b" + id.slice(1) },
    { agrees_with_opponent: true, accepted_proposal_id: "g" + id.slice(1) },
    { agrees_with_opponent: false, accepted_proposal_id: id },
    { agrees_with_opponent: "true", accepted_proposal_id: id },
    { agrees_with_opponent: true, accepted_proposal_id: [id] }, {},
  ]) {
    const raw = { ...body, ...vote }, before = structuredClone(raw);
    const normalized = normalizePositionVote(raw, id);
    assert.equal(normalized.position.agrees_with_opponent, false);
    assert.equal(normalized.position.accepted_proposal_id, null);
    assert.equal(normalized.warnings.length, 1);
    assert.deepEqual(raw, before);
    assert.deepEqual(normalized.originalVote.accepted_proposal_id, raw.accepted_proposal_id);
  }
});
test("only an exact candidate vote accepts; blind round cannot accept", () => {
  const raw = { ...body, agrees_with_opponent: true, accepted_proposal_id: id };
  assert.equal(normalizePositionVote(raw, id).position.agrees_with_opponent, true);
  assert.equal(normalizePositionVote(raw, null).position.agrees_with_opponent, false);
  assert.deepEqual(normalizePositionVote({ ...body, agrees_with_opponent: false, accepted_proposal_id: null }, id).warnings, []);
});
test("damaged analysis bodies remain fatal", () => {
  for (const raw of [null, {}, { ...body, reasoning: null }, { ...body, key_points: [123] }]) {
    assert.throws(() => normalizePositionVote(raw, id));
  }
});
