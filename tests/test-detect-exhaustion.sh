#!/usr/bin/env bash
# test-detect-exhaustion.sh — Tests for scripts/detect-exhaustion.sh
#
# Validates:
#   1. is_exhausted returns correct exit codes at boundary conditions
#   2. check_exhaustion returns well-formed JSON with correct fields
#   3. detect_round_exhaustion includes debate context
#   4. format_exhaustion_notice produces correct output markers
#   5. CLI mode (--check, --notice, json) works correctly
#   6. Edge cases: round 0, round == max, round > max, invalid input

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_PASSED=0
TESTS_FAILED=0

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------
pass() {
  TESTS_PASSED=$(( TESTS_PASSED + 1 ))
  echo "  ✅ $1"
}

fail() {
  TESTS_FAILED=$(( TESTS_FAILED + 1 ))
  echo "  ❌ $1"
  if [[ -n "${2:-}" ]]; then
    echo "     Detail: $2"
  fi
}

assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local desc="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc" "expected exit $expected, got $actual"
  fi
}

assert_json_field() {
  local json="$1"
  local field="$2"
  local expected="$3"
  local desc="$4"
  local actual
  actual=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('$field','MISSING'))" "$json" 2>/dev/null || echo "PARSE_ERROR")
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc" "field '$field': expected '$expected', got '$actual'"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local desc="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    pass "$desc"
  else
    fail "$desc" "output does not contain '$needle'"
  fi
}

# ---------------------------------------------------------------------------
# Setup: Create a minimal config environment
# ---------------------------------------------------------------------------
export CODEX_CONFIG_LOADED=1
# Mock config_get to return defaults
config_get() {
  local key="$1"
  local default="${2:-}"
  case "$key" in
    "debate.default_rounds") echo "3" ;;
    "debate.max_additional_rounds") echo "2" ;;
    *) echo "$default" ;;
  esac
}
export -f config_get

# Source the scripts under test (save/restore SCRIPT_DIR since each script resets it)
_TEST_ROOT="${SCRIPT_DIR}"
source "${_TEST_ROOT}/scripts/debate-round-cap.sh"
SCRIPT_DIR="${_TEST_ROOT}/scripts"
source "${_TEST_ROOT}/scripts/detect-exhaustion.sh"
SCRIPT_DIR="${_TEST_ROOT}/scripts"

echo "================================================"
echo " detect-exhaustion.sh — Test Suite"
echo "================================================"
echo ""

# ===========================================================================
# Group 1: is_exhausted boundary checks
# ===========================================================================
echo "── Group 1: is_exhausted boundary checks ──"

# effective_max = 3 + 2 = 5

is_exhausted 0 2>/dev/null && ec=0 || ec=$?
assert_exit_code "1" "$ec" "Round 0: not exhausted (exit 1)"

is_exhausted 3 2>/dev/null && ec=0 || ec=$?
assert_exit_code "1" "$ec" "Round 3 (default_rounds): not exhausted"

is_exhausted 4 2>/dev/null && ec=0 || ec=$?
assert_exit_code "1" "$ec" "Round 4 (one below max): not exhausted"

is_exhausted 5 2>/dev/null && ec=0 || ec=$?
assert_exit_code "0" "$ec" "Round 5 (== effective_max): exhausted"

is_exhausted 6 2>/dev/null && ec=0 || ec=$?
assert_exit_code "0" "$ec" "Round 6 (> effective_max): exhausted"

is_exhausted "abc" 2>/dev/null && ec=0 || ec=$?
assert_exit_code "2" "$ec" "Invalid input 'abc': returns error (exit 2)"

echo ""

# ===========================================================================
# Group 2: check_exhaustion JSON output
# ===========================================================================
echo "── Group 2: check_exhaustion JSON structure ──"

result=$(check_exhaustion 5 "false")
assert_json_field "$result" "exhausted" "True" "Round 5, no consensus: exhausted=True"
assert_json_field "$result" "current_round" "5" "current_round=5"
assert_json_field "$result" "effective_max_rounds" "5" "effective_max_rounds=5"
assert_json_field "$result" "rounds_remaining" "0" "rounds_remaining=0"
assert_json_field "$result" "next_action" "present_non_consensus_choices" "next_action=present_non_consensus_choices"
assert_json_field "$result" "consensus_reached" "False" "consensus_reached=False"

result2=$(check_exhaustion 5 "true")
assert_json_field "$result2" "exhausted" "True" "Round 5, consensus: exhausted=True"
assert_json_field "$result2" "next_action" "present_consensus" "Consensus at max: next_action=present_consensus"

result3=$(check_exhaustion 2 "true")
assert_json_field "$result3" "exhausted" "False" "Round 2, consensus: exhausted=False (early consensus)"
assert_json_field "$result3" "next_action" "present_consensus" "Early consensus: next_action=present_consensus"

result4=$(check_exhaustion 2 "false")
assert_json_field "$result4" "exhausted" "False" "Round 2, no consensus: exhausted=False"
assert_json_field "$result4" "next_action" "continue_round" "Mid-debate: next_action=continue_round"
assert_json_field "$result4" "rounds_remaining" "3" "Round 2: 3 rounds remaining"

echo ""

# ===========================================================================
# Group 3: check_exhaustion additional round tracking
# ===========================================================================
echo "── Group 3: Additional round tracking ──"

result5=$(check_exhaustion 4 "false")
assert_json_field "$result5" "additional_rounds_used" "1" "Round 4: 1 additional round used (4-3=1)"
assert_json_field "$result5" "additional_rounds_remaining" "1" "Round 4: 1 additional round remaining"

result6=$(check_exhaustion 5 "false")
assert_json_field "$result6" "additional_rounds_used" "2" "Round 5: 2 additional rounds used (5-3=2)"
assert_json_field "$result6" "additional_rounds_remaining" "0" "Round 5: 0 additional rounds remaining"

result7=$(check_exhaustion 1 "false")
assert_json_field "$result7" "additional_rounds_used" "0" "Round 1: 0 additional rounds used"
assert_json_field "$result7" "additional_rounds_remaining" "2" "Round 1: 2 additional rounds remaining"

echo ""

# ===========================================================================
# Group 4: detect_round_exhaustion with context
# ===========================================================================
echo "── Group 4: detect_round_exhaustion with debate context ──"

ctx_result=$(detect_round_exhaustion 5 "false" "REST vs GraphQL" "session-123" "[]") || true
assert_json_field "$ctx_result" "topic" "REST vs GraphQL" "Topic preserved in output"
assert_json_field "$ctx_result" "session_id" "session-123" "Session ID preserved"
assert_json_field "$ctx_result" "exhausted" "True" "Exhaustion detected with context"

# Test with rounds JSON
rounds_json='[{"codex":{"confidence":0.8},"claude":{"confidence":0.7}},{"codex":{"confidence":0.6},"claude":{"confidence":0.5}}]'
ctx_result2=$(detect_round_exhaustion 2 "false" "test" "s1" "$rounds_json") || true
assert_json_field "$ctx_result2" "total_rounds_completed" "2" "Rounds count from JSON"

echo ""

# ===========================================================================
# Group 5: detect_round_exhaustion exit codes
# ===========================================================================
echo "── Group 5: Exit code semantics ──"

detect_round_exhaustion 5 "false" "" "" "[]" >/dev/null 2>&1 && ec=0 || ec=$?
assert_exit_code "0" "$ec" "Exhausted (round 5): exit 0 (exit loop)"

detect_round_exhaustion 3 "true" "" "" "[]" >/dev/null 2>&1 && ec=0 || ec=$?
assert_exit_code "0" "$ec" "Consensus at round 3: exit 0 (exit loop)"

detect_round_exhaustion 2 "false" "" "" "[]" >/dev/null 2>&1 && ec=0 || ec=$?
assert_exit_code "1" "$ec" "Round 2, no consensus: exit 1 (continue loop)"

echo ""

# ===========================================================================
# Group 6: format_exhaustion_notice output markers
# ===========================================================================
echo "── Group 6: format_exhaustion_notice markers ──"

state_exhausted=$(check_exhaustion 5 "false")
notice=$(format_exhaustion_notice "$state_exhausted")
assert_contains "$notice" "EXHAUSTION_DETECTED=true" "Exhaustion notice: EXHAUSTION_DETECTED=true"
assert_contains "$notice" "EXHAUSTION_NEXT_ACTION=present_non_consensus_choices" "Exhaustion notice: correct next action"
assert_contains "$notice" "Maximum Debate Rounds Exhausted" "Exhaustion notice: header displayed"

state_consensus=$(check_exhaustion 5 "true")
notice2=$(format_exhaustion_notice "$state_consensus")
assert_contains "$notice2" "EXHAUSTION_CONSENSUS=true" "Consensus notice: EXHAUSTION_CONSENSUS=true"

state_early=$(check_exhaustion 2 "true")
notice3=$(format_exhaustion_notice "$state_early")
assert_contains "$notice3" "EXHAUSTION_DETECTED=false" "Early consensus: EXHAUSTION_DETECTED=false"
assert_contains "$notice3" "Early consensus reached" "Early consensus notice text"

state_continue=$(check_exhaustion 2 "false")
notice4=$(format_exhaustion_notice "$state_continue")
assert_contains "$notice4" "EXHAUSTION_DETECTED=false" "Continue: EXHAUSTION_DETECTED=false"
assert_contains "$notice4" "EXHAUSTION_NEXT_ACTION=continue_round" "Continue: next action is continue_round"

echo ""

# ===========================================================================
# Group 7: get_exhaustion_reason output
# ===========================================================================
echo "── Group 7: get_exhaustion_reason output ──"

reason=$(get_exhaustion_reason 5)
assert_contains "$reason" "Maximum rounds reached" "Round 5: contains 'Maximum rounds reached'"
assert_contains "$reason" "5/5" "Round 5: shows 5/5"

reason2=$(get_exhaustion_reason 2)
assert_contains "$reason2" "Not exhausted" "Round 2: contains 'Not exhausted'"
assert_contains "$reason2" "remaining" "Round 2: mentions remaining rounds"

echo ""

# ===========================================================================
# Group 8: CLI mode
# ===========================================================================
echo "── Group 8: CLI mode ──"

# CLI --check mode
cli_out=$("${_TEST_ROOT}/scripts/detect-exhaustion.sh" --round 5 --check 2>/dev/null) && cli_ec=0 || cli_ec=$?
assert_exit_code "0" "$cli_ec" "CLI --check round 5: exit 0 (exhausted)"
assert_contains "$cli_out" "Exhausted" "CLI --check round 5: output says Exhausted"

cli_out2=$("${_TEST_ROOT}/scripts/detect-exhaustion.sh" --round 2 --check 2>/dev/null) && cli_ec2=0 || cli_ec2=$?
assert_exit_code "1" "$cli_ec2" "CLI --check round 2: exit 1 (not exhausted)"
assert_contains "$cli_out2" "Not exhausted" "CLI --check round 2: output says Not exhausted"

# CLI JSON mode (default)
cli_json=$("${_TEST_ROOT}/scripts/detect-exhaustion.sh" --round 5 --consensus false 2>/dev/null) || true
assert_json_field "$cli_json" "exhausted" "True" "CLI JSON: exhausted=True"

# CLI --notice mode
cli_notice=$("${_TEST_ROOT}/scripts/detect-exhaustion.sh" --round 5 --consensus false --notice 2>/dev/null) || true
assert_contains "$cli_notice" "EXHAUSTION_DETECTED=true" "CLI --notice: marker present"

echo ""

# ===========================================================================
# Summary
# ===========================================================================
echo "================================================"
TOTAL=$(( TESTS_PASSED + TESTS_FAILED ))
echo " Results: ${TESTS_PASSED}/${TOTAL} passed, ${TESTS_FAILED} failed"
echo "================================================"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
  exit 1
fi
exit 0
