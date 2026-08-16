# codex-collab v3

Claude Code <-> OpenAI Codex cross-model collaboration — **debate**, **cross-verify**, and **ask** — built on the stable `codex app-server` JSON-RPC protocol.

## Why v3

v3 is a clean rebuild. Earlier versions shelled `codex exec` strings and parsed output in bash; that broke silently when the CLI changed and carried unsafe file-apply paths. v3 talks to `codex app-server` directly, sets the sandbox as a programmatic parameter, and lets Codex apply changes inside its own sandbox — so a whole class of defects cannot occur.

For everyday review/delegate/background work, use OpenAI's official plugin (`openai/codex-plugin-cc`). codex-collab covers what it doesn't: multi-round debate with consensus, and two-model independent cross-verification.

## Requirements

- Claude Code
- Node.js >= 18.18
- OpenAI Codex CLI (`npm install -g @openai/codex`, then `codex login`)

## Install

In Claude Code:

```
/plugin marketplace add secucon/codex-collab
/plugin install codex-collab@codex-collab
```

Verify with `/plugin` — the three commands below should be listed. To install from a local checkout instead, use `/plugin marketplace add /path/to/codex-collab`.

## Commands

- `/codex-ask <question>` — read-only question to Codex, optionally with Claude's take.
- `/codex-evaluate <target>` — Claude analyzes blind, Codex evaluates independently, then compares.
- `/codex-debate <topic>` — N-round Claude<->Codex debate with deterministic consensus and an approval-gated apply step.

## Safety

Sandbox is enforced in code (`read-only` by default; `workspace-write` only on an approved apply turn). No dangerous flags are ever constructed (enforced by a test). Codex performs all file writes inside its own sandbox.

Verified live on 2026-08-16 against a real Codex: under `read-only` a write request is refused and no file is created; under `workspace-write` a write inside the working directory succeeds while a write to a path outside it is refused. Note that Codex's `workspace-write` policy also permits writes to `/tmp` and `$TMPDIR` — that is Codex's own sandbox definition, not just the working directory, so do not treat "workspace-write" as "cwd only".

The consensus gate refuses to score a turn that failed: a `status: "error"` or missing `structured` on either side exits non-zero and writes a stop marker, so a crashed Codex turn cannot silently become a debate round.

## Development

`npm test` runs the unit suite (no Codex needed — a protocol fake is used).

Hang protection: JSON-RPC requests time out after 30s and an acknowledged turn times out after 10 minutes without `turn/completed` (override via `CODEX_COLLAB_REQUEST_TIMEOUT_MS` / `CODEX_COLLAB_TURN_TIMEOUT_MS`). `turn`/`check` write a failure marker to `--out` before doing any work, so even a killed process never leaves a previous run's result readable as fresh. CI additionally runs a drift canary against the real Codex CLI: it detects client-liveness and app-server protocol/handshake drift (the `initialize` handshake needs no auth, so a broken handshake fails the build). Asserting a fully successful live turn additionally requires Codex auth in CI, so a turn-level auth failure is tolerated.
