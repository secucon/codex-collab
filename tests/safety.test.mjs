// tests/safety.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { fileURLToPath } from "node:url";

const files = ["../scripts/codex-client.mjs", "../scripts/lib/app-server.mjs", "../scripts/consensus.mjs"];
const banned = ["--dangerously", "danger-full-access", "--full-auto", "bypass-approvals"];

test("no dangerous flag strings appear in Codex-arg-constructing scripts", () => {
  for (const rel of files) {
    const src = fs.readFileSync(fileURLToPath(new URL(rel, import.meta.url)), "utf8");
    for (const b of banned) assert.ok(!src.includes(b), `${rel} must not contain ${b}`);
  }
});
