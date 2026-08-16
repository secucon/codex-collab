// tests/schema-strictify.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { strictifySchema } from "../scripts/lib/schema.mjs";

function load(rel) { return JSON.parse(fs.readFileSync(fileURLToPath(new URL(rel, import.meta.url)), "utf8")); }

// Walks the normalized schema and asserts the constraints Codex/OpenAI
// structured-output STRICT mode actually enforces (verified live on
// 2026-08-16: the API rejected both on-disk schemas with 400
// invalid_json_schema for exactly these two rules).
function typesOf(node) {
  if (node.type === undefined) return [];
  return Array.isArray(node.type) ? node.type : [node.type];
}

const MAP_KEYWORDS = ["properties", "$defs", "definitions"];
const LIST_KEYWORDS = ["anyOf", "oneOf", "prefixItems"];
const SCHEMA_KEYWORDS = ["items"];

function assertStrictClean(node, path = "$") {
  if (node === null || typeof node !== "object") return;
  if (Array.isArray(node)) { node.forEach((n, i) => assertStrictClean(n, `${path}[${i}]`)); return; }
  if (node.properties || typesOf(node).includes("object")) {
    assert.equal(node.additionalProperties, false, `${path}: additionalProperties must be false`);
    const keys = Object.keys(node.properties ?? {});
    assert.deepEqual([...(node.required ?? [])].sort(), [...keys].sort(),
      `${path}: required must list every property key`);
  }
  for (const kw of MAP_KEYWORDS) {
    if (node[kw]) for (const k of Object.keys(node[kw])) assertStrictClean(node[kw][k], `${path}.${kw}.${k}`);
  }
  for (const kw of [...LIST_KEYWORDS, ...SCHEMA_KEYWORDS]) {
    if (node[kw]) assertStrictClean(node[kw], `${path}.${kw}`);
  }
}

test("strictifySchema drops the non-standard top-level version keyword", () => {
  const out = strictifySchema({ version: "3.0.0", type: "object", properties: {}, required: [] });
  assert.ok(!("version" in out));
});

test("strictifySchema preserves numeric range constraints", () => {
  // Verified live against real Codex on 2026-08-16: a STRICT-clean schema
  // keeping minimum/maximum is ACCEPTED. Stripping them would silently widen
  // the contract (evaluation.confidence 0..1 -> any number) for no benefit.
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: ["confidence"],
    properties: { confidence: { type: "number", minimum: 0, maximum: 1 } },
  });
  assert.deepEqual(out.properties.confidence, { type: "number", minimum: 0, maximum: 1 });
});

test("strictifySchema adds every property key to required and makes the added ones nullable", () => {
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: ["severity"],
    properties: { severity: { type: "string" }, location: { type: "string" } },
  });
  assert.deepEqual(out.required, ["severity", "location"]);
  assert.deepEqual(out.properties.severity.type, "string", "already-required props keep their type");
  assert.deepEqual(out.properties.location.type, ["string", "null"], "newly-required props become nullable");
});

test("strictifySchema sets additionalProperties:false on a nested object under a type union", () => {
  // position.json's `proposed_change` is typed ["object","null"] with no
  // additionalProperties and no required — the exact node the live API rejected.
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: ["stance"],
    properties: {
      stance: { type: "string" },
      proposed_change: { type: ["object", "null"], properties: { summary: { type: "string" } } },
    },
  });
  const pc = out.properties.proposed_change;
  assert.equal(pc.additionalProperties, false);
  assert.deepEqual(pc.required, ["summary"]);
  assert.deepEqual(pc.type, ["object", "null"], "an already-nullable union is not double-wrapped");
});

test("strictifySchema recurses into array items", () => {
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: ["findings"],
    properties: {
      findings: { type: "array", items: { type: "object", required: ["a"], properties: { a: { type: "string" }, b: { type: "string" } } } },
    },
  });
  assert.equal(out.properties.findings.items.additionalProperties, false);
  assert.deepEqual(out.properties.findings.items.required, ["a", "b"]);
});

test("strictifySchema adds null to an enum it makes nullable", () => {
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: [],
    properties: { severity: { type: "string", enum: ["low", "high"] } },
  });
  assert.deepEqual(out.properties.severity.enum, ["low", "high", null]);
});

test("strictifySchema closes an object node that declares no properties", () => {
  // STRICT requires additionalProperties:false on every object, not just on
  // objects that happen to carry a `properties` map.
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: ["bag"],
    properties: { bag: { type: "object" } },
  });
  assert.equal(out.properties.bag.additionalProperties, false);
  assert.deepEqual(out.properties.bag.required, []);
});

test("strictifySchema traverses anyOf and oneOf branches", () => {
  const branch = () => ({ type: "object", required: ["a"], properties: { a: { type: "string" }, b: { type: "string" } } });
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: ["x", "y"],
    properties: { x: { anyOf: [branch()] }, y: { oneOf: [branch()] } },
  });
  for (const [key, kw] of [["x", "anyOf"], ["y", "oneOf"]]) {
    const b = out.properties[key][kw][0];
    assert.equal(b.additionalProperties, false, `${kw} branch must be closed`);
    assert.deepEqual(b.required, ["a", "b"], `${kw} branch must require every key`);
  }
});

// Normalizing an applicator changes what it MATCHES, not just how it is spelled.
// Closing every allOf branch makes an intersection of differing branches
// unsatisfiable; forcing `required` inside an `if` inverts the condition for an
// absent key. Refusing is the only honest option — the caller gets a clear error
// at our boundary instead of a silently different contract or a bare API 400.
for (const kw of ["allOf", "not", "if", "then", "else", "contains", "propertyNames",
  "patternProperties", "dependentSchemas", "dependencies", "unevaluatedProperties",
  "unevaluatedItems", "additionalItems", "contentSchema"]) {
  test(`strictifySchema refuses to normalize a schema using ${kw}`, () => {
    const inner = { type: "object", required: [], properties: { a: { type: "string" } } };
    const value = ["patternProperties", "dependentSchemas", "dependencies"].includes(kw) ? { "^x": inner }
      : kw === "allOf" ? [inner] : inner;
    assert.throws(
      () => strictifySchema({ type: "object", additionalProperties: false, required: ["p"], properties: { p: { [kw]: value } } }),
      new RegExp(`cannot .*${kw.replace("$", "\\$")}`, "i"),
    );
  });
}

test("strictifySchema refuses a non-boolean additionalProperties instead of clobbering it", () => {
  // {type:"object", additionalProperties:{type:"string"}} means "any number of
  // string-valued keys". Overwriting it with false silently narrows that to
  // "no keys at all".
  assert.throws(
    () => strictifySchema({
      type: "object", additionalProperties: false, required: ["bag"],
      properties: { bag: { type: "object", additionalProperties: { type: "string" } } },
    }),
    /cannot .*additionalProperties/i,
  );
});

test("strictifySchema allows an additionalProperties already set to false or true", () => {
  const out = strictifySchema({
    type: "object", additionalProperties: true, required: ["bag"],
    properties: { bag: { type: "object", additionalProperties: false, required: [], properties: {} } },
  });
  assert.equal(out.additionalProperties, false);
  assert.equal(out.properties.bag.additionalProperties, false);
});

test("strictifySchema refuses an optional property whose nullability it cannot express", () => {
  // No type, no $ref, no anyOf/oneOf, no enum -> there is nowhere to put "null",
  // so the property would silently become required AND non-nullable.
  assert.throws(
    () => strictifySchema({
      type: "object", additionalProperties: false, required: [],
      properties: { pinned: { const: 5 } },
    }),
    /cannot make .*nullable/i,
  );
});

test("strictifySchema traverses $defs and definitions", () => {
  const def = () => ({ type: "object", required: [], properties: { a: { type: "string" } } });
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: ["r"],
    properties: { r: { $ref: "#/$defs/Thing" } },
    $defs: { Thing: def() },
    definitions: { Legacy: def() },
  });
  assert.equal(out.$defs.Thing.additionalProperties, false);
  assert.deepEqual(out.$defs.Thing.required, ["a"]);
  assert.equal(out.definitions.Legacy.additionalProperties, false);
});

test("strictifySchema traverses prefixItems", () => {
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: ["t"],
    properties: { t: { type: "array", prefixItems: [{ type: "object", required: [], properties: { a: { type: "string" } } }] } },
  });
  assert.equal(out.properties.t.prefixItems[0].additionalProperties, false);
  assert.deepEqual(out.properties.t.prefixItems[0].required, ["a"]);
});

test("strictifySchema normalizes required to exactly the property keys", () => {
  // Duplicates and entries with no matching property are both invalid under
  // STRICT ("an array including every key in properties").
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: ["a", "a", "ghost"],
    properties: { a: { type: "string" }, b: { type: "string" } },
  });
  assert.deepEqual(out.required, ["a", "b"]);
});

test("strictifySchema makes an untyped enum property nullable", () => {
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: [],
    properties: { mode: { enum: ["fast", "slow"] } },
  });
  assert.deepEqual(out.properties.mode.enum, ["fast", "slow", null]);
});

test("strictifySchema makes a $ref property nullable by wrapping it in anyOf", () => {
  // A $ref node carries no `type` to widen, so nullability has to be expressed
  // as a union — otherwise the property becomes required and non-nullable,
  // silently turning an optional field into a mandatory one.
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: [],
    properties: { thing: { $ref: "#/$defs/Thing" } },
    $defs: { Thing: { type: "object", required: [], properties: {} } },
  });
  assert.deepEqual(out.properties.thing.anyOf, [{ $ref: "#/$defs/Thing" }, { type: "null" }]);
  assert.ok(!("$ref" in out.properties.thing));
});

test("strictifySchema makes an anyOf property nullable by adding a null branch", () => {
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: [],
    properties: { v: { anyOf: [{ type: "string" }, { type: "number" }] } },
  });
  assert.deepEqual(out.properties.v.anyOf, [{ type: "string" }, { type: "number" }, { type: "null" }]);
});

test("strictifySchema does not add a second null branch to an already-nullable union", () => {
  const out = strictifySchema({
    type: "object", additionalProperties: false, required: [],
    properties: { v: { anyOf: [{ type: "string" }, { type: "null" }] } },
  });
  assert.deepEqual(out.properties.v.anyOf, [{ type: "string" }, { type: "null" }]);
});

test("strictifySchema does not mutate its input (on-disk schemas stay human-readable contracts)", () => {
  const input = load("../schemas/evaluation.json");
  const before = JSON.stringify(input);
  strictifySchema(input);
  assert.equal(JSON.stringify(input), before);
});

test("normalized position.json satisfies STRICT mode constraints", () => {
  assertStrictClean(strictifySchema(load("../schemas/position.json")));
});

test("normalized evaluation.json satisfies STRICT mode constraints", () => {
  assertStrictClean(strictifySchema(load("../schemas/evaluation.json")));
});
