#!/usr/bin/env bash
# test-fake-codex.sh — Verify that fake-codex.sh returns correct JSONL
# fixtures for each supported scenario.
#
# Usage:
#   ./tests/test-fake-codex.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAKE_CODEX="$SCRIPT_DIR/fake-codex.sh"
TMP_OUTPUT=$(mktemp /tmp/fake-codex-test-XXXXXX.md)
TMP_JSONL=$(mktemp /tmp/fake-codex-test-XXXXXX.jsonl)

PASS=0
FAIL=0
ERRORS=()

ok()  { echo "  ✓ $*"; PASS=$((PASS + 1)); }
err() { echo "  ✗ $*" >&2; ERRORS+=("$*"); FAIL=$((FAIL + 1)); }

cleanup() {
  rm -f "$TMP_OUTPUT" "$TMP_JSONL"
}
trap cleanup EXIT

echo "=== fake-codex.sh scenario tests ==="
echo ""

# ── Helper: run fake codex with scenario ─────────────────────────────────

run_scenario() {
  local scenario="$1"
  shift
  : > "$TMP_OUTPUT"
  : > "$TMP_JSONL"
  FAKE_CODEX_SCENARIO="$scenario" "$FAKE_CODEX" "$@" > "$TMP_JSONL" 2>/dev/null
  return $?
}

run_scenario_stderr() {
  local scenario="$1"
  shift
  : > "$TMP_OUTPUT"
  FAKE_CODEX_SCENARIO="$scenario" "$FAKE_CODEX" "$@" 2>&1 >/dev/null
}

# ── Test 1: session-start emits JSONL with session_id ────────────────────

echo "[ 1/12 ] session-start scenario"

if run_scenario "session-start" exec -o "$TMP_OUTPUT" -C /tmp -s read-only --json "hello"; then
  ok "exit code 0"
else
  err "session-start: unexpected non-zero exit"
fi

if grep -q '"session_id"' "$TMP_JSONL"; then
  ok "JSONL contains session_id"
else
  err "session-start: JSONL missing session_id"
fi

if grep -q '"session.start"' "$TMP_JSONL"; then
  ok "JSONL contains session.start event"
else
  err "session-start: JSONL missing session.start event"
fi

if [[ -s "$TMP_OUTPUT" ]]; then
  ok "output file is non-empty"
else
  err "session-start: output file is empty"
fi

echo ""

# ── Test 2: session-resume produces output (no JSONL) ────────────────────

echo "[ 2/12 ] session-resume scenario"

if run_scenario "session-resume" exec resume fake-session-001 -o "$TMP_OUTPUT" -C /tmp "follow up"; then
  ok "exit code 0"
else
  err "session-resume: unexpected non-zero exit"
fi

if [[ -s "$TMP_OUTPUT" ]]; then
  ok "output file is non-empty"
else
  err "session-resume: output file is empty"
fi

echo ""

# ── Test 3: debate-round returns structured position JSON ────────────────

echo "[ 3/12 ] debate-round scenario"

if run_scenario "debate-round" exec -o "$TMP_OUTPUT" -C /tmp -s read-only --json --output-schema '{}' "debate prompt"; then
  ok "exit code 0"
else
  err "debate-round: unexpected non-zero exit"
fi

if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'position' in d; assert 'confidence' in d; assert 'key_arguments' in d; assert d['agrees_with_opponent'] == False" "$TMP_OUTPUT" 2>/dev/null; then
  ok "output contains valid debate position JSON (agrees_with_opponent=false)"
else
  err "debate-round: output is not valid debate position JSON"
fi

if grep -q '"session_id"' "$TMP_JSONL"; then
  ok "JSONL contains session_id"
else
  err "debate-round: JSONL missing session_id"
fi

echo ""

# ── Test 4: debate-consensus returns agrees_with_opponent=true ───────────

echo "[ 4/12 ] debate-consensus scenario"

if run_scenario "debate-consensus" exec -o "$TMP_OUTPUT" -C /tmp -s read-only --json --output-schema '{}' "debate prompt"; then
  ok "exit code 0"
else
  err "debate-consensus: unexpected non-zero exit"
fi

if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['agrees_with_opponent'] == True; assert d['confidence'] >= 0.8" "$TMP_OUTPUT" 2>/dev/null; then
  ok "output has agrees_with_opponent=true and high confidence"
else
  err "debate-consensus: output does not indicate consensus"
fi

echo ""

# ── Test 5: debate-multi-round has multiple round events ─────────────────

echo "[ 5/12 ] debate-multi-round scenario"

if run_scenario "debate-multi-round" exec -o "$TMP_OUTPUT" -C /tmp -s read-only --json --output-schema '{}' "debate prompt"; then
  ok "exit code 0"
else
  err "debate-multi-round: unexpected non-zero exit"
fi

ROUND_COUNT=$(grep -c '"type":"round"' "$TMP_JSONL" 2>/dev/null || echo "0")
if [[ "$ROUND_COUNT" -ge 3 ]]; then
  ok "JSONL contains $ROUND_COUNT round events (>= 3)"
else
  err "debate-multi-round: expected >= 3 round events, found $ROUND_COUNT"
fi

echo ""

# ── Test 6: evaluate returns structured findings ─────────────────────────

echo "[ 6/12 ] evaluate scenario"

if run_scenario "evaluate" exec -o "$TMP_OUTPUT" -C /tmp -s read-only --json --output-schema '{}' "evaluate code"; then
  ok "exit code 0"
else
  err "evaluate: unexpected non-zero exit"
fi

if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert len(d['issues']) == 3; assert any(i['severity']=='high' for i in d['issues'])" "$TMP_OUTPUT" 2>/dev/null; then
  ok "output contains 3 issues with correct severity levels"
else
  err "evaluate: output does not contain expected structured findings"
fi

echo ""

# ── Test 7: ask-readonly returns text output ─────────────────────────────

echo "[ 7/12 ] ask-readonly scenario"

if run_scenario "ask-readonly" exec -o "$TMP_OUTPUT" -C /tmp -s read-only --json "how does auth work"; then
  ok "exit code 0"
else
  err "ask-readonly: unexpected non-zero exit"
fi

if grep -q "JWT" "$TMP_OUTPUT"; then
  ok "output contains expected content (JWT reference)"
else
  err "ask-readonly: output missing expected content"
fi

echo ""

# ── Test 8: ask-write includes tool_use events ───────────────────────────

echo "[ 8/12 ] ask-write scenario"

if run_scenario "ask-write" exec -o "$TMP_OUTPUT" -C /tmp --full-auto --json "add validation"; then
  ok "exit code 0"
else
  err "ask-write: unexpected non-zero exit"
fi

if grep -q '"tool_use' "$TMP_JSONL"; then
  ok "JSONL contains tool_use events"
else
  err "ask-write: JSONL missing tool_use events"
fi

echo ""

# ── Test 9: error-auth returns exit code 2 with auth message ─────────────

echo "[ 9/12 ] error-auth scenario"

EXIT_CODE=0
STDERR=$(run_scenario_stderr "error-auth" exec -o "$TMP_OUTPUT" -C /tmp -s read-only "prompt") || EXIT_CODE=$?

if [[ $EXIT_CODE -eq 2 ]]; then
  ok "exit code is 2 (auth error)"
else
  err "error-auth: expected exit code 2, got $EXIT_CODE"
fi

if echo "$STDERR" | grep -qi "auth\|login"; then
  ok "stderr contains auth/login message"
else
  err "error-auth: stderr missing auth/login message"
fi

echo ""

# ── Test 10: error-empty produces empty output file ──────────────────────

echo "[ 10/12 ] error-empty scenario"

run_scenario "error-empty" exec -o "$TMP_OUTPUT" -C /tmp -s read-only --json "prompt" || true

if [[ -f "$TMP_OUTPUT" ]] && [[ ! -s "$TMP_OUTPUT" ]]; then
  ok "output file exists but is empty"
else
  err "error-empty: output file should be empty"
fi

echo ""

# ── Test 11: error-crash returns non-zero exit ───────────────────────────

echo "[ 11/12 ] error-crash scenario"

EXIT_CODE=0
STDERR=$(run_scenario_stderr "error-crash" exec -o "$TMP_OUTPUT" -C /tmp -s read-only "prompt") || EXIT_CODE=$?

if [[ $EXIT_CODE -ne 0 ]]; then
  ok "exit code is non-zero ($EXIT_CODE)"
else
  err "error-crash: expected non-zero exit code"
fi

if echo "$STDERR" | grep -qi "fatal\|error"; then
  ok "stderr contains error message"
else
  err "error-crash: stderr missing error message"
fi

echo ""

# ── Test 12: custom session ID via FAKE_CODEX_SESSION_ID ─────────────────

echo "[ 12/12 ] custom session ID override"

: > "$TMP_JSONL"
FAKE_CODEX_SCENARIO="session-start" FAKE_CODEX_SESSION_ID="custom-test-42" \
  "$FAKE_CODEX" exec -o "$TMP_OUTPUT" -C /tmp -s read-only --json "hello" > "$TMP_JSONL" 2>/dev/null

if grep -q '"custom-test-42"' "$TMP_JSONL"; then
  ok "JSONL contains custom session ID 'custom-test-42'"
else
  err "custom session ID: JSONL missing custom-test-42"
fi

echo ""

# ── Summary ──────────────────────────────────────────────────────────────

echo "=== Summary ==="
echo "Passed : $PASS"
echo "Failed : $FAIL"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo ""
  echo "Errors:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
fi

echo ""
if [[ $FAIL -gt 0 ]]; then
  echo "RESULT: FAIL ($FAIL check(s) failed)"
  exit 1
else
  echo "RESULT: PASS — all tests passed"
  exit 0
fi
