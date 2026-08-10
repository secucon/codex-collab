// tests/plugin-structure.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { fileURLToPath } from "node:url";

function read(rel) { return fs.readFileSync(fileURLToPath(new URL(rel, import.meta.url)), "utf8"); }
const cmds = ["../commands/codex-ask.md", "../commands/codex-evaluate.md", "../commands/codex-debate.md", "../agents/codex-orchestrator.md"];

test("every command/agent references scripts via CLAUDE_PLUGIN_ROOT, never cwd-relative source", () => {
  for (const rel of cmds) {
    const src = read(rel);
    if (src.includes("codex-client.mjs") || src.includes("consensus.mjs")) {
      assert.ok(src.includes("${CLAUDE_PLUGIN_ROOT}"), `${rel} must use \${CLAUDE_PLUGIN_ROOT}`);
    }
    assert.ok(!/source\s+scripts\//.test(src), `${rel} must not source cwd-relative scripts`);
  }
});

test("plugin.json lists the three commands dir and the agent", () => {
  const p = JSON.parse(read("../.claude-plugin/plugin.json"));
  assert.equal(p.name, "codex-collab");
  assert.equal(p.version, "3.0.0");
});
