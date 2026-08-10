# Manual check: thread/resume across separate app-server spawns (spec R1)

This validates the load-bearing assumption behind the v3 stateless-per-round
design: that a **fresh** `codex app-server` process can `thread/resume` a thread
started by a **prior**, already-exited process. If it can, debate continuity
survives across separate Bash calls with no long-lived process. It requires a
real `codex` install + auth and is run manually — it is **not** part of the
automated `npm test` suite.

Requires: `codex` installed and `codex login` completed.
Run all commands **from the repository root** (so `node scripts/codex-client.mjs`
resolves). Each `node scripts/codex-client.mjs turn ...` invocation is its own
short-lived process that connects, runs one turn, and exits — so step 2 really is
a brand-new app-server spawn, which is the whole point of the check.

1. First turn (starts a thread, prints its id):
   ```bash
   printf 'Remember the secret word: platypus. Acknowledge.' > /tmp/r1.txt
   node scripts/codex-client.mjs turn --sandbox read-only --prompt-file /tmp/r1.txt --out /tmp/r1.json
   THREAD=$(node -e "console.log(require('/tmp/r1.json').threadId)")
   ```

2. Second turn in a BRAND NEW process, resuming that thread:
   ```bash
   printf 'What was the secret word I told you?' > /tmp/r2.txt
   node scripts/codex-client.mjs turn --sandbox read-only --resume "$THREAD" --prompt-file /tmp/r2.txt --out /tmp/r2.json
   node -e "console.log(require('/tmp/r2.json').text)"
   ```

3. **PASS** if step 2 recalls "platypus" → resume persists across spawns; the
   stateless design stands as-is.
   **FAIL** if it does not (the model has no memory of the first turn, or
   `thread/resume` errors) → switch the orchestrator to pass the full debate
   transcript in each round's prompt (still stateless, no `--resume`). Update the
   agent accordingly.

## If it FAILS: the transcript-passing fallback

The fallback keeps the design stateless — it just stops relying on `--resume` for
continuity and instead reconstructs context in the prompt each round:

- In `agents/codex-orchestrator.md`, drop the `--resume "$THREAD"` flag from the
  per-round `turn` calls.
- Before each round, build the prompt file by concatenating **all prior rounds**
  (both sides' positions/evaluations) ahead of the new instruction, so Codex sees
  the complete debate history in-band on every turn.
- Record the outcome (and that the fallback is now in effect) in `CHANGELOG.md`.

Nothing about the Node client (`scripts/codex-client.mjs`,
`scripts/lib/app-server.mjs`) needs to change: `--resume` simply goes unused, and
`thread/start` is used for every round.

## See also

- [`schema-acceptance-check.md`](./schema-acceptance-check.md) — the second
  real-Codex manual check: does Codex's structured-output STRICT mode accept
  `schemas/position.json` and `schemas/evaluation.json` as written?
