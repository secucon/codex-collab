#!/usr/bin/env bash
# test-status-summary.sh — Unit tests for codex-collab status summary generator
#
# Tests:
#   1. Config loading — verbosity, max_lines, auto_summary, summary_format
#   2. Config validation — invalid values fall back to defaults
#   3. Config hierarchy — env override, project override, global override
#   4. Command summary — minimal verbosity for all command types
#   5. Command summary — normal verbosity for all command types
#   6. Command summary — verbose with extra detail
#   7. Auto-summary disabled — no output when auto_summary=false
#   8. Max lines truncation
#   9. Detailed format wrapping (border lines)
#  10. Integration — config + summary generation end-to-end
#
# Usage:
#   bash tests/test-status-summary.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed

set -euo pipefail

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required to run status summary tests" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Test Framework
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
TOTAL=0
ERRORS=()

ok()   { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); echo "  ✓ $*"; }
fail() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); ERRORS+=("$*"); echo "  ✗ $*" >&2; }

assert_contains() {
  local label="$1" output="$2" expected="$3"
  if echo "$output" | grep -qF -- "$expected"; then
    ok "$label"
  else
    fail "$label — expected to contain: '$expected'"
  fi
}

assert_not_contains() {
  local label="$1" output="$2" unexpected="$3"
  if echo "$output" | grep -qF -- "$unexpected"; then
    fail "$label — should NOT contain: '$unexpected'"
  else
    ok "$label"
  fi
}

assert_line_count_le() {
  local label="$1" output="$2" max="$3"
  local count
  count="$(echo "$output" | wc -l | tr -d ' ')"
  if [[ "$count" -le "$max" ]]; then
    ok "$label (got $count lines, max $max)"
  else
    fail "$label — got $count lines, expected <= $max"
  fi
}

assert_empty() {
  local label="$1" output="$2"
  if [[ -z "$output" ]]; then
    ok "$label"
  else
    fail "$label — expected empty output, got: '$output'"
  fi
}

# ---------------------------------------------------------------------------
# Test Setup
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/status-summary.sh"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Create fake global and project config dirs for testing
GLOBAL_DIR="$TMPDIR_BASE/home/.claude"
PROJECT_DIR="$TMPDIR_BASE/project/.codex-collab"
mkdir -p "$GLOBAL_DIR" "$PROJECT_DIR"

GLOBAL_CONFIG="$GLOBAL_DIR/codex-collab-config.yaml"
PROJECT_CONFIG="$PROJECT_DIR/config.yaml"

echo "=== codex-collab status summary unit tests ==="
echo ""

# ---------------------------------------------------------------------------
# Test 1: Config defaults — verbosity=normal, max_lines=20, auto_summary=true
# ---------------------------------------------------------------------------
echo "[ 1/10 ] Config defaults"

# Source with no config files, env overrides cleared
(
  unset CODEX_STATUS_AUTO_SUMMARY CODEX_STATUS_FORMAT CODEX_STATUS_VERBOSITY CODEX_STATUS_MAX_LINES
  unset CODEX_CONFIG_LOADED
  # Source the script to get functions
  source "$SCRIPT"
  output="$(get_status_config)"

  echo "$output" | grep -q "auto_summary=true"     && echo "  ✓ default auto_summary=true" \
    || echo "  ✗ default auto_summary should be true" >&2
  echo "$output" | grep -q "summary_format=compact" && echo "  ✓ default summary_format=compact" \
    || echo "  ✗ default summary_format should be compact" >&2
  echo "$output" | grep -q "verbosity=normal"       && echo "  ✓ default verbosity=normal" \
    || echo "  ✗ default verbosity should be normal" >&2
  echo "$output" | grep -q "max_lines=20"           && echo "  ✓ default max_lines=20" \
    || echo "  ✗ default max_lines should be 20" >&2
)
RESULT=$?
if [[ $RESULT -eq 0 ]]; then
  ok "Config defaults verified"
else
  fail "Config defaults"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 2: Config validation — invalid values fall back to defaults
# ---------------------------------------------------------------------------
echo "[ 2/10 ] Config validation — invalid values"

(
  export CODEX_STATUS_VERBOSITY="invalid_level"
  export CODEX_STATUS_FORMAT="unknown_format"
  export CODEX_STATUS_MAX_LINES="999"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  output="$(get_status_config)"

  echo "$output" | grep -q "verbosity=normal"       && echo "  ✓ invalid verbosity falls back to normal" \
    || echo "  ✗ invalid verbosity should fall back to normal" >&2
  echo "$output" | grep -q "summary_format=compact"  && echo "  ✓ invalid format falls back to compact" \
    || echo "  ✗ invalid format should fall back to compact" >&2
  echo "$output" | grep -q "max_lines=20"            && echo "  ✓ out-of-range max_lines falls back to 20" \
    || echo "  ✗ out-of-range max_lines should fall back to 20" >&2
)
RESULT=$?
if [[ $RESULT -eq 0 ]]; then
  ok "Config validation: invalid values handled correctly"
else
  fail "Config validation"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 3: Config via environment variables
# ---------------------------------------------------------------------------
echo "[ 3/10 ] Config via environment variables"

(
  export CODEX_STATUS_AUTO_SUMMARY="false"
  export CODEX_STATUS_FORMAT="detailed"
  export CODEX_STATUS_VERBOSITY="verbose"
  export CODEX_STATUS_MAX_LINES="5"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  output="$(get_status_config)"

  echo "$output" | grep -q "auto_summary=false"      && echo "  ✓ env auto_summary=false" \
    || echo "  ✗ env auto_summary override failed" >&2
  echo "$output" | grep -q "summary_format=detailed"  && echo "  ✓ env summary_format=detailed" \
    || echo "  ✗ env summary_format override failed" >&2
  echo "$output" | grep -q "verbosity=verbose"        && echo "  ✓ env verbosity=verbose" \
    || echo "  ✗ env verbosity override failed" >&2
  echo "$output" | grep -q "max_lines=5"              && echo "  ✓ env max_lines=5" \
    || echo "  ✗ env max_lines override failed" >&2
)
RESULT=$?
if [[ $RESULT -eq 0 ]]; then
  ok "Config via environment variables"
else
  fail "Config via environment variables"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 4: Command summary — minimal verbosity
# ---------------------------------------------------------------------------
echo "[ 4/10 ] Command summary — minimal verbosity"

TEST4_PASS=0
TEST4_TOTAL=0

# Test debate minimal
output=$(
  export CODEX_STATUS_VERBOSITY="minimal"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true","rounds":3}'
)
TEST4_TOTAL=$((TEST4_TOTAL + 1))
if echo "$output" | grep -qF "Debate: consensus=true"; then
  ok "minimal debate: shows consensus"
  TEST4_PASS=$((TEST4_PASS + 1))
else
  fail "minimal debate: should show consensus"
fi

# Test evaluate minimal
output=$(
  export CODEX_STATUS_VERBOSITY="minimal"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-evaluate" '{"confidence":"0.85"}'
)
TEST4_TOTAL=$((TEST4_TOTAL + 1))
if echo "$output" | grep -qF "Evaluate: confidence=0.85"; then
  ok "minimal evaluate: shows confidence"
  TEST4_PASS=$((TEST4_PASS + 1))
else
  fail "minimal evaluate: should show confidence"
fi

# Test ask minimal
output=$(
  export CODEX_STATUS_VERBOSITY="minimal"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-ask" '{"mode":"write"}'
)
TEST4_TOTAL=$((TEST4_TOTAL + 1))
if echo "$output" | grep -qF "Ask: mode=write completed"; then
  ok "minimal ask: shows mode"
  TEST4_PASS=$((TEST4_PASS + 1))
else
  fail "minimal ask: should show mode"
fi

# Test unknown command minimal
output=$(
  export CODEX_STATUS_VERBOSITY="minimal"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "custom-cmd" '{}'
)
TEST4_TOTAL=$((TEST4_TOTAL + 1))
if echo "$output" | grep -qF "custom-cmd: completed"; then
  ok "minimal unknown cmd: shows completed"
  TEST4_PASS=$((TEST4_PASS + 1))
else
  fail "minimal unknown cmd: should show completed"
fi

# Minimal should be single line
TEST4_TOTAL=$((TEST4_TOTAL + 1))
line_count=$(echo "$output" | wc -l | tr -d ' ')
if [[ "$line_count" -eq 1 ]]; then
  ok "minimal output: single line"
  TEST4_PASS=$((TEST4_PASS + 1))
else
  fail "minimal output: expected 1 line, got $line_count"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 5: Command summary — normal verbosity
# ---------------------------------------------------------------------------
echo "[ 5/10 ] Command summary — normal verbosity"

# Test debate normal
output=$(
  export CODEX_STATUS_VERBOSITY="normal"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true","rounds":3,"topic":"refactoring approach"}' "sess-123"
)

assert_contains "normal debate: header"    "$output" "[codex-collab] Debate Summary"
assert_contains "normal debate: command"   "$output" "Command:   /codex-debate"
assert_contains "normal debate: topic"     "$output" "Topic:     refactoring approach"
assert_contains "normal debate: rounds"    "$output" "Rounds:    3"
assert_contains "normal debate: consensus" "$output" "Consensus: true"
assert_contains "normal debate: session"   "$output" "Session:   sess-123"

# Test evaluate normal
output=$(
  export CODEX_STATUS_VERBOSITY="normal"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-evaluate" '{"confidence":"0.92","issue_count":"2","target":"src/main.py"}' "sess-456"
)

assert_contains "normal evaluate: header"     "$output" "[codex-collab] Evaluation Summary"
assert_contains "normal evaluate: target"     "$output" "Target:     src/main.py"
assert_contains "normal evaluate: confidence" "$output" "Confidence: 0.92"
assert_contains "normal evaluate: issues"     "$output" "Issues:     2"

# Test ask normal
output=$(
  export CODEX_STATUS_VERBOSITY="normal"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-ask" '{"mode":"read-only","prompt_summary":"explain the auth flow"}'
)

assert_contains "normal ask: header" "$output" "[codex-collab] Ask Summary"
assert_contains "normal ask: mode"   "$output" "Mode:    read-only"
assert_contains "normal ask: prompt" "$output" "Prompt:  explain the auth flow"

echo ""

# ---------------------------------------------------------------------------
# Test 6: Command summary — verbose with extra detail
# ---------------------------------------------------------------------------
echo "[ 6/10 ] Command summary — verbose verbosity"

# Test debate verbose
output=$(
  export CODEX_STATUS_VERBOSITY="verbose"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true","rounds":3,"topic":"API design","auto_apply":"true","final_position":"Use REST over GraphQL"}' "sess-789"
)

assert_contains "verbose debate: header"    "$output" "[codex-collab] Debate Summary"
assert_contains "verbose debate: separator" "$output" "  ---"
assert_contains "verbose debate: auto_apply" "$output" "Auto-apply: true"
assert_contains "verbose debate: position"   "$output" "Position:   Use REST over GraphQL"
assert_contains "verbose debate: timestamp"  "$output" "Timestamp:"

# Test evaluate verbose
output=$(
  export CODEX_STATUS_VERBOSITY="verbose"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-evaluate" '{"confidence":"0.75","issue_count":"5","max_severity":"high","cross_verified":"true"}'
)

assert_contains "verbose evaluate: severity"     "$output" "Severity:       high"
assert_contains "verbose evaluate: cross-verify" "$output" "Cross-verified: true"

echo ""

# ---------------------------------------------------------------------------
# Test 7: Auto-summary disabled — no output
# ---------------------------------------------------------------------------
echo "[ 7/10 ] Auto-summary disabled"

output=$(
  export CODEX_STATUS_AUTO_SUMMARY="false"
  export CODEX_STATUS_VERBOSITY="normal"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true"}'
)

assert_empty "auto_summary=false produces no output" "$output"

echo ""

# ---------------------------------------------------------------------------
# Test 8: Max lines truncation
# ---------------------------------------------------------------------------
echo "[ 8/10 ] Max lines truncation"

# Generate verbose output (many lines) with max_lines=3
output=$(
  export CODEX_STATUS_VERBOSITY="verbose"
  export CODEX_STATUS_MAX_LINES="3"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true","rounds":3,"topic":"test topic","auto_apply":"true","final_position":"position text"}' "sess-trunc"
)

assert_line_count_le "max_lines=3 truncation" "$output" 3
assert_contains "truncation indicator" "$output" "more lines truncated"

# Test max_lines=2 — extreme truncation
output=$(
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_MAX_LINES="2"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true","rounds":3,"topic":"test"}' "sess-x"
)

assert_line_count_le "max_lines=2 extreme truncation" "$output" 2
assert_contains "extreme truncation has indicator" "$output" "truncated"

echo ""

# ---------------------------------------------------------------------------
# Test 9: Detailed format wrapping (border lines)
# ---------------------------------------------------------------------------
echo "[ 9/10 ] Detailed format wrapping"

output=$(
  export CODEX_STATUS_FORMAT="detailed"
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_MAX_LINES="50"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-evaluate" '{"confidence":"0.8","issue_count":"1"}'
)

# Detailed format should have border lines (─)
assert_contains "detailed format: has border" "$output" "──────"
# Should still contain the actual content
assert_contains "detailed format: has content" "$output" "Evaluation Summary"

echo ""

# ---------------------------------------------------------------------------
# Test 10: Integration — full config load + summary generation
# ---------------------------------------------------------------------------
echo "[ 10/10 ] Integration — config hierarchy + summary"

# Write global config with status settings
cat > "$GLOBAL_CONFIG" <<'YAML'
status:
  auto_summary: true
  summary_format: compact
  verbosity: verbose
  max_lines: 50
YAML

# Write project config overriding verbosity
cat > "$PROJECT_CONFIG" <<'YAML'
status:
  verbosity: minimal
  max_lines: 10
YAML

# Test that project verbosity overrides global
output=$(
  export CODEX_GLOBAL_CONFIG="$GLOBAL_CONFIG"
  export CODEX_PROJECT_ROOT="$TMPDIR_BASE/project"
  unset CODEX_CONFIG_LOADED
  unset CODEX_STATUS_VERBOSITY CODEX_STATUS_FORMAT CODEX_STATUS_MAX_LINES CODEX_STATUS_AUTO_SUMMARY
  source "$REPO_ROOT/scripts/load-config.sh"
  load_config "$TMPDIR_BASE/project"
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true","rounds":5}'
)

# With project override verbosity=minimal, should be a single concise line
assert_contains "integration: minimal output from project override" "$output" "Debate: consensus=true"
assert_not_contains "integration: no verbose detail in minimal" "$output" "Timestamp:"

# Test with auto_summary disabled via project config
cat > "$PROJECT_CONFIG" <<'YAML'
status:
  auto_summary: false
YAML

output=$(
  export CODEX_GLOBAL_CONFIG="$GLOBAL_CONFIG"
  export CODEX_PROJECT_ROOT="$TMPDIR_BASE/project"
  unset CODEX_CONFIG_LOADED
  unset CODEX_STATUS_VERBOSITY CODEX_STATUS_FORMAT CODEX_STATUS_MAX_LINES CODEX_STATUS_AUTO_SUMMARY
  source "$REPO_ROOT/scripts/load-config.sh"
  load_config "$TMPDIR_BASE/project"
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true"}'
)

assert_empty "integration: project auto_summary=false disables output" "$output"

# Test max_lines from config hierarchy
cat > "$PROJECT_CONFIG" <<'YAML'
status:
  verbosity: verbose
  max_lines: 4
YAML

output=$(
  export CODEX_GLOBAL_CONFIG="$GLOBAL_CONFIG"
  export CODEX_PROJECT_ROOT="$TMPDIR_BASE/project"
  unset CODEX_CONFIG_LOADED
  unset CODEX_STATUS_VERBOSITY CODEX_STATUS_FORMAT CODEX_STATUS_MAX_LINES CODEX_STATUS_AUTO_SUMMARY
  source "$REPO_ROOT/scripts/load-config.sh"
  load_config "$TMPDIR_BASE/project"
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true","rounds":3,"topic":"test","auto_apply":"false","final_position":"pos"}' "sess-int"
)

assert_line_count_le "integration: max_lines=4 from config" "$output" 4

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== Summary ==="
echo "Total : $TOTAL"
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo ""
  echo "Failures:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
fi

echo ""
if [[ $FAIL -gt 0 ]]; then
  echo "RESULT: FAIL ($FAIL test(s) failed)"
  exit 1
else
  echo "RESULT: PASS — all $PASS tests passed"
  exit 0
fi
