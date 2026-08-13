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
  const pkg = JSON.parse(read("../package.json"));
  assert.equal(p.name, "codex-collab");
  assert.equal(p.version, pkg.version, "plugin.json and package.json versions must match");
});

test("marketplace.json versions match package.json", () => {
  const m = JSON.parse(read("../.claude-plugin/marketplace.json"));
  const pkg = JSON.parse(read("../package.json"));
  assert.equal(m.metadata.version, pkg.version, "marketplace metadata version must match package.json");
  for (const plugin of m.plugins) {
    assert.equal(plugin.version, pkg.version, `marketplace plugin "${plugin.name}" version must match package.json`);
  }
});
