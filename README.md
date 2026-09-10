# codex-collab v3

**English** | [한국어](README.ko.md)

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

- `/codex-collab:ask <question>` — read-only question to Codex, optionally with Claude's take.
- `/codex-collab:evaluate <target>` — Claude analyzes blind, Codex evaluates independently, then compares.
- `/codex-collab:debate <topic>` — N-round Claude<->Codex debate with deterministic consensus and an approval-gated apply step.

## Safety

Sandbox is enforced in code (`read-only` by default; `workspace-write` only on an approved apply turn). No dangerous flags are ever constructed (enforced by a test). Codex performs all file writes inside its own sandbox.

Verified live on 2026-08-16 against a real Codex: under `read-only` a write request is refused and no file is created; under `workspace-write` a write inside the working directory succeeds while a write to a path outside it is refused. Note that Codex's `workspace-write` policy also permits writes to `/tmp` and `$TMPDIR` — that is Codex's own sandbox definition, not just the working directory, so do not treat "workspace-write" as "cwd only".

Only `status: "completed"` is a successful turn. Failed/interrupted turns, malformed JSON, and invalid bundled output contracts are rejected. The consensus gate requires both models to explicitly accept the same candidate proposal's SHA-256; accepting different previous positions is not consensus. The approved apply content comes from that shared proposal.

A malformed or mismatched vote in an otherwise valid completed analysis counts as non-acceptance. The round records warnings and original votes, and the debate can continue. Analysis-body and transport failures still stop the run.

Every invocation gets a UUID directory under `.codex-collab/runs/`. Node manages debate state, exclusive round locks, thread resume and the five-round cap. Reports live in each run's `report.md`. First-round analysis is blind; subsequent rounds discuss a fixed shared candidate. The models share filesystem access, so anti-anchoring is a behavioral rule, not filesystem isolation.

Existing boolean-only debate artifacts do not establish consensus with the new position schema. Start a fresh debate after upgrading; old reports remain untouched.

## Performance controls

`codex-client.mjs turn` and `workflow.mjs round` accept `--model` and `--effort`. Results record connection, thread start/resume and turn durations, total time through result creation (excluding shutdown), prompt bytes and server-reported token usage. Token usage is null when the server does not report it; it is not a billing estimate.

Resumed debate prompts send the new candidate instead of repeating Codex's previous replies. Each round still starts a fresh app-server process, and evaluation remains sequential. Measure the recorded timings before adding a persistent connection or parallel evaluation.

## Development

`npm test` runs the unit suite (no Codex needed — a protocol fake is used).

`node tests/manual/live-debate-check.mjs` explicitly runs two authenticated, read-only Codex turns against a deterministic peer fixture. It checks structured output, thread resume and consensus and saves protocol field shapes in a temporary run directory. This consumes model usage and is not part of `npm test`.

Hang protection: JSON-RPC requests time out after 30s and an acknowledged turn times out after 10 minutes (override via `CODEX_COLLAB_REQUEST_TIMEOUT_MS` / `CODEX_COLLAB_TURN_TIMEOUT_MS`). A timed-out turn is interrupted; shutdown sends SIGTERM after 50ms and SIGKILL after 1s if necessary. `turn`/`check` write failure markers before connecting. The non-interactive client declines permission/elicitation requests and explicitly rejects unsupported server requests.

CI runs unit tests on Node 18/20/22/24, a required Codex 0.154.0 canary and an advisory latest-CLI canary. Only explicit post-handshake authentication failures are tolerated; invalid parameters and timeouts fail the canary. An unauthenticated canary does not verify model output or structured-schema acceptance. A failed or interrupted debate stops; do not remove a round lock while a prior invocation might still be alive.
