# Manual check: Codex structured-output STRICT mode accepts our schemas

This is the second real-Codex manual check (companion to
[`resume-check.md`](./resume-check.md)). It verifies that the JSON schemas we
hand to Codex via `--schema` are actually accepted by Codex/OpenAI
**structured-output STRICT mode**, and that Codex returns valid structured JSON
against them. It requires a real `codex` install + auth and is **not** part of
the automated `npm test` suite.

Requires: `codex` installed and `codex login` completed.
Run all commands **from the repository root**.

## Why this check exists

A review of the task-5 schemas flagged three things that STRICT mode may reject
in `schemas/position.json` and `schemas/evaluation.json` as written:

1. A non-standard top-level **`version`** keyword.
2. **Optional properties not listed in `required`** while the enclosing object
   sets `additionalProperties: false` — STRICT mode requires every property key
   to appear in `required`. Today `proposed_change` (position) and
   `location` (evaluation `findings[]`) are optional.
3. **`minimum` / `maximum`** on `confidence` (evaluation) — numeric range
   keywords STRICT mode does not support.

These are unverified because no real `codex` exists in the build environment.
This procedure records how to verify them and exactly what to change if they
fail.

## Check A — `schemas/position.json`

1. Write a trivial prompt that asks for a position JSON:
   ```bash
   cat > /tmp/pos-prompt.txt <<'EOF'
   Return a position for a debate on the claim "the sky is blue".
   Set stance to a one-line claim, reasoning to one sentence, key_points to one
   or two short strings, and agrees_with_opponent to false.
   EOF
   ```

2. Ask Codex for structured output against the schema:
   ```bash
   node scripts/codex-client.mjs turn --sandbox read-only \
     --schema schemas/position.json --prompt-file /tmp/pos-prompt.txt \
     --out /tmp/pos.json
   echo "exit=$?"
   ```

3. Interpret the result:
   ```bash
   # PASS requires: command exited 0 AND .structured is a non-null object
   # carrying the required keys.
   node -e '
     const r = require("/tmp/pos.json");
     const s = r.structured;
     const ok = s && typeof s === "object" &&
       ["stance","reasoning","key_points","agrees_with_opponent"].every(k => k in s);
     console.log(ok ? "PASS" : "FAIL", JSON.stringify(s));
     process.exit(ok ? 0 : 1);
   '
   ```

   - **PASS** — the `turn` command exits 0 and the validator above prints `PASS`
     (Codex accepted the schema and returned valid structured JSON).
     → No change needed; `schemas/position.json` stands as-is.
   - **FAIL** — either the `turn` command exits non-zero (Codex rejected the
     schema; the stderr error typically mentions the schema / structured output /
     `additionalProperties` / `required` / an unsupported keyword, and
     `/tmp/pos.json` is not written), **or** it exits 0 but `.structured` is
     `null` / missing keys (Codex did not honor the schema).
     → Apply the schema-transform fallback below.

## Check B — `schemas/evaluation.json`

1. Write a trivial prompt that asks for an evaluation JSON:
   ```bash
   cat > /tmp/eval-prompt.txt <<'EOF'
   Return an evaluation of a trivial one-line code snippet.
   Set summary to one sentence, findings to a short list where each item has a
   severity (one of info, low, medium, high, critical) and a description, and
   confidence to a number between 0 and 1.
   EOF
   ```

2. Ask Codex for structured output against the schema:
   ```bash
   node scripts/codex-client.mjs turn --sandbox read-only \
     --schema schemas/evaluation.json --prompt-file /tmp/eval-prompt.txt \
     --out /tmp/eval.json
   echo "exit=$?"
   ```

3. Interpret the result:
   ```bash
   node -e '
     const r = require("/tmp/eval.json");
     const s = r.structured;
     const ok = s && typeof s === "object" &&
       ["summary","findings","confidence"].every(k => k in s);
     console.log(ok ? "PASS" : "FAIL", JSON.stringify(s));
     process.exit(ok ? 0 : 1);
   '
   ```

   - **PASS** — exits 0 and validator prints `PASS`. → No change needed.
   - **FAIL** — non-zero exit or `.structured` null / missing keys. → Apply the
     schema-transform fallback below.

## If either check FAILS: the schema-transform fallback

Do **not** hand-edit `schemas/*.json` into a STRICT-only shape — the schemas
double as human-readable contracts and are asserted by `tests/schemas.test.mjs`
(which checks for the `version` key and the current `required` sets). Instead,
add a **normalizer step in `scripts/codex-client.mjs`** that transforms the
loaded schema *in memory* before it is passed to Codex, leaving the on-disk
files untouched.

In `cmdTurn`, between reading `opts.schema` and calling `client.runTurn(...)`,
run the parsed `outputSchema` through a `strictifySchema()` helper that walks the
schema recursively and:

1. **Drops the top-level `version`** keyword (and any other non-JSON-Schema
   keyword STRICT mode does not recognize).
2. For every object node that has `additionalProperties: false`, **lists every
   property in `required`**, and makes any property that was previously optional
   **nullable** by turning its `type` into a union that includes `"null"`
   (e.g. `"string"` → `["string","null"]`, `["object","null"]` stays as-is).
   Apply recursively to nested objects (`proposed_change` in position;
   `findings[].items` in evaluation).
3. **Strips `minimum` / `maximum`** (and other unsupported numeric-range
   keywords) wherever they appear — e.g. on `confidence`.

Concretely, the normalized (in-memory) shapes become:

- **position**: no `version`; `required` = all five properties including
  `proposed_change`; inside `proposed_change`, `additionalProperties: false`
  with `summary` and `files` both required (and nullable if the model may omit
  them).
- **evaluation**: no `version`; `findings[]` items require `severity`,
  `description`, **and** `location` (with `location` typed `["string","null"]`);
  `confidence` keeps `type: number` but drops `minimum`/`maximum`.

This is still fully stateless and touches only `scripts/codex-client.mjs`; the
schema files, the schema tests, and the app-server client are unchanged. Record
the outcome (and that the normalizer is now in effect) in `CHANGELOG.md`.
