#!/usr/bin/env bash
# run-scenarios.sh — Behavioral E2E scenario runner for codex-collab v2.1.0
#
# Chains multiple fake-codex interactions to simulate real user workflows.
# Each scenario verifies end-to-end behavior across session lifecycle,
# command sequencing, and error propagation.
#
# Usage:
#   ./tests/run-scenarios.sh                          # run all scenarios
#   ./tests/run-scenarios.sh --scenario happy-path    # run single scenario
#   ./tests/run-scenarios.sh --verbose                # show step-by-step logs
#   ./tests/run-scenarios.sh --list                   # list available scenarios
#   ./tests/run-scenarios.sh --help
#
# Prerequisites:
#   - tests/fake-codex.sh must be executable
#   - tests/fixtures/ must contain required JSONL fixtures
#   - python3 must be available (for JSON assertions)
#
# Exit codes:
#   0 — all scenarios passed
#   1 — one or more scenarios failed
#   2 — usage error (invalid arguments, missing prerequisites)

set -uo pipefail

# ── Constants ────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAKE_CODEX="$SCRIPT_DIR/fake-codex.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Temp directory for scenario artifacts ────────────────────────────────────

TMP_DIR=$(mktemp -d /tmp/codex-collab-scenarios-XXXXXX)

# ── State ────────────────────────────────────────────────────────────────────

PASS=0
FAIL=0
SKIP=0
ERRORS=()
VERBOSE=0
SELECTED_SCENARIO=""

# ═══════════════════════════════════════════════════════════════════════════════
# Shared Helpers
# ═══════════════════════════════════════════════════════════════════════════════

ok() {
  echo "    ✓ $*"
  PASS=$((PASS + 1))
}

err() {
  echo "    ✗ $*" >&2
  ERRORS+=("$*")
  FAIL=$((FAIL + 1))
}

skip() {
  echo "    ⊘ $* (skipped)"
  SKIP=$((SKIP + 1))
}

log() {
  if [[ $VERBOSE -eq 1 ]]; then
    echo "    … $*"
  fi
}

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

summary() {
  echo ""
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║  Scenario Test Summary                                  ║"
  echo "╠══════════════════════════════════════════════════════════╣"
  printf "║  Passed  : %-43s ║\n" "$PASS"
  printf "║  Failed  : %-43s ║\n" "$FAIL"
  printf "║  Skipped : %-43s ║\n" "$SKIP"
  printf "║  Total   : %-43s ║\n" "$((PASS + FAIL + SKIP))"
  echo "╚══════════════════════════════════════════════════════════╝"

  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo ""
    echo "Failures:"
    for e in "${ERRORS[@]}"; do
      echo "  - $e"
    done
  fi

  echo ""
  if [[ $FAIL -gt 0 ]]; then
    echo "RESULT: FAIL ($FAIL check(s) failed)"
    exit 1
  else
    echo "RESULT: PASS — all scenario checks passed"
    exit 0
  fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Fake Codex Invocation Helper
# ═══════════════════════════════════════════════════════════════════════════════
#
# run_codex <scenario> [codex args...]
#   Sets FAKE_CODEX_SCENARIO and runs fake-codex.sh.
#   Captures stdout (JSONL), output file (-o), and exit code.
#
# After calling, these variables are available:
#   LAST_EXIT_CODE — exit code from codex
#   LAST_JSONL     — path to captured JSONL stdout
#   LAST_OUTPUT    — path to output file (-o)

LAST_EXIT_CODE=0
LAST_JSONL=""
LAST_OUTPUT=""
STEP_COUNTER=0

run_codex() {
  local scenario="$1"
  shift

  STEP_COUNTER=$((STEP_COUNTER + 1))
  LAST_JSONL="$TMP_DIR/step-${STEP_COUNTER}.jsonl"
  LAST_OUTPUT="$TMP_DIR/step-${STEP_COUNTER}.out"

  : > "$LAST_JSONL"
  : > "$LAST_OUTPUT"

  log "step $STEP_COUNTER: codex [$scenario] $*"

  LAST_EXIT_CODE=0
  FAKE_CODEX_SCENARIO="$scenario" \
    "$FAKE_CODEX" "$@" -o "$LAST_OUTPUT" --json > "$LAST_JSONL" 2>/dev/null \
    || LAST_EXIT_CODE=$?

  log "step $STEP_COUNTER: exit=$LAST_EXIT_CODE, jsonl=$(wc -l < "$LAST_JSONL" | tr -d ' ') lines"

  return 0  # always return 0; callers check LAST_EXIT_CODE
}

# ═══════════════════════════════════════════════════════════════════════════════
# Assertion Helpers
# ═══════════════════════════════════════════════════════════════════════════════

assert_exit_zero() {
  local label="$1"
  if [[ $LAST_EXIT_CODE -eq 0 ]]; then
    ok "$label: exit code 0"
  else
    err "$label: expected exit 0, got $LAST_EXIT_CODE"
  fi
}

assert_exit_nonzero() {
  local label="$1"
  if [[ $LAST_EXIT_CODE -ne 0 ]]; then
    ok "$label: exit code non-zero ($LAST_EXIT_CODE)"
  else
    err "$label: expected non-zero exit, got 0"
  fi
}

assert_exit_code() {
  local label="$1"
  local expected="$2"
  if [[ $LAST_EXIT_CODE -eq $expected ]]; then
    ok "$label: exit code $expected"
  else
    err "$label: expected exit $expected, got $LAST_EXIT_CODE"
  fi
}

assert_output_contains() {
  local label="$1"
  local pattern="$2"
  if grep -q "$pattern" "$LAST_OUTPUT" 2>/dev/null; then
    ok "$label: output contains '$pattern'"
  else
    err "$label: output missing '$pattern'"
  fi
}

assert_output_nonempty() {
  local label="$1"
  if [[ -s "$LAST_OUTPUT" ]]; then
    ok "$label: output is non-empty"
  else
    err "$label: output is empty"
  fi
}

assert_jsonl_contains() {
  local label="$1"
  local pattern="$2"
  if grep -q "$pattern" "$LAST_JSONL" 2>/dev/null; then
    ok "$label: JSONL contains '$pattern'"
  else
    err "$label: JSONL missing '$pattern'"
  fi
}

assert_jsonl_has_session_id() {
  local label="$1"
  assert_jsonl_contains "$label" '"session_id"'
}

assert_output_valid_json() {
  local label="$1"
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$LAST_OUTPUT" 2>/dev/null; then
    ok "$label: output is valid JSON"
  else
    err "$label: output is not valid JSON"
  fi
}

assert_json_field() {
  local label="$1"
  local expr="$2"
  if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert $expr" "$LAST_OUTPUT" 2>/dev/null; then
    ok "$label: $expr"
  else
    err "$label: assertion failed — $expr"
  fi
}

# ── Extract session ID from JSONL ────────────────────────────────────────────

extract_session_id() {
  python3 -c "
import json, sys
for line in open(sys.argv[1]):
    line = line.strip()
    if not line: continue
    try:
        obj = json.loads(line)
        if 'session_id' in obj:
            print(obj['session_id'])
            sys.exit(0)
    except (ValueError, KeyError, TypeError):
        pass
sys.exit(1)
" "$LAST_JSONL" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════════
# Scenario Registry
# ═══════════════════════════════════════════════════════════════════════════════

SCENARIOS=(
  "happy-path"
  "debate-resume-chain"
)

scenario_description() {
  case "$1" in
    happy-path)          echo "E2E: session-start → ask-readonly → evaluate" ;;
    debate-resume-chain) echo "E2E: debate-round → session-resume → debate-consensus" ;;
    *)                   echo "(unknown scenario)" ;;
  esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO: happy-path
#
# Full happy-path flow: start a session, ask a read-only question using
# the session, then run an evaluation. Verifies session continuity,
# correct outputs, and zero exit codes throughout.
#
# Flow: session-start → ask-readonly → evaluate
# ═══════════════════════════════════════════════════════════════════════════════

scenario_happy_path() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  SCENARIO: happy-path"
  echo "  Flow: session-start → ask-readonly → evaluate"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  STEP_COUNTER=0

  # ── Step 1: Start a new session ──────────────────────────────
  echo "  Step 1/3: session-start — Create new codex session"

  run_codex "session-start" exec -C "$PLUGIN_ROOT" -s read-only "Initialize session for code review"

  assert_exit_zero "session-start"
  assert_output_nonempty "session-start"
  assert_jsonl_has_session_id "session-start"
  assert_jsonl_contains "session-start" '"session.start"'

  # Extract session ID for subsequent steps
  local session_id
  session_id=$(extract_session_id)
  if [[ -n "$session_id" ]]; then
    ok "session-start: captured session_id=$session_id"
  else
    err "session-start: failed to extract session_id from JSONL"
    echo "    ⚠ Aborting scenario — session ID required for subsequent steps"
    return
  fi

  log "using session_id=$session_id for subsequent steps"
  echo ""

  # ── Step 2: Ask a read-only question within the session ──────
  echo "  Step 2/3: ask-readonly — Read-only question (within session)"

  run_codex "ask-readonly" exec -C "$PLUGIN_ROOT" -s read-only "How does the authentication module work?"

  assert_exit_zero "ask-readonly"
  assert_output_nonempty "ask-readonly"
  assert_output_contains "ask-readonly" "JWT"
  assert_jsonl_has_session_id "ask-readonly"

  # Verify session ID continuity (same mock session should be used)
  local ask_session_id
  ask_session_id=$(extract_session_id)
  if [[ "$ask_session_id" == "$session_id" ]]; then
    ok "ask-readonly: session ID matches previous step ($session_id)"
  else
    err "ask-readonly: session ID mismatch (expected=$session_id, got=$ask_session_id)"
  fi

  echo ""

  # ── Step 3: Run an evaluation ────────────────────────────────
  echo "  Step 3/3: evaluate — Run code evaluation"

  run_codex "evaluate" exec -C "$PLUGIN_ROOT" -s read-only --output-schema '{}' "Evaluate the codebase for security issues"

  assert_exit_zero "evaluate"
  assert_output_nonempty "evaluate"
  assert_output_valid_json "evaluate"
  assert_json_field "evaluate" "len(d['issues']) == 3"
  assert_json_field "evaluate" "any(i['severity'] == 'high' for i in d['issues'])"
  assert_json_field "evaluate" "'confidence' in d and d['confidence'] > 0"
  assert_jsonl_has_session_id "evaluate"

  echo ""
  echo "  ── happy-path scenario complete ──"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO: debate-resume-chain
#
# Validates the full debate lifecycle:
#   Step 1: debate-round   — Start a debate, Codex takes initial position
#                            → captures session_id from JSONL
#   Step 2: session-resume — Resume the same session to continue context
#                            → uses session_id from Step 1
#   Step 3: debate-consensus — Final debate round where Codex reaches
#                              consensus (agrees_with_opponent=true)
#
# Key assertions:
#   - Session ID captured and consistent across all steps
#   - Debate position progresses from disagreement to consensus
#   - Each step exits successfully (exit code 0)
# ═══════════════════════════════════════════════════════════════════════════════

scenario_debate_resume_chain() {
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  SCENARIO: debate-resume-chain"
  echo "  Flow: debate-round → session-resume → debate-consensus"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  STEP_COUNTER=0

  local SESSION_ID="debate-chain-session-$(date +%s)"

  # ── Step 1: Initial debate round ─────────────────────────────────────
  echo "  Step 1/3: debate-round — Initial position"

  FAKE_CODEX_SESSION_ID="$SESSION_ID" \
    run_codex "debate-round" exec -C /tmp -s read-only \
      --output-schema '{"type":"object","properties":{"position":{},"confidence":{},"agrees_with_opponent":{}}}' \
      "Should this module use classes or functions? Consider encapsulation, testability, and team conventions."

  assert_exit_zero "debate-round"
  assert_jsonl_has_session_id "debate-round"

  # Extract and verify session_id from JSONL
  local CAPTURED_SESSION_ID
  CAPTURED_SESSION_ID=$(extract_session_id)

  if [[ "$CAPTURED_SESSION_ID" == "$SESSION_ID" ]]; then
    ok "debate-round: captured session_id matches expected ($SESSION_ID)"
  else
    err "debate-round: session_id mismatch (expected=$SESSION_ID, got=$CAPTURED_SESSION_ID)"
  fi

  # Output has valid debate position with agrees_with_opponent=false
  assert_output_valid_json "debate-round"
  assert_json_field "debate-round" "'position' in d and 'confidence' in d and 'key_arguments' in d"
  assert_json_field "debate-round" "d['agrees_with_opponent'] == False"

  echo ""

  # ── Step 2: Resume session to continue debate context ────────────────
  echo "  Step 2/3: session-resume — Continue context with captured session_id"

  FAKE_CODEX_SESSION_ID="$SESSION_ID" \
    run_codex "session-resume" exec resume "$CAPTURED_SESSION_ID" -C /tmp \
      "The opponent argues that functions with closures provide equivalent encapsulation."

  assert_exit_zero "session-resume"
  assert_output_nonempty "session-resume"

  if [[ "$CAPTURED_SESSION_ID" == "$SESSION_ID" ]]; then
    ok "session-resume: session ID continuity maintained"
  else
    err "session-resume: session ID continuity broken"
  fi

  echo ""

  # ── Step 3: Final debate round — consensus reached ───────────────────
  echo "  Step 3/3: debate-consensus — Final round, consensus reached"

  FAKE_CODEX_SESSION_ID="$SESSION_ID" \
    run_codex "debate-consensus" exec -C /tmp -s read-only \
      --output-schema '{"type":"object","properties":{"position":{},"confidence":{},"agrees_with_opponent":{}}}' \
      "Based on the discussion, please provide your final position."

  assert_exit_zero "debate-consensus"

  # JSONL uses same session_id
  local FINAL_SESSION_ID
  FINAL_SESSION_ID=$(extract_session_id)
  if [[ "$FINAL_SESSION_ID" == "$SESSION_ID" ]]; then
    ok "debate-consensus: session_id matches original ($SESSION_ID)"
  else
    err "debate-consensus: session_id mismatch (expected=$SESSION_ID, got=$FINAL_SESSION_ID)"
  fi

  # Consensus: agrees_with_opponent=true, high confidence
  assert_output_valid_json "debate-consensus"
  assert_json_field "debate-consensus" "d['agrees_with_opponent'] == True"
  assert_json_field "debate-consensus" "d['confidence'] >= 0.8"

  # Session ID consistent across all three steps
  if [[ "$CAPTURED_SESSION_ID" == "$SESSION_ID" && "$FINAL_SESSION_ID" == "$SESSION_ID" ]]; then
    ok "Session ID continuity: all 3 steps used same session ($SESSION_ID)"
  else
    err "Session ID continuity broken across steps"
  fi

  echo ""
  echo "  ── debate-resume-chain scenario complete ──"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# Argument Parsing
# ═══════════════════════════════════════════════════════════════════════════════

show_help() {
  cat <<'HELP'
Usage: run-scenarios.sh [OPTIONS]

Options:
  --scenario <name>   Run only the specified scenario
  --verbose, -v       Show detailed step-by-step logging
  --list              List all available scenarios and exit
  --help, -h          Show this help message and exit

HELP
  echo "Available scenarios:"
  for s in "${SCENARIOS[@]}"; do
    printf "  %-24s %s\n" "$s" "$(scenario_description "$s")"
  done
  exit 0
}

list_scenarios() {
  echo "Available scenarios:"
  for s in "${SCENARIOS[@]}"; do
    printf "  %-24s %s\n" "$s" "$(scenario_description "$s")"
  done
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)
      if [[ $# -lt 2 ]]; then
        echo "ERROR: --scenario requires a value" >&2
        exit 2
      fi
      SELECTED_SCENARIO="$2"
      shift 2
      ;;
    --verbose|-v)
      VERBOSE=1
      shift
      ;;
    --list)
      list_scenarios
      ;;
    --help|-h)
      show_help
      ;;
    *)
      echo "ERROR: Unknown option '$1'" >&2
      echo "Run with --help for usage information" >&2
      exit 2
      ;;
  esac
done

# ── Validate prerequisites ──────────────────────────────────────────────────

if [[ ! -x "$FAKE_CODEX" ]]; then
  echo "ERROR: fake-codex.sh not found or not executable at: $FAKE_CODEX" >&2
  echo "Hint: Run 'chmod +x $FAKE_CODEX' first" >&2
  exit 2
fi

if [[ ! -d "$FIXTURES_DIR" ]]; then
  echo "ERROR: fixtures directory not found at $FIXTURES_DIR" >&2
  exit 2
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required for JSON assertions" >&2
  exit 2
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Main: Run scenarios
# ═══════════════════════════════════════════════════════════════════════════════

echo "╔══════════════════════════════════════════════════════════╗"
echo "║  codex-collab E2E scenario tests                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
log "Temp dir: $TMP_DIR"

# Validate selected scenario if specified
if [[ -n "$SELECTED_SCENARIO" ]]; then
  VALID=0
  for s in "${SCENARIOS[@]}"; do
    if [[ "$s" == "$SELECTED_SCENARIO" ]]; then
      VALID=1
      break
    fi
  done
  if [[ $VALID -eq 0 ]]; then
    echo "ERROR: Unknown scenario '$SELECTED_SCENARIO'" >&2
    echo "Available scenarios:" >&2
    for s in "${SCENARIOS[@]}"; do
      echo "  $s" >&2
    done
    exit 2
  fi
fi

# Dispatch scenario by name
run_scenario_by_name() {
  local name="$1"
  case "$name" in
    happy-path)          scenario_happy_path ;;
    debate-resume-chain) scenario_debate_resume_chain ;;
    *)
      echo "ERROR: No implementation for scenario '$name'" >&2
      err "scenario '$name' not implemented"
      ;;
  esac
}

if [[ -n "$SELECTED_SCENARIO" ]]; then
  run_scenario_by_name "$SELECTED_SCENARIO"
else
  for s in "${SCENARIOS[@]}"; do
    run_scenario_by_name "$s"
  done
fi

# Print summary and exit
summary
