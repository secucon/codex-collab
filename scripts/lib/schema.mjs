// scripts/lib/schema.mjs
//
// Codex/OpenAI structured-output STRICT mode accepts only a subset of JSON
// Schema. Our on-disk schemas double as human-readable contracts (and are
// asserted by tests/schemas.test.mjs), so they are normalized in memory here
// instead of being rewritten into a STRICT-only shape on disk.
//
// Verified live against a real Codex on 2026-08-16: without this normalizer the
// API rejects both schemas with 400 invalid_json_schema —
//   position.json:   "In context=('properties','proposed_change','type','0'),
//                     'additionalProperties' is required to be supplied and to be false."
//   evaluation.json: "In context=('properties','findings','items'), 'required' is
//                     required to be supplied and to be an array including every
//                     key in properties. Missing 'location'."

// Numeric range keywords (minimum/maximum/...) are deliberately left alone:
// verified live on 2026-08-16 that STRICT mode accepts them. Stripping them
// would widen the contract (evaluation.confidence 0..1 -> any number) for no
// gain.
//
// STRICT mode has no notion of an optional property: every key must be listed in
// `required`. A property that was optional therefore becomes required-but-nullable.
function makeNullable(node) {
  if (node === null || typeof node !== "object" || node.type === undefined) return;
  const types = Array.isArray(node.type) ? node.type : [node.type];
  if (!types.includes("null")) node.type = [...types, "null"];
  if (Array.isArray(node.enum) && !node.enum.includes(null)) node.enum = [...node.enum, null];
}

function walk(node) {
  if (node === null || typeof node !== "object") return;
  if (Array.isArray(node)) { node.forEach(walk); return; }
  if (node.properties && typeof node.properties === "object") {
    node.additionalProperties = false;
    const keys = Object.keys(node.properties);
    const required = Array.isArray(node.required) ? node.required : [];
    const added = keys.filter((k) => !required.includes(k));
    node.required = [...required, ...added];
    for (const k of added) makeNullable(node.properties[k]);
    for (const k of keys) walk(node.properties[k]);
  }
  if (node.items) walk(node.items);
}

/** Return a STRICT-mode-acceptable copy of `schema`. The input is never mutated. */
export function strictifySchema(schema) {
  const normalized = structuredClone(schema);
  delete normalized.version; // non-standard keyword; ours only, not JSON Schema's
  walk(normalized);
  return normalized;
}
