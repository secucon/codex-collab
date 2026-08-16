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
//
// DESIGN: normalize what can be normalized without changing meaning; REFUSE
// everything else. The two rewrites this module performs — closing an object and
// promoting optional properties to required-but-nullable — are meaning-preserving
// only in plain `properties`/`items`/union positions. Applied inside an
// applicator they change what the schema MATCHES: closing each `allOf` branch
// makes an intersection of differing branches unsatisfiable, and forcing
// `required` inside an `if` inverts the condition for an absent key. So a schema
// using those keywords throws here, where the message is actionable, rather than
// being silently altered or bounced by the API with a bare 400.
//
// Numeric range keywords (minimum/maximum/...) are deliberately left alone:
// verified live on 2026-08-16 that STRICT mode accepts them. Stripping them
// would widen the contract (evaluation.confidence 0..1 -> any number) for no gain.
//
// `$ref` targets are never resolved or inlined. A local ref is normalized only
// because `$defs`/`definitions` are traversed in their own right; a ref pointing
// outside the document is left untouched. Traversing a keyword also does not make
// STRICT mode support it.

// Keywords whose value is a map of name -> subschema.
const MAP_KEYWORDS = ["properties", "$defs", "definitions"];
// Keywords whose value is an array of subschemas.
const LIST_KEYWORDS = ["anyOf", "oneOf", "prefixItems"];
// Keywords whose value is a single subschema.
const SCHEMA_KEYWORDS = ["items"];
// Keywords this normalizer cannot touch without changing what the schema matches.
const REFUSED_KEYWORDS = [
  "allOf", "not", "if", "then", "else", "contains", "propertyNames",
  "patternProperties", "dependentSchemas", "dependencies",
  "unevaluatedProperties", "unevaluatedItems", "additionalItems", "contentSchema",
];

function refuse(what, path) {
  throw new Error(`cannot normalize schema for STRICT mode: ${what} at ${path}`);
}

function typesOf(node) {
  if (node.type === undefined) return [];
  return Array.isArray(node.type) ? node.type : [node.type];
}

function allowsNull(node) {
  if (node === null || typeof node !== "object") return false;
  if (typesOf(node).includes("null")) return true;
  return Array.isArray(node.enum) && node.enum.includes(null);
}

// STRICT mode has no notion of an optional property: every key must be listed in
// `required`. A property that was optional therefore becomes required-but-nullable,
// which has to be expressed differently depending on how the subschema is written.
// If there is nowhere to put "null", refuse — silently promoting the property to
// required AND non-nullable would turn an optional field into a mandatory one.
function makeNullable(node, path) {
  if (node === null || typeof node !== "object") refuse(`cannot make ${path} nullable: not a schema object`, path);
  if (allowsNull(node)) return;
  if (node.type !== undefined) {
    node.type = [...typesOf(node), "null"];
    if (Array.isArray(node.enum) && !node.enum.includes(null)) node.enum = [...node.enum, null];
    return;
  }
  if (node.$ref !== undefined) {
    // A $ref carries no `type` to widen, so the union has to wrap it. Keeping
    // `$ref` as a sibling of `anyOf` would leave two competing applicators.
    const ref = node.$ref;
    delete node.$ref;
    node.anyOf = [{ $ref: ref }, { type: "null" }];
    return;
  }
  for (const kw of ["anyOf", "oneOf"]) {
    if (Array.isArray(node[kw])) {
      if (!node[kw].some(allowsNull)) node[kw] = [...node[kw], { type: "null" }];
      return;
    }
  }
  if (Array.isArray(node.enum)) { node.enum = [...node.enum, null]; return; }
  throw new Error(`cannot make optional property ${path} nullable: it has no type, $ref, anyOf/oneOf or enum to widen`);
}

function walk(node, path) {
  if (node === null || typeof node !== "object") return;
  if (Array.isArray(node)) { node.forEach((n, i) => walk(n, `${path}[${i}]`)); return; }

  for (const kw of REFUSED_KEYWORDS) {
    if (node[kw] !== undefined) refuse(`${kw} is not supported`, path);
  }

  const properties = node.properties && typeof node.properties === "object" ? node.properties : null;
  if (properties || typesOf(node).includes("object")) {
    // A schema-valued additionalProperties ("any number of string-valued keys")
    // cannot be expressed under STRICT, and overwriting it with false would
    // narrow the contract to "no keys at all".
    if (node.additionalProperties !== undefined && typeof node.additionalProperties !== "boolean") {
      refuse("a schema-valued additionalProperties is not supported", path);
    }
    node.additionalProperties = false;
    const keys = Object.keys(properties ?? {});
    // `required` must be exactly the property keys: no duplicates, no entries
    // without a matching property, nothing missing. Preserve the author's order
    // for the keys they already listed.
    const listed = Array.isArray(node.required) ? node.required : [];
    const kept = [];
    for (const k of listed) if (keys.includes(k) && !kept.includes(k)) kept.push(k);
    const added = keys.filter((k) => !kept.includes(k));
    node.required = [...kept, ...added];
    for (const k of added) makeNullable(properties[k], `${path}.${k}`);
  }

  for (const kw of MAP_KEYWORDS) {
    const map = node[kw];
    if (map && typeof map === "object" && !Array.isArray(map)) {
      for (const k of Object.keys(map)) walk(map[k], `${path}.${kw}.${k}`);
    }
  }
  for (const kw of [...LIST_KEYWORDS, ...SCHEMA_KEYWORDS]) {
    if (node[kw] !== undefined && node[kw] !== null && typeof node[kw] === "object") walk(node[kw], `${path}.${kw}`);
  }
}

/**
 * Return a STRICT-mode-acceptable copy of `schema`. The input is never mutated.
 * Throws if the schema uses a construct that cannot be normalized without
 * changing its meaning.
 */
export function strictifySchema(schema) {
  const normalized = structuredClone(schema);
  delete normalized.version; // non-standard keyword; ours only, not JSON Schema's
  walk(normalized, "$");
  return normalized;
}
