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
