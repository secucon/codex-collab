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
function assertStrictClean(node, path = "$") {
  if (node === null || typeof node !== "object") return;
  if (Array.isArray(node)) { node.forEach((n, i) => assertStrictClean(n, `${path}[${i}]`)); return; }
  if (node.properties) {
    assert.equal(node.additionalProperties, false, `${path}: additionalProperties must be false`);
    const keys = Object.keys(node.properties);
    assert.deepEqual([...(node.required ?? [])].sort(), [...keys].sort(),
      `${path}: required must list every property key`);
    for (const k of keys) assertStrictClean(node.properties[k], `${path}.${k}`);
  }
  if (node.items) assertStrictClean(node.items, `${path}.items`);
}

function typesOf(node) { return Array.isArray(node.type) ? node.type : [node.type]; }

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
