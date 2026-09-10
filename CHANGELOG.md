# Changelog

## 3.1.1 — 2026-09-10

### Fixed
- Consensus requires both models to explicitly accept the SHA-256 of the same
  candidate proposal. Votes on previous opposing positions no longer establish
  consensus when the models swap positions. Position schema 3.1.1 adds required
  `accepted_proposal_id` (null for rejection or a blind round). Old boolean-only
  positions cannot establish consensus; start a fresh debate after upgrading.
- Only completed turns succeed. Interrupted/failed turns and invalid structured
  JSON become error results; bundled position/evaluation outputs also receive
  local domain validation. Check no longer reports interrupted turns as healthy.
- Match notifications by thread and turn, preserve final answers over commentary,
  tolerate retryable errors, and answer server requests with declines or explicit
  unsupported-method errors. Reject overlapping turns on one client.
- Bound shutdown with SIGTERM then SIGKILL, interrupt timed-out turns, cap retained
  stderr, and validate timeouts and round-limit numbers.
- Give every command a UUID run directory. Debate rounds use an exclusive lock
  and atomically save state before stopping, including the terminal round.
- CI distinguishes explicit authentication failures from protocol errors; a pinned
  0.154.0 canary is required and latest-CLI drift remains advisory. Unit matrix
  covers Node 18, 20, 22 and 24.

### Changed
- Node now builds debate prompts, resumes threads, scores and records rounds,
  and enforces the five-round cap via `scripts/workflow.mjs`.
- Resumed debate prompts omit Codex's already-persisted prior responses.
- CLI accepts `--model`, `--effort`, and `--run-id`; results include phase timings,
  prompt bytes, turn ID and server-reported token usage (null when unavailable).
- Runs and reports live under `.codex-collab/runs/<runId>/`. Persistent connections
  and parallel model evaluation remain deferred until latency is measured.

## 3.1.0 — 2026-08-16

### Changed (BREAKING — command names)
- The three commands dropped the redundant `codex-` prefix, since the plugin
  name already namespaces them. `/codex-collab:codex-ask` was saying "codex"
  twice.

  | before | after |
  | --- | --- |
  | `/codex-collab:codex-ask` | `/codex-collab:ask` |
  | `/codex-collab:codex-evaluate` | `/codex-collab:evaluate` |
  | `/codex-collab:codex-debate` | `/codex-collab:debate` |

  Only the file names and the prose that names them changed; no script,
  schema, or protocol behaviour is affected. Versioned as a minor bump rather
  than a major one because the v3 architecture is untouched — the break is
  limited to what a user types.

## 3.0.2 — 2026-08-16

First validation against a real, authenticated `codex` (CLI 0.147.0). Both
manual checks parked in `tests/manual/` since 3.0.0 have now been run, and the
paths they could not reach were exercised live.

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
- **The consensus gate scored failed turns.** A codex-client error marker
  (`status: "error"`, `structured: null`) fed to `consensus.mjs` produced an
  ordinary `"divergence N, continue"` verdict and exit 0, so a crashed Codex turn
  could silently become a debate round — the only guard was the orchestrator
  remembering to check. `evaluateConsensus` now refuses an unusable position on
  either side, and the CLI writes a pending marker before doing any work, exits 1,
  and leaves a `capReached: true` stop marker so an unscoreable round halts the
  loop instead of spinning.
- `strictifySchema` now traverses `anyOf`/`oneOf`/`prefixItems` and
  `$defs`/`definitions`, closes object nodes that declare no `properties`,
  normalizes `required` to exactly the property keys (dropping duplicates and
  entries with no matching property), and can express nullability for `$ref`,
  `anyOf`/`oneOf` and untyped `enum` properties — all of which previously became
  required-but-not-nullable.
- **`strictifySchema` refuses what it cannot normalize instead of silently
  changing it.** Its two rewrites — closing an object and promoting optional
  properties to required-but-nullable — preserve meaning only in plain
  `properties`/`items`/union positions. Inside an applicator they change what the
  schema *matches*: closing every `allOf` branch makes an intersection of
  differing branches unsatisfiable, and forcing `required` inside an `if` inverts
  the condition for an absent key. So `allOf`, `not`, `if`/`then`/`else`,
  `contains`, `propertyNames`, `patternProperties`, `dependentSchemas`,
  `dependencies`, `unevaluated*`, `additionalItems` and `contentSchema` now throw
  with the offending path, as does a schema-valued `additionalProperties` (which
  was previously overwritten with `false`, narrowing "any string-valued key" to
  "no keys at all") and an optional property with no `type`/`$ref`/`anyOf`/`enum`
  to widen (which previously became required AND non-nullable).
- **The debate spec depended on shell state that does not survive a Bash call.**
  `agents/codex-orchestrator.md` used `${codex_thread_id:+--resume "$codex_thread_id"}`
  and `--round "$round"`, neither of which any step ever assigned. Pasted verbatim
  they expand to nothing, so `--resume` silently vanished and every round started a
  fresh Codex thread — no error, no continuity. All snippets now use literal values,
  the thread id is read from the previous round's `-codex.json`, and a test fails the
  build if any command/agent bash snippet references a variable other than
  `CLAUDE_PLUGIN_ROOT`.
- Other debate-spec defects, found by running the loop end to end with a real agent:
  round-2+ prompts pointed at a `structured` key that a Claude position file never
  has (only Codex output files are wrapped); per-round temp paths carried the round
  number but not the debate id, so a second debate overwrote the first one's
  artifacts; the state file's shape was declared but no step wrote it; the reports
  directory was never created and the report filename was unspecified; and "the
  topic ONLY" for round 1 forbade even a neutral instruction. All are now specified.
- Documented in the spec: both sides answer `agrees_with_opponent` against the
  opponent's *previous* position, so mutual agreement becomes visible to the gate one
  round after it actually occurs — and `divergence` can rise while the two sides
  converge, so it must not be presented as a convergence metric.

### Verified against real Codex (2026-08-16)
- `thread/resume` **does** resume a thread across separate app-server processes
  (`tests/manual/resume-check.md` → PASS). The stateless-per-round design stands;
  the transcript-passing fallback is not needed.
- STRICT mode **accepts** `minimum`/`maximum` — the third hypothesis in
  `tests/manual/schema-acceptance-check.md` was wrong. Numeric range keywords are
  deliberately preserved so `evaluation.confidence` keeps its 0..1 contract.
- A schema exercising `$defs` + `$ref`, an `anyOf` union, an untyped `enum`, an
  object with no `properties` and a `minimum`/`maximum` range is **accepted** after
  normalization and **rejected** before it (`400 invalid_json_schema`), so the
  normalizer is load-bearing rather than decorative.
- The apply gate behaves as documented: under `workspace-write` a write inside the
  working directory succeeds and a write outside it is refused; under `read-only`
  no file is created. Codex's `workspace-write` policy does also permit `/tmp` and
  `$TMPDIR` — see the Safety section of the README.

### Known limitations
- `$ref` targets are never resolved or inlined. A local `$ref` is normalized only
  because `$defs`/`definitions` are traversed in their own right; a ref pointing
  outside the document is left untouched. Traversing a keyword also does not make
  STRICT mode *support* it.
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
