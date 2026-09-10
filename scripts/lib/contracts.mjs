// Domain checks for the bundled outputs. Custom --schema files are enforced by
// Codex's structured-output API; this is deliberately not a JSON Schema engine.
function object(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) throw new Error(`${label} must be an object`);
}
function strings(value, label) {
  if (!Array.isArray(value) || value.some(v => typeof v !== "string")) throw new Error(`${label} must be an array of strings`);
}
export function validatePosition(p, { validateVote = true } = {}) {
  object(p, "position");
  for (const key of ["stance", "reasoning"]) if (typeof p[key] !== "string" || !p[key].trim()) throw new Error(`position.${key} must be non-empty`);
  strings(p.key_points, "position.key_points");
  if (validateVote) {
    if (typeof p.agrees_with_opponent !== "boolean") throw new Error("position.agrees_with_opponent must be boolean");
    if (p.accepted_proposal_id !== null && (typeof p.accepted_proposal_id !== "string" || !/^[a-f0-9]{64}$/.test(p.accepted_proposal_id))) throw new Error("position.accepted_proposal_id must be a SHA-256 id or null");
    if (p.agrees_with_opponent !== (p.accepted_proposal_id !== null)) throw new Error("position agreement and accepted proposal id must match");
  }
  if (p.proposed_change != null) {
    object(p.proposed_change, "proposed_change");
    if (typeof p.proposed_change.summary !== "string" || !p.proposed_change.summary.trim()) throw new Error("proposed_change.summary must be non-empty");
    strings(p.proposed_change.files, "proposed_change.files");
  }
  return p;
}

// A completed analysis can contain a malformed vote. Never repair it into an
// acceptance: retain the raw vote and conservatively count it as not accepted.
// Body/transport failures still throw and stop the run.
export function normalizePositionVote(raw, expectedId) {
  validatePosition(raw, { validateVote: false });
  const originalVote = { agrees_with_opponent: raw.agrees_with_opponent, accepted_proposal_id: raw.accepted_proposal_id };
  const accepted = typeof expectedId === "string" && /^[a-f0-9]{64}$/.test(expectedId)
    && raw.agrees_with_opponent === true && raw.accepted_proposal_id === expectedId;
  const rejected = raw.agrees_with_opponent === false && raw.accepted_proposal_id === null;
  return {
    position: { ...raw, agrees_with_opponent: accepted, accepted_proposal_id: accepted ? expectedId : null },
    originalVote,
    warnings: accepted || rejected ? [] : ["Invalid or mismatched proposal vote counted as not accepted"],
  };
}
export function validateEvaluation(e) {
  object(e, "evaluation");
  if (typeof e.summary !== "string" || !Array.isArray(e.findings)) throw new Error("evaluation requires summary and findings");
  if (!Number.isFinite(e.confidence) || e.confidence < 0 || e.confidence > 1) throw new Error("evaluation confidence must be between 0 and 1");
  for (const f of e.findings) {
    object(f, "finding");
    if (!["info", "low", "medium", "high", "critical"].includes(f.severity) || typeof f.description !== "string") throw new Error("invalid evaluation finding");
    if (f.location != null && typeof f.location !== "string") throw new Error("finding location must be a string or null");
  }
  return e;
}
