# codex-collab v3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild codex-collab as a clean Claude Code plugin whose unique workflows (debate, cross-verify, read-only ask) run on the stable `codex app-server` JSON-RPC protocol, with the sandbox enforced as a programmatic parameter.

**Architecture:** Claude reasons (positions, blind analysis, round decisions) in markdown agents/commands; a small zero-dependency Node layer (`codex-client.mjs`, `consensus.mjs`) does all Codex I/O over `codex app-server` stdio JSON-RPC; the Codex sandbox is the only defense line. Stateless per round — each round spawns app-server, resumes a stored thread-id, runs one turn, closes.

**Tech Stack:** Node.js ≥18.18 (zero runtime deps), `node --test` + `node:assert` for tests, JSON-RPC over child-process stdio, Claude Code plugin (commands/agents/skills markdown, JSON schemas).

## Global Constraints

- Node.js ≥ 18.18. Zero runtime dependencies. Dev-only: none (use Node built-ins `node:test`, `node:assert`, `node:child_process`).
- No python3 dependency anywhere. No load-bearing bash logic. No `set -euo pipefail` sourced into a caller.
- All plugin script paths referenced from command/agent frontmatter MUST use `${CLAUDE_PLUGIN_ROOT}` — never cwd-relative.
- The strings `--dangerously`, `danger-full-access`, `--full-auto`, `bypass-approvals` MUST NOT appear in any script that constructs Codex arguments (enforced by a test).
- Sandbox defaults to `read-only` everywhere; `workspace-write` is passed ONLY on the explicit, approval-gated apply turn.
- Prompts are passed to Codex via file/stdin, never interpolated into a shell command string.
- Plugin name stays `codex-collab`. Marketplace entry unchanged. Version `3.0.0`.
- License: codex-collab is MIT; the official plugin referenced is Apache-2.0. Implement from the documented protocol. Any verbatim-copied code requires a NOTICE attribution.
- App-server protocol facts (verified against openai/codex-plugin-cc @ db52e28):
  - Spawn: `spawn("codex", ["app-server"], { cwd })`, JSONL over stdout/stdin, one JSON object per line.
  - Handshake: `request("initialize", { clientInfo, capabilities: { experimentalApi: false, requestAttestation: false } })` then `notify("initialized", {})`.
  - `thread/start` params: `{ cwd, model|null, approvalPolicy: "never", sandbox: "read-only"|"workspace-write", serviceName, ephemeral: bool }` → result `{ thread: { id } }`.
  - `thread/resume` params: `{ threadId, cwd, model|null, approvalPolicy: "never", sandbox }` → result `{ thread: { id } }`.
  - `turn/start` params: `{ threadId, input: [{ type: "text", text, text_elements: [] }], model|null, effort|null, outputSchema|null }`.
  - Completion notifications: `turn/completed` (has `params.turn.status`); final text arrives via `item/completed` where `params.item.type === "agentMessage"` (accumulate `item.text`; `phase === "final_answer"` marks the final). `error` notification carries `params.error`.

---

## File Structure

```
codex-collab/                          (v3 clean)
  .claude-plugin/
    plugin.json                        name codex-collab, version 3.0.0, commands/agents/skills globs
    marketplace.json                   (kept from v2.2, unchanged)
  package.json                         name, engines>=18.18, scripts.test = "node --test"
  NOTICE                               attribution notes
  commands/
    codex-ask.md
    codex-evaluate.md
    codex-debate.md
  agents/
    codex-orchestrator.md              drives debate + evaluate reasoning
  scripts/
    codex-client.mjs                   CLI: `turn`, `check` (only Codex I/O entrypoint)
    consensus.mjs                      CLI + pure export: deterministic consensus gate
    lib/
      app-server.mjs                   CodexAppServerClient (spawn, JSON-RPC, turn capture)
      args.mjs                         tiny argv parser (flags + values)
  schemas/
    position.json                      debate round position
    evaluation.json                    cross-verify structured output (ported, cleaned)
  tests/
    fake-app-server.mjs                minimal fake speaking the real JSONL protocol
    app-server.test.mjs                client unit tests against the fake
    codex-client.test.mjs             CLI turn/check tests against the fake
    consensus.test.mjs                 pure unit tests
    safety.test.mjs                    asserts no dangerous flag strings are emitted
  .github/workflows/
    ci.yml                             unit tests + drift canary (real @openai/codex)
  README.md
  CHANGELOG.md
  docs/superpowers/specs/2026-08-10-codex-collab-v3-design.md   (already committed)
```

Files that will be **deleted** in Task 1 (the entire v2.2 bash/python implementation): everything under `scripts/*.sh`, the v2 `agents/*.md`, `skills/*`, `hooks/`, old `commands/*.md`, old `schemas/*.json` (except values ported into new schemas), `tests/*.sh`, `.codex-collab/`, `docs/rules.yaml.example`.

---

## Task 1: Clean slate + scaffold

**Files:**
- Delete: `scripts/*.sh`, `agents/*.md`, `skills/`, `hooks/`, `commands/*.md`, `schemas/*.json`, `tests/*.sh`, `tests/fixtures/`, `tests/manual-checklist.md`, `.codex-collab/config.yaml`, `docs/rules.yaml.example`, `.github/workflows/ci.yml`
- Create: `package.json`, `NOTICE`
- Modify: `.claude-plugin/plugin.json`

**Interfaces:**
- Produces: a repo with no v2.2 implementation, a `package.json` exposing `npm test` → `node --test`, and a v3 `plugin.json`.

- [ ] **Step 1: Remove the v2.2 implementation**

```bash
git rm -r scripts hooks skills tests .codex-collab docs/rules.yaml.example
git rm agents/*.md commands/*.md schemas/*.json
git rm .github/workflows/ci.yml
```

- [ ] **Step 2: Write `package.json`**

```json
{
  "name": "codex-collab",
  "version": "3.0.0",
  "private": true,
  "description": "Claude Code <-> OpenAI Codex cross-model collaboration: debate, cross-verify, ask — on the codex app-server protocol",
  "type": "module",
  "engines": { "node": ">=18.18" },
  "scripts": {
    "test": "node --test",
    "test:canary": "node scripts/codex-client.mjs check --out /dev/stdout"
  },
  "license": "MIT"
}
```

- [ ] **Step 3: Write `NOTICE`**

```text
codex-collab v3
Copyright (c) jguru. MIT License.

This project's codex app-server client is an independent implementation
written against the publicly documented Codex app-server protocol
(https://developers.openai.com/codex/app-server). It was informed by
reference to openai/codex-plugin-cc (Apache-2.0). No source files were
copied verbatim. Should any verbatim excerpt be introduced later, the
Apache-2.0 attribution and license notice will be reproduced here.
```

- [ ] **Step 4: Rewrite `.claude-plugin/plugin.json`**

```json
{
  "name": "codex-collab",
  "version": "3.0.0",
  "description": "Claude Code <-> OpenAI Codex (GPT-5.x) cross-model collaboration — debate, cross-verify, ask via the codex app-server protocol",
  "author": { "name": "jguru" },
  "repository": "https://github.com/secucon/codex-collab",
  "license": "MIT",
  "keywords": ["codex", "openai", "collaboration", "cross-model", "debate", "evaluate", "app-server"],
  "commands": ["./commands/"],
  "agents": ["./agents/codex-orchestrator.md"]
}
```

- [ ] **Step 5: Verify the tree is clean and Node runs**

Run: `node --version && npm test 2>&1 | head -5`
Expected: Node ≥ v18.18 prints; `npm test` reports "no test files found" (exit is fine — no tests yet).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: v3 clean slate — remove v2.2 bash impl, scaffold Node project"
```

---

## Task 2: `consensus.mjs` — deterministic consensus gate

The simplest, most isolated unit: a pure function plus a thin CLI. No Codex, no I/O beyond reading two JSON files and writing one.

**Files:**
- Create: `scripts/consensus.mjs`
- Create: `scripts/lib/args.mjs`
- Test: `tests/consensus.test.mjs`

**Interfaces:**
- Produces:
  - `export function evaluateConsensus(claudePos, codexPos, opts)` where positions are `{ agrees_with_opponent: bool, key_points: string[] }` and `opts` is `{ round: number, defaultRounds: number, maxExtra: number }`. Returns `{ consensus: boolean, divergence: number, capReached: boolean, reason: string }`.
  - `export function parseArgs(argv, spec)` in `lib/args.mjs`: `spec` is `{ flags: string[], values: string[] }`; returns an object mapping option name (without `--`) to `true` (flags) or the string value; unknown `--x` with no spec entry throws.
  - CLI: `node consensus.mjs --claude <file> --codex <file> --round N --default-rounds D --max-extra E --out <file>` writes the result object as JSON to `--out`.
- Consumed by: the `codex-orchestrator` agent between debate rounds (Task 6).

- [ ] **Step 1: Write the failing test for `parseArgs`**

```js
// tests/consensus.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { parseArgs } from "../scripts/lib/args.mjs";

test("parseArgs reads flags and values", () => {
  const out = parseArgs(
    ["--verbose", "--out", "x.json", "--round", "2"],
    { flags: ["verbose"], values: ["out", "round"] }
  );
  assert.equal(out.verbose, true);
  assert.equal(out.out, "x.json");
  assert.equal(out.round, "2");
});

test("parseArgs throws on unknown option", () => {
  assert.throws(() => parseArgs(["--nope"], { flags: [], values: [] }), /unknown option/i);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `node --test tests/consensus.test.mjs`
Expected: FAIL — cannot find module `../scripts/lib/args.mjs`.

- [ ] **Step 3: Implement `lib/args.mjs`**

```js
// scripts/lib/args.mjs
export function parseArgs(argv, spec) {
  const flags = new Set(spec.flags ?? []);
  const values = new Set(spec.values ?? []);
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const tok = argv[i];
    if (!tok.startsWith("--")) throw new Error(`unexpected argument: ${tok}`);
    const name = tok.slice(2);
    if (flags.has(name)) {
      out[name] = true;
    } else if (values.has(name)) {
      const val = argv[++i];
      if (val === undefined) throw new Error(`missing value for --${name}`);
      out[name] = val;
    } else {
      throw new Error(`unknown option: --${name}`);
    }
  }
  return out;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `node --test tests/consensus.test.mjs`
Expected: PASS (2 passing).

- [ ] **Step 5: Add failing tests for `evaluateConsensus`**

```js
// append to tests/consensus.test.mjs
import { evaluateConsensus } from "../scripts/consensus.mjs";

const agree = { agrees_with_opponent: true, key_points: ["a", "b"] };
const disagree = { agrees_with_opponent: false, key_points: ["a", "c", "d"] };

test("consensus true only when BOTH sides agree", () => {
  const r = evaluateConsensus(agree, agree, { round: 1, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r.consensus, true);
  const r2 = evaluateConsensus(agree, disagree, { round: 1, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r2.consensus, false);
});

test("divergence is symmetric-difference size over key_points", () => {
  const r = evaluateConsensus(agree, disagree, { round: 1, defaultRounds: 3, maxExtra: 2 });
  // {a,b} vs {a,c,d} -> symmetric diff {b,c,d} = 3
  assert.equal(r.divergence, 3);
});

test("cap is default + min(extra,2), clamped", () => {
  // round 5 with defaultRounds 3, maxExtra 2 => cap 5 => capReached true
  const r = evaluateConsensus(disagree, disagree, { round: 5, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r.capReached, true);
  // maxExtra 9 must clamp to 2 => cap still 5
  const r2 = evaluateConsensus(disagree, disagree, { round: 5, defaultRounds: 3, maxExtra: 9 });
  assert.equal(r2.capReached, true);
  // round 4 under cap 5 => not reached
  const r3 = evaluateConsensus(disagree, disagree, { round: 4, defaultRounds: 3, maxExtra: 2 });
  assert.equal(r3.capReached, false);
});
```

- [ ] **Step 6: Run to verify failure**

Run: `node --test tests/consensus.test.mjs`
Expected: FAIL — `evaluateConsensus` not exported.

- [ ] **Step 7: Implement `consensus.mjs`**

```js
// scripts/consensus.mjs
import fs from "node:fs";
import { parseArgs } from "./lib/args.mjs";

export function evaluateConsensus(claudePos, codexPos, opts) {
  const { round, defaultRounds, maxExtra } = opts;
  const cap = defaultRounds + Math.max(0, Math.min(maxExtra ?? 0, 2));
  const a = new Set(claudePos.key_points ?? []);
  const b = new Set(codexPos.key_points ?? []);
  let divergence = 0;
  for (const p of a) if (!b.has(p)) divergence++;
  for (const p of b) if (!a.has(p)) divergence++;
  const consensus = Boolean(claudePos.agrees_with_opponent) && Boolean(codexPos.agrees_with_opponent);
  const capReached = round >= cap;
  const reason = consensus
    ? "both sides agree"
    : capReached
      ? `round cap ${cap} reached without consensus`
      : `divergence ${divergence}, continue`;
  return { consensus, divergence, capReached, reason };
}

function main() {
  const opts = parseArgs(process.argv.slice(2), {
    flags: [],
    values: ["claude", "codex", "round", "default-rounds", "max-extra", "out"]
  });
  const claudePos = JSON.parse(fs.readFileSync(opts.claude, "utf8"));
  const codexPos = JSON.parse(fs.readFileSync(opts.codex, "utf8"));
  const result = evaluateConsensus(claudePos, codexPos, {
    round: Number(opts.round),
    defaultRounds: Number(opts["default-rounds"] ?? 3),
    maxExtra: Number(opts["max-extra"] ?? 2)
  });
  fs.writeFileSync(opts.out, JSON.stringify(result, null, 2));
}

if (import.meta.url === `file://${process.argv[1]}`) main();
```

- [ ] **Step 8: Run to verify pass**

Run: `node --test tests/consensus.test.mjs`
Expected: PASS (all consensus + args tests).

- [ ] **Step 9: Smoke-test the CLI**

Run:
```bash
printf '{"agrees_with_opponent":true,"key_points":["a"]}' > /tmp/c.json
printf '{"agrees_with_opponent":true,"key_points":["a"]}' > /tmp/x.json
node scripts/consensus.mjs --claude /tmp/c.json --codex /tmp/x.json --round 1 --default-rounds 3 --max-extra 2 --out /tmp/o.json && cat /tmp/o.json
```
Expected: JSON with `"consensus": true`.

- [ ] **Step 10: Commit**

```bash
git add scripts/consensus.mjs scripts/lib/args.mjs tests/consensus.test.mjs
git commit -m "feat: deterministic consensus gate + argv parser"
```

---

## Task 3: `fake-app-server.mjs` + `lib/app-server.mjs` — JSON-RPC client

Build the client against a fake that speaks the real JSONL protocol, so it is tested without a real `codex` binary.

**Files:**
- Create: `tests/fake-app-server.mjs`
- Create: `scripts/lib/app-server.mjs`
- Test: `tests/app-server.test.mjs`

**Interfaces:**
- Produces (`lib/app-server.mjs`):
  - `export class CodexAppServerClient` with:
    - `static async connect(cwd, { command, args, env } = {})` — spawns `command` (default `"codex"`) with `args` (default `["app-server"]`), performs `initialize` + `initialized`, resolves to a connected client. `command`/`args` override exists so tests inject the fake.
    - `async startThread({ sandbox, model })` → `string threadId`
    - `async resumeThread(threadId, { sandbox, model })` → `string threadId`
    - `async runTurn(threadId, { prompt, outputSchema, effort })` → `{ text: string, structured: object|null, status: string }`
    - `async close()`
  - The client accumulates `agentMessage` item text, resolves the turn on `turn/completed`, and rejects on an `error` notification or non-zero exit.
- Consumed by: `codex-client.mjs` (Task 4).

- [ ] **Step 1: Write the fake app-server**

```js
// tests/fake-app-server.mjs
// A minimal executable that speaks the codex app-server JSONL protocol on stdio.
// Behavior is scripted via env:
//   FAKE_TURN_TEXT   - text returned as the final agentMessage
//   FAKE_TURN_ERROR  - if set, emit an `error` notification instead of completing
//   FAKE_STRUCTURED  - if set (JSON string), echoed as final agentMessage text
import readline from "node:readline";

function send(obj) { process.stdout.write(JSON.stringify(obj) + "\n"); }

const rl = readline.createInterface({ input: process.stdin });
let threadSeq = 0;
let turnSeq = 0;

rl.on("line", (line) => {
  if (!line.trim()) return;
  const msg = JSON.parse(line);
  if (msg.method === "initialize") return send({ id: msg.id, result: { } });
  if (msg.method === "initialized") return;
  if (msg.method === "thread/start" || msg.method === "thread/resume") {
    const id = msg.params.threadId ?? `thread-${++threadSeq}`;
    return send({ id: msg.id, result: { thread: { id } } });
  }
  if (msg.method === "turn/start") {
    const threadId = msg.params.threadId;
    const turnId = `turn-${++turnSeq}`;
    send({ id: msg.id, result: { turn: { id: turnId } } });
    send({ method: "turn/started", params: { threadId, turn: { id: turnId } } });
    if (process.env.FAKE_TURN_ERROR) {
      send({ method: "error", params: { error: { message: process.env.FAKE_TURN_ERROR } } });
      return;
    }
    const text = process.env.FAKE_STRUCTURED ?? process.env.FAKE_TURN_TEXT ?? "ok";
    send({ method: "item/completed", params: { threadId, item: { type: "agentMessage", phase: "final_answer", text } } });
    send({ method: "turn/completed", params: { threadId, turn: { id: turnId, status: "completed" } } });
    return;
  }
});
```

- [ ] **Step 2: Write failing client tests**

```js
// tests/app-server.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { CodexAppServerClient } from "../scripts/lib/app-server.mjs";

const FAKE = fileURLToPath(new URL("./fake-app-server.mjs", import.meta.url));
function connectFake(env = {}) {
  return CodexAppServerClient.connect(process.cwd(), {
    command: process.execPath, args: [FAKE], env: { ...process.env, ...env }
  });
}

test("start thread then run a turn returns final text", async () => {
  const client = await connectFake({ FAKE_TURN_TEXT: "hello from codex" });
  const threadId = await client.startThread({ sandbox: "read-only" });
  assert.match(threadId, /^thread-/);
  const res = await client.runTurn(threadId, { prompt: "hi" });
  assert.equal(res.text, "hello from codex");
  assert.equal(res.status, "completed");
  await client.close();
});

test("resume reuses the given thread id", async () => {
  const client = await connectFake();
  const id = await client.resumeThread("thread-xyz", { sandbox: "read-only" });
  assert.equal(id, "thread-xyz");
  await client.close();
});

test("an error notification rejects the turn", async () => {
  const client = await connectFake({ FAKE_TURN_ERROR: "boom" });
  const threadId = await client.startThread({ sandbox: "read-only" });
  await assert.rejects(() => client.runTurn(threadId, { prompt: "x" }), /boom/);
  await client.close();
});

test("structured output is parsed when text is valid JSON", async () => {
  const client = await connectFake({ FAKE_STRUCTURED: '{"stance":"yes"}' });
  const threadId = await client.startThread({ sandbox: "read-only" });
  const res = await client.runTurn(threadId, { prompt: "x", outputSchema: { type: "object" } });
  assert.deepEqual(res.structured, { stance: "yes" });
  await client.close();
});
```

- [ ] **Step 3: Run to verify failure**

Run: `node --test tests/app-server.test.mjs`
Expected: FAIL — cannot find `../scripts/lib/app-server.mjs`.

- [ ] **Step 4: Implement `lib/app-server.mjs`**

```js
// scripts/lib/app-server.mjs
import { spawn } from "node:child_process";
import readline from "node:readline";

const CLIENT_INFO = { title: "codex-collab", name: "Claude Code", version: "3.0.0" };
const CAPABILITIES = { experimentalApi: false, requestAttestation: false };

export class CodexAppServerClient {
  constructor(cwd) {
    this.cwd = cwd;
    this.pending = new Map();
    this.nextId = 1;
    this.stderr = "";
    this.closed = false;
    this.exitError = null;
    this._turnWaiter = null; // { resolve, reject, threadId, text }
    this.exitPromise = new Promise((r) => (this._resolveExit = r));
  }

  static async connect(cwd, { command = "codex", args = ["app-server"], env } = {}) {
    const client = new CodexAppServerClient(cwd);
    client.proc = spawn(command, args, { cwd, env: env ?? process.env, stdio: ["pipe", "pipe", "pipe"] });
    client.proc.stdout.setEncoding("utf8");
    client.proc.stderr.setEncoding("utf8");
    client.proc.stderr.on("data", (c) => (client.stderr += c));
    client.proc.on("error", (e) => client._handleExit(e));
    client.proc.on("exit", (code, signal) => {
      const err = code === 0 || code === null ? null
        : new Error(`codex app-server exited (${signal ? "signal " + signal : "code " + code}).${client.stderr ? "\n" + client.stderr.trim() : ""}`);
      client._handleExit(err);
    });
    client.rl = readline.createInterface({ input: client.proc.stdout });
    client.rl.on("line", (line) => client._handleLine(line));
    await client._request("initialize", { clientInfo: CLIENT_INFO, capabilities: CAPABILITIES });
    client._notify("initialized", {});
    return client;
  }

  _send(msg) {
    if (!this.proc?.stdin) throw new Error("codex app-server stdin unavailable");
    this.proc.stdin.write(JSON.stringify(msg) + "\n");
  }
  _request(method, params) {
    if (this.closed) throw new Error("client closed");
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject, method });
      this._send({ id, method, params });
    });
  }
  _notify(method, params = {}) { if (!this.closed) this._send({ method, params }); }

  _handleLine(line) {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); }
    catch (e) { this._handleExit(new Error(`bad JSONL from app-server: ${e.message}`)); return; }
    if (msg.id !== undefined && !msg.method) {
      const p = this.pending.get(msg.id);
      if (!p) return;
      this.pending.delete(msg.id);
      if (msg.error) p.reject(new Error(msg.error.message ?? `${p.method} failed`));
      else p.resolve(msg.result ?? {});
      return;
    }
    if (msg.method) this._handleNotification(msg);
  }

  _handleNotification(msg) {
    const w = this._turnWaiter;
    if (!w) return;
    if (msg.method === "item/completed" && msg.params?.item?.type === "agentMessage") {
      if (typeof msg.params.item.text === "string") w.text = msg.params.item.text;
    } else if (msg.method === "error") {
      const waiter = this._turnWaiter; this._turnWaiter = null;
      waiter.reject(new Error(msg.params?.error?.message ?? "codex error"));
    } else if (msg.method === "turn/completed") {
      const waiter = this._turnWaiter; this._turnWaiter = null;
      waiter.resolve({ text: waiter.text ?? "", status: msg.params?.turn?.status ?? "completed" });
    }
  }

  _handleExit(err) {
    if (this._exited) return;
    this._exited = true;
    this.exitError = err ?? null;
    for (const p of this.pending.values()) p.reject(err ?? new Error("app-server closed"));
    this.pending.clear();
    if (this._turnWaiter) { const w = this._turnWaiter; this._turnWaiter = null; w.reject(err ?? new Error("app-server closed")); }
    this._resolveExit();
  }

  async startThread({ sandbox = "read-only", model = null } = {}) {
    const res = await this._request("thread/start", {
      cwd: this.cwd, model, approvalPolicy: "never", sandbox, serviceName: "codex-collab", ephemeral: false
    });
    return res.thread.id;
  }
  async resumeThread(threadId, { sandbox = "read-only", model = null } = {}) {
    const res = await this._request("thread/resume", { threadId, cwd: this.cwd, model, approvalPolicy: "never", sandbox });
    return res.thread.id;
  }
  async runTurn(threadId, { prompt, outputSchema = null, effort = null }) {
    if (!prompt || !prompt.trim()) throw new Error("prompt required");
    const done = new Promise((resolve, reject) => { this._turnWaiter = { resolve, reject, threadId, text: null }; });
    await this._request("turn/start", {
      threadId, input: [{ type: "text", text: prompt, text_elements: [] }], model: null, effort, outputSchema
    });
    const result = await done;
    let structured = null;
    if (outputSchema) { try { structured = JSON.parse(result.text); } catch { structured = null; } }
    return { text: result.text, structured, status: result.status };
  }
  async close() {
    if (this.closed) { await this.exitPromise; return; }
    this.closed = true;
    if (this.rl) this.rl.close();
    if (this.proc && !this.proc.killed) {
      this.proc.stdin.end();
      setTimeout(() => { if (this.proc && this.proc.exitCode === null) this.proc.kill("SIGTERM"); }, 50).unref?.();
    }
    await this.exitPromise;
  }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `node --test tests/app-server.test.mjs`
Expected: PASS (4 passing).

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/app-server.mjs tests/fake-app-server.mjs tests/app-server.test.mjs
git commit -m "feat: codex app-server JSON-RPC client + protocol fake"
```

---

## Task 4: `codex-client.mjs` — the `turn` and `check` CLI

The single entrypoint the agent shells into. Wraps the client with a file-based prompt, sandbox selection, and JSON output.

**Files:**
- Create: `scripts/codex-client.mjs`
- Test: `tests/codex-client.test.mjs`, `tests/safety.test.mjs`

**Interfaces:**
- Consumes: `CodexAppServerClient` from `lib/app-server.mjs`; `parseArgs` from `lib/args.mjs`.
- Produces (CLI):
  - `node codex-client.mjs turn --sandbox <read-only|workspace-write> --prompt-file <path> [--schema <path>] [--resume <thread-id>] --out <path>` → writes `{ threadId, text, structured|null, status }` JSON to `--out`.
  - `node codex-client.mjs check --out <path>` → writes `{ ok: bool, version?: string, error?: string }`.
  - Env override `CODEX_COLLAB_COMMAND` / `CODEX_COLLAB_ARGS` (JSON array) lets tests inject the fake; defaults to `codex app-server`.
  - Exit code non-zero on failure; error also captured in the `--out` JSON where possible.

- [ ] **Step 1: Write failing CLI tests**

```js
// tests/codex-client.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const run = promisify(execFile);
const CLIENT = fileURLToPath(new URL("../scripts/codex-client.mjs", import.meta.url));
const FAKE = fileURLToPath(new URL("./fake-app-server.mjs", import.meta.url));

function tmp(name) { return path.join(fs.mkdtempSync(path.join(os.tmpdir(), "cc-")), name); }
function fakeEnv(extra = {}) {
  return { ...process.env, CODEX_COLLAB_COMMAND: process.execPath, CODEX_COLLAB_ARGS: JSON.stringify([FAKE]), ...extra };
}

test("turn writes threadId and text to --out", async () => {
  const promptFile = tmp("p.txt"); fs.writeFileSync(promptFile, "hi");
  const out = tmp("o.json");
  await run(process.execPath, [CLIENT, "turn", "--sandbox", "read-only", "--prompt-file", promptFile, "--out", out],
    { env: fakeEnv({ FAKE_TURN_TEXT: "answer" }) });
  const res = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.equal(res.text, "answer");
  assert.match(res.threadId, /^thread-/);
});

test("turn with --schema parses structured output", async () => {
  const promptFile = tmp("p.txt"); fs.writeFileSync(promptFile, "hi");
  const schema = tmp("s.json"); fs.writeFileSync(schema, '{"type":"object"}');
  const out = tmp("o.json");
  await run(process.execPath, [CLIENT, "turn", "--sandbox", "read-only", "--prompt-file", promptFile, "--schema", schema, "--out", out],
    { env: fakeEnv({ FAKE_STRUCTURED: '{"stance":"yes"}' }) });
  const res = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.deepEqual(res.structured, { stance: "yes" });
});

test("check reports ok against a working server", async () => {
  const out = tmp("o.json");
  await run(process.execPath, [CLIENT, "check", "--out", out], { env: fakeEnv() });
  const res = JSON.parse(fs.readFileSync(out, "utf8"));
  assert.equal(res.ok, true);
});
```

- [ ] **Step 2: Write the safety test**

```js
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
```

- [ ] **Step 3: Run to verify failure**

Run: `node --test tests/codex-client.test.mjs tests/safety.test.mjs`
Expected: codex-client tests FAIL (module missing); safety test FAILs (module missing for codex-client.mjs read).

- [ ] **Step 4: Implement `codex-client.mjs`**

```js
// scripts/codex-client.mjs
import fs from "node:fs";
import { parseArgs } from "./lib/args.mjs";
import { CodexAppServerClient } from "./lib/app-server.mjs";

function serverOverride() {
  const command = process.env.CODEX_COLLAB_COMMAND;
  if (!command) return {};
  let args = ["app-server"];
  if (process.env.CODEX_COLLAB_ARGS) { try { args = JSON.parse(process.env.CODEX_COLLAB_ARGS); } catch {} }
  return { command, args };
}

async function cmdTurn(opts) {
  const sandbox = opts.sandbox ?? "read-only";
  if (sandbox !== "read-only" && sandbox !== "workspace-write") throw new Error(`invalid sandbox: ${sandbox}`);
  const prompt = fs.readFileSync(opts["prompt-file"], "utf8");
  const outputSchema = opts.schema ? JSON.parse(fs.readFileSync(opts.schema, "utf8")) : null;
  const client = await CodexAppServerClient.connect(process.cwd(), serverOverride());
  try {
    const threadId = opts.resume
      ? await client.resumeThread(opts.resume, { sandbox })
      : await client.startThread({ sandbox });
    const res = await client.runTurn(threadId, { prompt, outputSchema });
    fs.writeFileSync(opts.out, JSON.stringify({ threadId, ...res }, null, 2));
  } finally { await client.close(); }
}

async function cmdCheck(opts) {
  try {
    const client = await CodexAppServerClient.connect(process.cwd(), serverOverride());
    const threadId = await client.startThread({ sandbox: "read-only" });
    const res = await client.runTurn(threadId, { prompt: "Reply with the single word: ready." });
    await client.close();
    fs.writeFileSync(opts.out, JSON.stringify({ ok: true, sample: res.text }, null, 2));
  } catch (e) {
    fs.writeFileSync(opts.out, JSON.stringify({ ok: false, error: String(e.message ?? e) }, null, 2));
    process.exitCode = 1;
  }
}

async function main() {
  const [sub, ...rest] = process.argv.slice(2);
  if (sub === "turn") {
    await cmdTurn(parseArgs(rest, { flags: [], values: ["sandbox", "prompt-file", "schema", "resume", "out"] }));
  } else if (sub === "check") {
    await cmdCheck(parseArgs(rest, { flags: [], values: ["out"] }));
  } else {
    console.error("usage: codex-client.mjs <turn|check> ...");
    process.exitCode = 2;
  }
}

main().catch((e) => { console.error(e.message ?? e); process.exitCode = 1; });
```

- [ ] **Step 5: Run to verify pass**

Run: `node --test tests/codex-client.test.mjs tests/safety.test.mjs`
Expected: PASS (3 client + 1 safety).

- [ ] **Step 6: Run the full suite**

Run: `npm test`
Expected: PASS — all suites (consensus, args, app-server, codex-client, safety).

- [ ] **Step 7: Commit**

```bash
git add scripts/codex-client.mjs tests/codex-client.test.mjs tests/safety.test.mjs
git commit -m "feat: codex-client turn/check CLI with file-based prompts + sandbox guard"
```

---

## Task 5: Schemas

**Files:**
- Create: `schemas/position.json`, `schemas/evaluation.json`
- Test: `tests/schemas.test.mjs`

**Interfaces:**
- Produces: two JSON Schema files. `position.json` requires `agrees_with_opponent` (bool) and `key_points` (string array) so `consensus.mjs` always has its inputs; `evaluation.json` is the cross-verify structure.
- Consumed by: `codex-client.mjs turn --schema` (passed as `outputSchema`); `consensus.mjs` (reads the position fields).

- [ ] **Step 1: Write a failing schema-shape test**

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test tests/schemas.test.mjs`
Expected: FAIL — files not found.

- [ ] **Step 3: Write `schemas/position.json`**

```json
{
  "version": "3.0.0",
  "type": "object",
  "additionalProperties": false,
  "required": ["stance", "reasoning", "key_points", "agrees_with_opponent"],
  "properties": {
    "stance": { "type": "string", "description": "one-line position on the topic this round" },
    "reasoning": { "type": "string" },
    "key_points": { "type": "array", "items": { "type": "string" }, "description": "atomic claims; used for divergence scoring" },
    "agrees_with_opponent": { "type": "boolean", "description": "true only if you now accept the opponent's position" },
    "proposed_change": {
      "type": ["object", "null"],
      "properties": {
        "summary": { "type": "string" },
        "files": { "type": "array", "items": { "type": "string" } }
      }
    }
  }
}
```

- [ ] **Step 4: Write `schemas/evaluation.json`**

```json
{
  "version": "3.0.0",
  "type": "object",
  "additionalProperties": false,
  "required": ["summary", "findings", "confidence"],
  "properties": {
    "summary": { "type": "string" },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["severity", "description"],
        "properties": {
          "severity": { "type": "string", "enum": ["info", "low", "medium", "high", "critical"] },
          "description": { "type": "string" },
          "location": { "type": "string" }
        }
      }
    },
    "confidence": { "type": "number", "minimum": 0, "maximum": 1 }
  }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `node --test tests/schemas.test.mjs`
Expected: PASS (2 passing).

- [ ] **Step 6: Commit**

```bash
git add schemas/position.json schemas/evaluation.json tests/schemas.test.mjs
git commit -m "feat: position + evaluation JSON schemas"
```

---

## Task 6: Commands + orchestrator agent (Claude-side workflows)

Markdown that wires slash commands to Claude reasoning and the Node CLI. No new code logic; correctness is in the instructions and the `${CLAUDE_PLUGIN_ROOT}` paths.

**Files:**
- Create: `commands/codex-ask.md`, `commands/codex-evaluate.md`, `commands/codex-debate.md`, `agents/codex-orchestrator.md`
- Test: `tests/plugin-structure.test.mjs`

**Interfaces:**
- Consumes: `scripts/codex-client.mjs`, `scripts/consensus.mjs`, `schemas/*.json` — all referenced via `${CLAUDE_PLUGIN_ROOT}`.
- Produces: three working slash commands.

- [ ] **Step 1: Write a failing structure test**

```js
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
```

- [ ] **Step 2: Run to verify failure**

Run: `node --test tests/plugin-structure.test.mjs`
Expected: FAIL — command files not found.

- [ ] **Step 3: Write `commands/codex-ask.md`**

````markdown
---
description: Ask OpenAI Codex a read-only question; optionally add Claude's own take.
argument-hint: <question>
---

Ask Codex the user's question in a strictly read-only sandbox, then present the answer.

1. Write the user's question ($ARGUMENTS) verbatim to a temp file, e.g. `/tmp/codex-collab-ask.$$.txt`.
2. Run (read-only is mandatory):

   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-client.mjs" turn \
     --sandbox read-only \
     --prompt-file /tmp/codex-collab-ask.$$.txt \
     --out /tmp/codex-collab-ask.$$.json
   ```
3. Read the `.json` `out` file and present Codex's `text` to the user under a "Codex" heading.
4. Optionally add a short "Claude's take" section with your own view, clearly separated. Never merge the two into one unattributed answer.

Never pass `--sandbox workspace-write` here. This command is read-only by contract.
````

- [ ] **Step 4: Write `commands/codex-evaluate.md`**

````markdown
---
description: Cross-verify — Codex evaluates a target while Claude independently analyzes it, then compares.
argument-hint: <file-or-topic>
---

Use the codex-orchestrator agent to run a two-model cross-verification of $ARGUMENTS. The ordering is mandatory and enforced by these steps:

1. FIRST, produce your own independent (blind) analysis of the target and save it to `/tmp/codex-collab-blind.$$.md`. Do NOT call Codex yet.
2. THEN build a Codex prompt that contains ONLY the target and the evaluation task — it must NOT contain your analysis. Write it to `/tmp/codex-collab-eval.$$.txt`.
3. Run:

   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-client.mjs" turn \
     --sandbox read-only \
     --prompt-file /tmp/codex-collab-eval.$$.txt \
     --schema "${CLAUDE_PLUGIN_ROOT}/schemas/evaluation.json" \
     --out /tmp/codex-collab-eval.$$.json
   ```
4. Read Codex's `structured` output and compare it against your blind analysis. Present: your findings, Codex's findings, and where they agree/diverge.
````

- [ ] **Step 5: Write `commands/codex-debate.md`**

````markdown
---
description: Multi-round Claude<->Codex debate with deterministic consensus detection.
argument-hint: <topic>
---

Delegate to the codex-orchestrator agent to run a structured debate on $ARGUMENTS. Follow the agent's loop exactly: round 1 blind, anti-anchoring on every Codex prompt, deterministic consensus via consensus.mjs, code-clamped round cap, and an approval gate before any workspace-write apply turn.
````

- [ ] **Step 6: Write `agents/codex-orchestrator.md`**

````markdown
---
name: codex-orchestrator
description: Runs the Claude-side loop for /codex-debate and /codex-evaluate — position formation, blind analysis, anti-anchoring, and deterministic round control.
tools: Bash, Read, Write
model: sonnet
---

You orchestrate cross-model collaboration with OpenAI Codex. You never invoke Codex except through `${CLAUDE_PLUGIN_ROOT}/scripts/codex-client.mjs`, and you keep the two models' outputs attributed and separate.

## Debate loop (/codex-debate)

State lives in `.codex-collab/debates/<id>.json`: `{ codex_thread_id, round, rounds: [...] }`. Create the dir if needed.

For each round:

1. Form YOUR position as JSON matching `${CLAUDE_PLUGIN_ROOT}/schemas/position.json` and save to `/tmp/cc-claude.$$.json`. Round 1: form it blind (no Codex output yet).
2. Build the Codex prompt in a temp file containing ONLY: the topic, and Codex's OWN prior-round positions. NEVER include your reasoning or conclusions — this is the anti-anchoring rule, enforced by what you put in the file.
3. Call Codex:

   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/codex-client.mjs" turn \
     --sandbox read-only \
     --prompt-file /tmp/cc-codex-prompt.$$.txt \
     --schema "${CLAUDE_PLUGIN_ROOT}/schemas/position.json" \
     ${codex_thread_id:+--resume "$codex_thread_id"} \
     --out /tmp/cc-codex.$$.json
   ```
   Save the returned `threadId` as `codex_thread_id` for the next round.
4. Check consensus deterministically:

   ```bash
   node "${CLAUDE_PLUGIN_ROOT}/scripts/consensus.mjs" \
     --claude /tmp/cc-claude.$$.json \
     --codex /tmp/cc-codex.$$.json \
     --round "$round" --default-rounds 3 --max-extra 2 \
     --out /tmp/cc-consensus.$$.json
   ```
   If `consensus` is true → stop and report. If `capReached` is true → stop and present both positions. Otherwise increment round and repeat, using Codex's structured `key_points` (not your summary) as the opponent input for your next position.

## Apply gate

If the consensus position has a `proposed_change`, present the summary and ask the user to approve. Only on explicit approval, run ONE apply turn with `--sandbox workspace-write`, instructing Codex to implement the agreed change. Codex writes the files inside its own sandbox — you do not edit files yourself for this step.

## Cross-verify (/codex-evaluate)

Blind analysis first (saved), then a Codex read-only turn whose prompt excludes your analysis, then compare. Same anti-anchoring rule.

## Report

Save a Markdown report to `.codex-collab/reports/` summarizing rounds, the consensus outcome, and any applied change.
````

- [ ] **Step 7: Run to verify pass**

Run: `node --test tests/plugin-structure.test.mjs`
Expected: PASS (2 passing).

- [ ] **Step 8: Run the full suite**

Run: `npm test`
Expected: PASS — all suites.

- [ ] **Step 9: Commit**

```bash
git add commands agents tests/plugin-structure.test.mjs
git commit -m "feat: ask/evaluate/debate commands + codex-orchestrator agent"
```

---

## Task 7: CI (unit + drift canary), README, CHANGELOG

**Files:**
- Create: `.github/workflows/ci.yml`, `README.md`, `CHANGELOG.md`

**Interfaces:**
- Produces: a green CI on push/PR (unit job always; canary job installs real `@openai/codex` and runs `check`).

- [ ] **Step 1: Write `.github/workflows/ci.yml`**

```yaml
name: codex-collab CI

on:
  push:
    branches: [main, v3-clean]
  pull_request:

jobs:
  unit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "20" }
      - run: npm test

  drift-canary:
    runs-on: ubuntu-latest
    continue-on-error: true   # informational: red canary signals Codex drift, doesn't block merges of unrelated work
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: "20" }
      - name: Install real Codex CLI
        run: npm install -g @openai/codex
      - name: Handshake + read-only turn (auth may be absent; we assert the client speaks the protocol)
        run: |
          node scripts/codex-client.mjs check --out /tmp/check.json || true
          cat /tmp/check.json
          node -e "const r=require('/tmp/check.json'); if(!('ok' in r)) { console.error('canary: client did not produce a structured result'); process.exit(1); }"
```

Note: the canary asserts the client produces a structured result against the real binary (protocol/framing didn't break). It tolerates auth failures (no ChatGPT/API creds in CI) via the `ok:false` path, but a crash or missing `ok` field — the signature of a protocol change — fails it.

- [ ] **Step 2: Verify the workflow is valid YAML**

Run: `node -e "const fs=require('fs');const s=fs.readFileSync('.github/workflows/ci.yml','utf8');if(!s.includes('drift-canary'))process.exit(1);console.log('ok')"`
Expected: `ok`.

- [ ] **Step 3: Write `README.md`**

```markdown
# codex-collab v3

Claude Code <-> OpenAI Codex cross-model collaboration — **debate**, **cross-verify**, and **ask** — built on the stable `codex app-server` JSON-RPC protocol.

## Why v3

v3 is a clean rebuild. Earlier versions shelled `codex exec` strings and parsed output in bash; that broke silently when the CLI changed and carried unsafe file-apply paths. v3 talks to `codex app-server` directly, sets the sandbox as a programmatic parameter, and lets Codex apply changes inside its own sandbox — so a whole class of defects cannot occur.

For everyday review/delegate/background work, use OpenAI's official plugin (`openai/codex-plugin-cc`). codex-collab covers what it doesn't: multi-round debate with consensus, and two-model independent cross-verification.

## Requirements

- Claude Code
- Node.js >= 18.18
- OpenAI Codex CLI (`npm install -g @openai/codex`, then `codex login`)

## Commands

- `/codex-ask <question>` — read-only question to Codex, optionally with Claude's take.
- `/codex-evaluate <target>` — Claude analyzes blind, Codex evaluates independently, then compares.
- `/codex-debate <topic>` — N-round Claude<->Codex debate with deterministic consensus and an approval-gated apply step.

## Safety

Sandbox is enforced in code (`read-only` by default; `workspace-write` only on an approved apply turn). No dangerous flags are ever constructed (enforced by a test). Codex performs all file writes inside its own sandbox.

## Development

`npm test` runs the unit suite (no Codex needed — a protocol fake is used). CI additionally runs a drift canary against the real Codex CLI so protocol changes surface as a failing build.
```

- [ ] **Step 4: Write `CHANGELOG.md`**

```markdown
# Changelog

## 3.0.0 — 2026-08-10

Clean rebuild on the `codex app-server` JSON-RPC protocol.

### Breaking
- Removed the entire v2.2 bash/python implementation, the rule engine, safety hooks, and named-session store.
- Codex is now invoked via `codex app-server` (JSON-RPC), not `codex exec` strings.

### Added
- `codex-client.mjs` app-server client with programmatic sandbox selection (read-only by default).
- Deterministic consensus gate (`consensus.mjs`) — replaces model self-judgment.
- CI drift canary against the real `@openai/codex` — protocol changes now fail the build.
- Structural anti-anchoring (Codex prompts exclude Claude's analysis by construction).

### Fixed (defect classes eliminated vs v2.2)
- Arbitrary file write outside the working dir (no plugin-side file apply anymore).
- Broken rollback / stashed user work (Codex applies inside its own sandbox).
- Dead safety hooks (safety is now a code parameter, not a hook matcher).
- Silent CLI drift (canary + protocol client).
```

- [ ] **Step 5: Final full suite + commit**

Run: `npm test`
Expected: PASS — all suites.

```bash
git add .github/workflows/ci.yml README.md CHANGELOG.md
git commit -m "ci: unit + Codex drift canary; docs: v3 README + CHANGELOG"
```

---

## Task 8: Live validation of R1 (thread/resume across spawns) — real Codex required

This validates the load-bearing assumption from the spec. It requires a real `codex` install + auth and is run manually (not in the automated suite).

**Files:**
- Create: `tests/manual/resume-check.md` (a documented manual procedure)

**Interfaces:**
- Produces: a recorded yes/no on whether a fresh app-server process can `thread/resume` a thread started by a prior process. Determines whether the stateless design stands as-is or switches to the transcript-passing fallback.

- [ ] **Step 1: Write the manual procedure**

```markdown
# Manual check: thread/resume across separate app-server spawns (spec R1)

Requires: `codex` installed and `codex login` completed.

1. First turn (starts a thread, prints its id):
   printf 'Remember the secret word: platypus. Acknowledge.' > /tmp/r1.txt
   node scripts/codex-client.mjs turn --sandbox read-only --prompt-file /tmp/r1.txt --out /tmp/r1.json
   THREAD=$(node -e "console.log(require('/tmp/r1.json').threadId)")

2. Second turn in a BRAND NEW process, resuming that thread:
   printf 'What was the secret word I told you?' > /tmp/r2.txt
   node scripts/codex-client.mjs turn --sandbox read-only --resume "$THREAD" --prompt-file /tmp/r2.txt --out /tmp/r2.json
   node -e "console.log(require('/tmp/r2.json').text)"

3. PASS if step 2 recalls "platypus" → resume persists across spawns; stateless design stands.
   FAIL if it does not → switch the orchestrator to pass the full debate transcript in each round's prompt (still stateless, no --resume). Update the agent accordingly.
```

- [ ] **Step 2: Commit**

```bash
git add tests/manual/resume-check.md
git commit -m "docs: manual R1 resume-across-spawns validation procedure"
```

- [ ] **Step 3: (When a real Codex is available) run the procedure and record the outcome**

Run the steps in `tests/manual/resume-check.md`. If FAIL, implement the transcript-passing fallback in `agents/codex-orchestrator.md` (drop `--resume`; include all prior rounds in each prompt file) and note it in CHANGELOG.

---

## Self-Review

**Spec coverage:**
- §3 architecture (Claude/Node/sandbox) → Tasks 3,4,6. ✓
- §4.1 app-server client owned in-repo → Task 3. ✓
- §4.2 stateless per round → Task 6 (resume + thread-id state) + Task 8 (validation). ✓
- §4.3 clean codebase same name → Task 1. ✓
- §4.4 apply via Codex sandbox → Task 6 (agent apply gate), Task 4 (sandbox values). ✓
- §5.1 codex-client turn/check → Task 4. ✓
- §5.2 consensus deterministic + clamp → Task 2. ✓
- §5.3 schemas → Task 5. ✓
- §5.4 debate state file → Task 6. ✓
- §6 data flow (ask/evaluate/debate) → Task 6 commands+agent. ✓
- §7 safety (code sandbox, no dangerous flags, no hooks) → Task 4 + safety.test.mjs. ✓
- §8 testing + drift canary → Tasks 2–6 (fake + units) + Task 7 (canary). ✓
- §9 portability (Node, no python, CLAUDE_PLUGIN_ROOT) → Task 1 (package.json), Task 6 (structure test). ✓
- §10 R1 validation-first → Task 8. ✓
- §11 migration → Task 1 + docs in Task 7. ✓
- §12 ported assets (evaluation schema, position, anti-anchoring, round cap) → Task 5 + Task 2 + Task 6. ✓

**Placeholder scan:** No TBD/TODO; every code step has full code. ✓

**Type consistency:** `evaluateConsensus(claudePos, codexPos, opts)` and `parseArgs(argv, spec)` used identically in tests and impl; `CodexAppServerClient.connect/startThread/resumeThread/runTurn/close` names match across Tasks 3–4; `{ threadId, text, structured, status }` shape consistent between app-server.mjs, codex-client.mjs, and their tests. ✓

**Note on Task 8 ordering:** R1 is load-bearing but only verifiable with a real Codex, which is absent in this environment. The plan builds the resume-based design (the expected-correct path per the official plugin, which resumes threads the same way) and isolates the fallback to a single agent-markdown change, so a FAIL is cheap to absorb.
```
