// tests/schemas.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { fileURLToPath } from "node:url";

function load(rel) { return JSON.parse(fs.readFileSync(fileURLToPath(new URL(rel, import.meta.url)), "utf8")); }

test("position schema requires consensus-gate inputs", () => {
  const s = load("../schemas/position.json");
  assert.equal(s.type, "object");
  assert.ok(s.required.includes("agrees_with_opponent"));
  assert.ok(s.required.includes("key_points"));
  assert.equal(s.properties.agrees_with_opponent.type, "boolean");
  assert.equal(s.properties.key_points.type, "array");
});

test("evaluation schema is a versioned object with findings", () => {
  const s = load("../schemas/evaluation.json");
  assert.equal(s.type, "object");
  assert.ok("version" in s);
  assert.ok(s.properties.findings);
});
