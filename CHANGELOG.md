# Changelog

## Unreleased

First validation against a real, authenticated `codex` (CLI 0.147.0). Both
manual checks parked in `tests/manual/` since 3.0.0 have now been run.

### Fixed
- **Structured output was broken against real Codex.** Both `schemas/position.json`
  and `schemas/evaluation.json` were rejected with `400 invalid_json_schema`,
  so `/codex-evaluate` and `/codex-debate` could not complete a single turn.
  `scripts/lib/schema.mjs` now normalizes the schema **in memory** before it is
  sent (`strictifySchema`): the non-standard top-level `version` is dropped,
  every object node gets `additionalProperties: false`, every property key is
  added to `required`, and properties that were optional become nullable. The
  on-disk schemas are unchanged and remain the human-readable contracts.
- **`/codex-debate` could never reach consensus.** `agents/codex-orchestrator.md`
  applied the anti-anchoring rule to every round, so Codex was never shown
  Claude's position and its `agrees_with_opponent` had no referent — while the
  gate requires both sides to agree. Anti-anchoring now scopes to round 1 only;
  rounds 2+ carry the opponent's prior position verbatim. Verified live: the same
  round-2 positions score `consensus: false` under the old prompt shape and
  `consensus: true` under the new one.

### Verified against real Codex (2026-08-16)
- `thread/resume` **does** resume a thread across separate app-server processes
  (`tests/manual/resume-check.md` → PASS). The stateless-per-round design stands;
  the transcript-passing fallback is not needed.
- STRICT mode **accepts** `minimum`/`maximum` — the third hypothesis in
  `tests/manual/schema-acceptance-check.md` was wrong. Numeric range keywords are
  deliberately preserved so `evaluation.confidence` keeps its 0..1 contract.

### Known limitations
- `strictifySchema` traverses only inline `properties` and `items`. Schemas using
  `anyOf`/`oneOf`/`allOf`/`$defs`/`$ref`, or an object node with no `properties`,
  are not normalized. Neither shipped schema uses them.
- `consensus.mjs` reports `divergence` as an exact-string set difference over
  free-text `key_points`, so it is very nearly always `|a| + |b|` and carries no
  usable signal. It is informational only — it does not gate the loop.

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
