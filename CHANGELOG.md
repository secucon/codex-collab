# Changelog

## 3.0.1 — 2026-08-10

Hardening fast-follow: hang and stale-output protection.

### Fixed
- A hung app-server can no longer hang the client: JSON-RPC requests time out (default 30s), and an acknowledged turn times out without `turn/completed` (default 10 min). Override via `CODEX_COLLAB_REQUEST_TIMEOUT_MS` / `CODEX_COLLAB_TURN_TIMEOUT_MS`.
- A failed handshake no longer leaks the spawned app-server process.
- `turn`/`check` write a pending failure marker to `--out` before doing any work, so a killed process (e.g. a caller-side timeout) can never leave a previous run's result readable as fresh — closes the `/codex-ask` stale-answer window.
- Local input errors (missing prompt file, invalid schema or sandbox) now write the error marker too, instead of leaving `--out` stale.

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
