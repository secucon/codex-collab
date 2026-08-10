# codex-collab v3 — Design Spec

**Date:** 2026-08-10
**Status:** Approved (design), pending spec review → implementation plan
**Author:** jguru + Claude

## 1. Context & Problem

codex-collab v2.2 integrates OpenAI Codex by having an LLM type `codex exec` strings into Bash, with bash/python scripts doing post-hoc parsing. A cold analysis (2026-08-09) found verified, reproduced P0 defects:

- Write path already broken on current stable Codex (`codex exec --full-auto` removed upstream, PR #36054, stable in rust-v0.147.0 on 2026-08-07); the test mock accepts any flag, so drift is invisible.
- The entire bash script layer is unreachable when installed as a plugin (0 uses of `${CLAUDE_PLUGIN_ROOT}`; all `source scripts/…` are cwd-relative).
- All 5 safety hooks are dead (matcher uses an invented expression DSL; Claude Code's matcher is a tool-name regex).
- Arbitrary file write outside the working dir via `../` path traversal; broken rollback that git-stashes the user's work while reporting success; indefinite stdin deadlock in dead code.
- CI red on main (`validate-plugin.sh` FAILs).

Meanwhile OpenAI shipped an official plugin (`openai/codex-plugin-cc`) that wraps the stable `codex app-server` JSON-RPC protocol. It covers review/delegate/background/transfer well but **lacks** codex-collab's unique value: multi-round Claude↔Codex debate with consensus detection, and two-model independent cross-verification.

**Goal:** rebuild codex-collab so its unique workflows (debate, cross-verify, quick read-only ask) run on the official plugin's proven substrate pattern — app-server + programmatic sandbox — shedding the bash-scrapes-CLI maintenance tax and the entire P0 defect class.

## 2. Goals & Non-Goals

**Goals**
- Preserve the three workflows: `/codex-ask`, `/codex-evaluate`, `/codex-debate`.
- Invoke Codex through `codex app-server` (stable JSON-RPC), with the sandbox set as a **programmatic parameter**, not a model-typed flag.
- Eliminate the P0 class structurally: no plugin-side file writes (Codex writes inside its own sandbox), no dead hooks, no CLI-flag guessing.
- Add a **drift canary** in CI (install real `@openai/codex`, run a real turn) so breakage is a red build, not silent.
- Keep the marketplace name `codex-collab` and the existing repo.

**Non-Goals (v1 / YAGNI)**
- No persistent/warm app-server broker, no background job store, no status/result/cancel surface (the official plugin already does this; our debate is bounded and synchronous).
- No session-transfer / rescue commands (defer to the official plugin; document the pairing).
- No rule engine, no auto-trigger safety debate, no named long-lived sessions.

## 3. Architecture

**One sentence:** Claude reasons, Node does I/O, the sandbox is the defense line.

```
commands/*.md ──▶ agents/*.md   (Claude: forms positions, blind analysis, round decisions)
                       │  Bash: node scripts/codex-client.mjs turn ...
                       ▼
             scripts/codex-client.mjs  (Node, zero deps)
                       │  JSON-RPC over stdio
                       ▼
                codex app-server  ──▶ sandbox: 'read-only' | 'workspace-write'  (code decides)
```

**Boundaries.** Reasoning (should we converge? what's the rebuttal?) is Claude's. Codex invocation, sandbox selection, and structured output are Node's. Consensus is a deterministic pure function. Each unit is independently testable.

**Language.** The only Node is `codex-client.mjs` and `consensus.mjs`. Commands, agents, and schemas stay markdown/JSON. **No python3 dependency. No `set -euo pipefail` leakage.** Node ≥18.18 (matches official), zero runtime dependencies.

## 4. Key Decisions

1. **app-server client, owned in-repo (~small).** We speak JSON-RPC to `codex app-server` directly (initialize with `experimentalApi: false`; `thread/start`, `turn/start`, `thread/resume`). We are on a versioned, documented protocol that powers OpenAI's own VS Code extension — CLI flag drift no longer reaches us. **License:** the official plugin is Apache-2.0 and codex-collab is MIT; we implement the client from the documented protocol, using the official source only as a reference. Any code copied verbatim gets a NOTICE attribution per Apache-2.0 §4.
2. **Stateless per round; no broker.** Each round spawns `codex app-server`, resumes the thread, runs one turn, closes. The only cross-round state is a stored **thread-id**. Accepted trade-off: per-round cold-start latency (~seconds × ~2 turns/round). A seam is left to add a warm broker later if latency hurts.
3. **New clean codebase, same name/repo.** v3 replaces the bash implementation; the marketplace name stays `codex-collab`. v2.2 is preserved via the existing `v2.2.0` git tag / commit for reference. v3 is built on a branch and becomes main when green.
4. **Apply via Codex's sandbox, never plugin-side.** When debate consensus yields a code change, a single `workspace-write` Codex turn (behind a user-approval gate) makes Codex apply it inside its own sandbox. No plugin-side file writing → path traversal, `cp` escape, and broken rollback cannot exist.

## 5. Components

```
codex-collab/                         (v3, clean)
  .claude-plugin/plugin.json          name: codex-collab, v3.0.0
  commands/
    codex-ask.md
    codex-evaluate.md
    codex-debate.md
  agents/
    codex-orchestrator.md             Claude-side debate loop + cross-verify reasoning
                                      (drives /codex-debate and /codex-evaluate; /codex-ask is command-only)
  scripts/
    codex-client.mjs                  app-server JSON-RPC client (the only Codex I/O)
    consensus.mjs                     deterministic consensus gate (pure fn + thin CLI)
    lib/                              minimal helpers (path safety, temp files)
  schemas/
    position.json                     debate round position (incl. agrees_with_opponent)
    evaluation.json                   cross-verify structured output (ported, cleaned)
  tests/
    codex-client.test.mjs             against fake-app-server (real JSON-RPC framing)
    consensus.test.mjs                pure unit
    fake-app-server.mjs               minimal fake speaking the real protocol
  .github/workflows/ci.yml            unit tests + DRIFT CANARY (real @openai/codex)
  README.md, CHANGELOG.md, docs/
```

### 5.1 `codex-client.mjs` (CLI, invoked by the agent via Bash)

- `node codex-client.mjs turn --sandbox <read-only|workspace-write> [--schema <path>] --prompt-file <path> [--resume <thread-id>] --out <path>`
  - Spawns `codex app-server`; `initialize` (`experimentalApi:false`); if `--resume` → `thread/resume`, else `thread/start` with the sandbox; sends `turn/start` with the prompt; awaits completion; writes `{ threadId, text, structured? }` JSON to `--out`; closes the process.
  - **Prompt is passed by file, never interpolated into the shell** — closes shell-injection and keeps anti-anchoring enforceable (the file is built from allowed inputs only).
- `node codex-client.mjs check --out <path>` — verifies `codex` availability + a real app-server handshake. Used by CI canary and a lightweight setup check.

### 5.2 `consensus.mjs`

- `node consensus.mjs --claude <position.json> --codex <position.json> --out <path>` → `{ consensus: bool, divergence: number, reason }`.
- **Deterministic:** reads `agrees_with_opponent` on both sides and a simple divergence metric over `key_points`. No model self-judgment. Round cap (`default_rounds + min(extra, 2)`) is clamped here.

### 5.3 Schemas

- `position.json`: `{ stance, reasoning, key_points[], agrees_with_opponent: bool, proposed_change?: { summary, files[] } }`
- `evaluation.json`: ported from v2.2, cleaned (versioned).

### 5.4 State

- A debate keeps a small working file under `.codex-collab/debates/<id>.json`: `{ codex_thread_id, rounds[] }`, written/read by the orchestrator between rounds via Write/Read tools. Single debate per invocation → no locking. Reports saved to `.codex-collab/reports/`.

## 6. Data Flow

**/codex-ask `<q>`** — one `read-only` turn via `codex-client`. Return Codex's answer; optionally append Claude's own take, clearly labeled. (Fills the read-only-Q&A gap the official plugin lacks.)

**/codex-evaluate `<target>`**
1. Claude produces a **blind** independent analysis of the target and saves it.
2. `codex-client turn --sandbox read-only --schema evaluation.json` on the target; **the Codex prompt excludes Claude's analysis**.
3. Claude compares its analysis vs Codex's structured evaluation → merged report. Blind-first ordering is enforced by the step sequence, not a header self-check.

**/codex-debate `<topic>`**
1. Round 1: Claude forms its position (blind — no Codex yet).
2. `codex-client turn --sandbox read-only --schema position.json` with a prompt built from **topic + Codex's own prior turns only** (anti-anchoring by construction). First round `thread/start`; later rounds `--resume <thread-id>`.
3. `consensus.mjs` reads both positions → consensus? stop : next round. Loop until consensus or the code-clamped round cap.
4. On consensus with a `proposed_change`: **user-approval gate →** one `workspace-write` Codex turn instructs Codex to apply the agreed change inside its sandbox.
5. Save report.

## 7. Safety Model

- Enforcement is the **sandbox parameter in code**, defaulting to `read-only` everywhere; `workspace-write` only on the explicit, approval-gated apply turn.
- `--dangerously-*` is never constructed anywhere (asserted by a grep test).
- **No safety hooks in v1.** The dead-hook problem disappears because safety is structural, not matcher-based. (A single correctly-matched PreToolUse warn-hook is a possible later add, not needed for enforcement.)

## 8. Testing & CI

- **Unit:** `codex-client` against `fake-app-server.mjs` (speaks the real JSON-RPC framing); `consensus.mjs` pure unit incl. round-cap clamp and both `agrees_with_opponent` combinations.
- **Drift canary (the thing v2.2 lacked):** a CI job runs `npm install -g @openai/codex`, then `node codex-client.mjs check` performing a real `read-only` turn, and asserts a response. Protocol/CLI drift → red build.
- **Injection-safety test:** assert no `--dangerously`/`danger-full-access` string is ever emitted; assert prompts go via file, not shell interpolation.
- Green CI is the release gate (v2.2's `validate-plugin.sh` FAIL must not recur).

## 9. Portability

- Node ≥18.18, zero runtime deps. No python3. No bash pipeline as load-bearing logic. No fixed-width box-drawing UI assuming a TTY. Works from any cwd (all script paths resolved via `${CLAUDE_PLUGIN_ROOT}` in command/agent frontmatter).

## 10. Risks & Validation-First Tasks

- **R1 (load-bearing): `thread/resume` across separate app-server spawns.** The stateless design assumes Codex persists threads on disk so a fresh app-server can resume them. **Must be verified first** against a real `codex`. Fallback if false: pass the full debate transcript in each round's prompt (no resume) — still stateless, higher token cost. Design survives either way.
- **R2: app-server handshake/framing details.** Derive exact `initialize` params and message framing from the official `plugins/codex/scripts/lib/app-server.mjs` + Codex app-server docs during implementation; encode them in `fake-app-server.mjs`.
- **R3: cold-start latency.** Accepted for v1; warm-broker seam documented.
- **R4: `codex` not installed in the dev/CI base image.** Integration test + canary require it; unit tests use the fake and run without it.

## 11. Migration

- Build v3 on a branch. Keep `codex-collab` name and repo. Preserve v2.2 via its existing git tag for reference. Port only verified assets: `evaluation.json`, the debate position concept, anti-anchoring prompt language, the round-cap concept (now code). Delete the bash/python implementation, dead hooks, and orphan scripts. README rewritten for v3; CHANGELOG notes the clean break and the reason (v2.2 P0s + move to app-server).

## 12. Ported Assets (from v2.2)

- `schemas/evaluation.json` (cleaned, versioned)
- Debate round/position structure → `schemas/position.json`
- Anti-anchoring prompt wording (Blind Phase / Comparison Phase) → agent prompt, now backed by structural ordering
- Round-cap policy (`default_rounds + ≤2`) → `consensus.mjs` clamp
