#!/usr/bin/env bash
# test-summary-format-and-save.sh — Tests for console output formatting and
# file auto-save functionality of status summary reports
#
# Tests:
#   1. Console formatting — status icons (✓, ✗, △) in emit_post_command_summary
#   2. Console formatting — compact vs detailed border rendering
#   3. Console formatting — field alignment across commands (debate/evaluate/ask)
#   4. Console formatting — [codex-collab] prefix on all output lines
#   5. File auto-save — report saved to .codex-collab/reports/ with correct filename
#   6. File auto-save — report content matches console output
#   7. File auto-save — report metadata header contains command, timestamp, project
#   8. File auto-save — auto_save=false skips file creation
#   9. File auto-save — save_report public API works correctly
#  10. File auto-save — reports directory auto-created when missing
#  11. Console formatting — minimal single-line output for all commands
#  12. File auto-save — filename sanitization for special characters
#
# Usage:
#   bash tests/test-summary-format-and-save.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed

set -euo pipefail

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required to run these tests" >&2
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

assert_line_count_eq() {
  local label="$1" output="$2" expected="$3"
  local count
  count="$(echo "$output" | wc -l | tr -d ' ')"
  if [[ "$count" -eq "$expected" ]]; then
    ok "$label (got $count lines)"
  else
    fail "$label — got $count lines, expected $expected"
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

assert_file_exists() {
  local label="$1" filepath="$2"
  if [[ -f "$filepath" ]]; then
    ok "$label"
  else
    fail "$label — file not found: $filepath"
  fi
}

assert_file_not_exists() {
  local label="$1" pattern="$2"
  local matches
  matches="$(ls $pattern 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$matches" -eq 0 ]]; then
    ok "$label"
  else
    fail "$label — found $matches file(s) matching: $pattern"
  fi
}

assert_file_contains() {
  local label="$1" filepath="$2" expected="$3"
  if [[ -f "$filepath" ]] && grep -qF -- "$expected" "$filepath"; then
    ok "$label"
  else
    fail "$label — file '$filepath' does not contain: '$expected'"
  fi
}

assert_regex() {
  local label="$1" output="$2" pattern="$3"
  if echo "$output" | grep -qE -- "$pattern"; then
    ok "$label"
  else
    fail "$label — output did not match regex: '$pattern'"
  fi
}

# ---------------------------------------------------------------------------
# Test Setup
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/status-summary.sh"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Create fake project root with .codex-collab dir
FAKE_PROJECT="$TMPDIR_BASE/project"
mkdir -p "$FAKE_PROJECT/.codex-collab"

echo "=== codex-collab summary format & auto-save tests ==="
echo ""

# ===========================================================================
# SECTION 1: Console Output Formatting Tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Test 1: Status icons in emit_post_command_summary
# ---------------------------------------------------------------------------
echo "[ 1/12 ] Console formatting — status icons"

# Success icon (✓)
output=$(
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_FORMAT="compact"
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_AUTO_SAVE="false"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  emit_post_command_summary "codex-ask" "success" "read-only" "" "$FAKE_PROJECT" 2>/dev/null
)
assert_contains "success icon ✓" "$output" "✓ Codex Ask"

# Error icon (✗)
output=$(
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_FORMAT="compact"
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_AUTO_SAVE="false"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  emit_post_command_summary "codex-evaluate" "error" "" "" "$FAKE_PROJECT" 2>/dev/null
)
assert_contains "error icon ✗" "$output" "✗ Codex Evaluate"
assert_contains "error shows failed" "$output" "failed"

# Partial icon (△)
output=$(
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_FORMAT="compact"
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_AUTO_SAVE="false"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  emit_post_command_summary "codex-debate" "partial" "" "2 round(s)" "$FAKE_PROJECT" 2>/dev/null
)
assert_contains "partial icon △" "$output" "△ Codex Debate"
assert_contains "partial shows partially completed" "$output" "partially completed"

echo ""

# ---------------------------------------------------------------------------
# Test 2: Compact vs detailed border rendering
# ---------------------------------------------------------------------------
echo "[ 2/12 ] Console formatting — compact vs detailed borders"

# Compact mode should NOT have top/bottom borders
output=$(
  export CODEX_STATUS_FORMAT="compact"
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_AUTO_SAVE="false"
  export CODEX_STATUS_MAX_LINES="50"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true","rounds":2,"topic":"test"}' "sess-001"
)
# First line of compact should be the header, not a border
assert_contains "compact has header" "$output" "[codex-collab] Debate Summary"
first_line="$(echo "$output" | head -n1)"
assert_not_contains "compact first line is NOT border" "$first_line" "──────"

# Detailed mode should wrap with border lines
output=$(
  export CODEX_STATUS_FORMAT="detailed"
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_AUTO_SAVE="false"
  export CODEX_STATUS_MAX_LINES="50"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true","rounds":2,"topic":"test"}' "sess-001"
)
first_line="$(echo "$output" | head -n1)"
last_line="$(echo "$output" | tail -n1)"
assert_contains "detailed first line is border" "$first_line" "──────"
assert_contains "detailed last line is border" "$last_line" "──────"
assert_contains "detailed still has content" "$output" "Debate Summary"

echo ""

# ---------------------------------------------------------------------------
# Test 3: Field alignment across commands
# ---------------------------------------------------------------------------
echo "[ 3/12 ] Console formatting — field alignment"

# Debate fields
output=$(
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_FORMAT="compact"
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_AUTO_SAVE="false"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"false","rounds":4,"topic":"Architecture decision"}' "sess-align"
)
assert_contains "debate: Command field" "$output" "  Command:   /codex-debate"
assert_contains "debate: Topic field" "$output" "  Topic:     Architecture decision"
assert_contains "debate: Rounds field" "$output" "  Rounds:    4"
assert_contains "debate: Consensus field" "$output" "  Consensus: false"
assert_contains "debate: Session field" "$output" "  Session:   sess-align"

# Evaluate fields
output=$(
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_FORMAT="compact"
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_AUTO_SAVE="false"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-evaluate" '{"confidence":"0.9","issue_count":"3","target":"src/api.ts"}' "sess-eval"
)
assert_contains "evaluate: Command field" "$output" "  Command:    /codex-evaluate"
assert_contains "evaluate: Target field" "$output" "  Target:     src/api.ts"
assert_contains "evaluate: Confidence field" "$output" "  Confidence: 0.9"
assert_contains "evaluate: Issues field" "$output" "  Issues:     3"

# Ask fields
output=$(
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_FORMAT="compact"
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_AUTO_SAVE="false"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-ask" '{"mode":"write","prompt_summary":"refactor utils"}'
)
assert_contains "ask: Command field" "$output" "  Command: /codex-ask"
assert_contains "ask: Mode field" "$output" "  Mode:    write"
assert_contains "ask: Prompt field" "$output" "  Prompt:  refactor utils"

echo ""

# ---------------------------------------------------------------------------
# Test 4: [codex-collab] prefix on all summary headers
# ---------------------------------------------------------------------------
echo "[ 4/12 ] Console formatting — [codex-collab] prefix"

for cmd in codex-debate codex-evaluate codex-ask; do
  output=$(
    export CODEX_STATUS_VERBOSITY="normal"
    export CODEX_STATUS_FORMAT="compact"
    export CODEX_STATUS_AUTO_SUMMARY="true"
    export CODEX_STATUS_AUTO_SAVE="false"
    unset CODEX_CONFIG_LOADED
    source "$SCRIPT"
    generate_command_summary "$cmd" '{}' ""
  )
  assert_contains "$cmd: header has [codex-collab] prefix" "$output" "[codex-collab]"
done

# Minimal verbosity also has prefix
for cmd in codex-debate codex-evaluate codex-ask custom-cmd; do
  output=$(
    export CODEX_STATUS_VERBOSITY="minimal"
    export CODEX_STATUS_FORMAT="compact"
    export CODEX_STATUS_AUTO_SUMMARY="true"
    export CODEX_STATUS_AUTO_SAVE="false"
    unset CODEX_CONFIG_LOADED
    source "$SCRIPT"
    generate_command_summary "$cmd" '{}' ""
  )
  assert_contains "minimal $cmd: has [codex-collab] prefix" "$output" "[codex-collab]"
done

# emit_post_command_summary has prefix
output=$(
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_AUTO_SAVE="false"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  emit_post_command_summary "codex-debate" "success" "" "3 round(s), consensus reached" "$FAKE_PROJECT" 2>/dev/null
)
assert_contains "emit: completion line has [codex-collab] prefix" "$output" "[codex-collab] ✓ Codex Debate"

echo ""

# ---------------------------------------------------------------------------
# Test 5: File auto-save — report saved with correct filename pattern
# ---------------------------------------------------------------------------
echo "[ 5/12 ] File auto-save — report creation and filename"

SAVE_PROJECT="$TMPDIR_BASE/save-test-1"
mkdir -p "$SAVE_PROJECT/.codex-collab"

output=$(
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_FORMAT="compact"
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_AUTO_SAVE="true"
  export CODEX_PROJECT_ROOT="$SAVE_PROJECT"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true","rounds":2}' "sess-save" 2>/dev/null
)

# Check that at least one .txt report file was created
report_count=$(ls "$SAVE_PROJECT/.codex-collab/reports/"*.txt 2>/dev/null | wc -l | tr -d ' ')
if [[ "$report_count" -ge 1 ]]; then
  ok "report file created in .codex-collab/reports/"
else
  fail "no report file found in $SAVE_PROJECT/.codex-collab/reports/"
fi

# Check filename pattern: codex-debate-YYYYMMDD-HHMMSS.txt
report_file=$(ls "$SAVE_PROJECT/.codex-collab/reports/"*.txt 2>/dev/null | head -n1)
if [[ -n "$report_file" ]]; then
  basename_report=$(basename "$report_file")
  assert_regex "filename starts with codex-debate" "$basename_report" "^codex-debate-[0-9]{8}-[0-9]{6}\.txt$"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 6: File auto-save — report content matches console output
# ---------------------------------------------------------------------------
echo "[ 6/12 ] File auto-save — content matches console output"

SAVE_PROJECT2="$TMPDIR_BASE/save-test-2"
mkdir -p "$SAVE_PROJECT2/.codex-collab"

console_output=$(
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_FORMAT="compact"
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_AUTO_SAVE="true"
  export CODEX_PROJECT_ROOT="$SAVE_PROJECT2"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-evaluate" '{"confidence":"0.88","issue_count":"1","target":"utils.py"}' "" 2>/dev/null
)

report_file=$(ls "$SAVE_PROJECT2/.codex-collab/reports/"*.txt 2>/dev/null | head -n1)
if [[ -n "$report_file" ]]; then
  # The report should contain the same summary content (after the metadata header)
  assert_file_contains "report has header content" "$report_file" "Evaluation Summary"
  assert_file_contains "report has confidence" "$report_file" "Confidence: 0.88"
  assert_file_contains "report has issues" "$report_file" "Issues:     1"
  assert_file_contains "report has target" "$report_file" "Target:     utils.py"

  # Console output should also have these
  assert_contains "console has same header" "$console_output" "Evaluation Summary"
  assert_contains "console has same confidence" "$console_output" "Confidence: 0.88"
else
  fail "report file not created for content comparison"
  fail "skipping content match tests"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 7: File auto-save — metadata header
# ---------------------------------------------------------------------------
echo "[ 7/12 ] File auto-save — metadata header"

SAVE_PROJECT3="$TMPDIR_BASE/save-test-3"
mkdir -p "$SAVE_PROJECT3/.codex-collab"

$(
  export CODEX_STATUS_VERBOSITY="verbose"
  export CODEX_STATUS_FORMAT="compact"
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_AUTO_SAVE="true"
  export CODEX_PROJECT_ROOT="$SAVE_PROJECT3"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-ask" '{"mode":"write","prompt_summary":"fix bug in auth"}' "" >/dev/null 2>/dev/null
)

report_file=$(ls "$SAVE_PROJECT3/.codex-collab/reports/"*.txt 2>/dev/null | head -n1)
if [[ -n "$report_file" ]]; then
  assert_file_contains "metadata: has report header marker" "$report_file" "# codex-collab Summary Report"
  assert_file_contains "metadata: has command name" "$report_file" "# Command:   codex-ask"
  assert_file_contains "metadata: has generated timestamp" "$report_file" "# Generated:"
  assert_file_contains "metadata: has project path" "$report_file" "# Project:   $SAVE_PROJECT3"
  assert_file_contains "metadata: has result JSON" "$report_file" "mode"
else
  fail "report file not created for metadata test"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 8: File auto-save — auto_save=false skips file creation
# ---------------------------------------------------------------------------
echo "[ 8/12 ] File auto-save — disabled when auto_save=false"

SAVE_PROJECT4="$TMPDIR_BASE/save-test-4"
mkdir -p "$SAVE_PROJECT4/.codex-collab"

$(
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_STATUS_FORMAT="compact"
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_AUTO_SAVE="false"
  export CODEX_PROJECT_ROOT="$SAVE_PROJECT4"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true"}' "" >/dev/null 2>/dev/null
)

# No reports directory or files should be created
if [[ -d "$SAVE_PROJECT4/.codex-collab/reports" ]]; then
  report_count=$(ls "$SAVE_PROJECT4/.codex-collab/reports/"*.txt 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$report_count" -eq 0 ]]; then
    ok "auto_save=false: no report files created"
  else
    fail "auto_save=false: found $report_count report file(s) — should be 0"
  fi
else
  ok "auto_save=false: reports directory not created"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 9: File auto-save — save_report public API
# ---------------------------------------------------------------------------
echo "[ 9/12 ] File auto-save — save_report public API"

SAVE_PROJECT5="$TMPDIR_BASE/save-test-5"
mkdir -p "$SAVE_PROJECT5/.codex-collab"

saved_path=$(
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  save_report "codex-debate" "Test summary content here" "$SAVE_PROJECT5" '{"consensus":"true","rounds":3}'
)

if [[ -n "$saved_path" && -f "$saved_path" ]]; then
  ok "save_report: returned valid file path"
  assert_file_contains "save_report: has summary content" "$saved_path" "Test summary content here"
  assert_file_contains "save_report: has command in metadata" "$saved_path" "# Command:   codex-debate"
  assert_file_contains "save_report: has result JSON" "$saved_path" "consensus"
else
  fail "save_report: did not return valid file path (got: '$saved_path')"
fi

# Test save_report error handling — missing args
error_output=$(
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  save_report "" "" "$SAVE_PROJECT5" 2>&1
) || true
assert_contains "save_report: error on missing args" "$error_output" "WARNING"

echo ""

# ---------------------------------------------------------------------------
# Test 10: File auto-save — reports directory auto-created
# ---------------------------------------------------------------------------
echo "[ 10/12 ] File auto-save — reports directory auto-creation"

SAVE_PROJECT6="$TMPDIR_BASE/save-test-6"
# Deliberately do NOT create .codex-collab/reports/
mkdir -p "$SAVE_PROJECT6"

saved_path=$(
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  save_report "codex-evaluate" "Auto-created dir test" "$SAVE_PROJECT6" '{}'
)

if [[ -d "$SAVE_PROJECT6/.codex-collab/reports" ]]; then
  ok "reports directory auto-created"
else
  fail "reports directory was not auto-created at $SAVE_PROJECT6/.codex-collab/reports/"
fi

if [[ -n "$saved_path" && -f "$saved_path" ]]; then
  ok "report file saved in auto-created directory"
else
  fail "report file not saved after auto-creating directory"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 11: Console formatting — minimal single-line output
# ---------------------------------------------------------------------------
echo "[ 11/12 ] Console formatting — minimal single-line for all commands"

for cmd_pair in "codex-debate:Debate" "codex-evaluate:Evaluate" "codex-ask:Ask"; do
  cmd="${cmd_pair%%:*}"
  label="${cmd_pair##*:}"
  output=$(
    export CODEX_STATUS_VERBOSITY="minimal"
    export CODEX_STATUS_FORMAT="compact"
    export CODEX_STATUS_AUTO_SUMMARY="true"
    export CODEX_STATUS_AUTO_SAVE="false"
    unset CODEX_CONFIG_LOADED
    source "$SCRIPT"
    generate_command_summary "$cmd" '{"consensus":"true","confidence":"0.9","mode":"write"}' ""
  )
  assert_line_count_eq "minimal $cmd: single line" "$output" 1
  assert_contains "minimal $cmd: has label" "$output" "$label"
done

# Unknown command also single line
output=$(
  export CODEX_STATUS_VERBOSITY="minimal"
  export CODEX_STATUS_FORMAT="compact"
  export CODEX_STATUS_AUTO_SUMMARY="true"
  export CODEX_STATUS_AUTO_SAVE="false"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "custom-command" '{}' ""
)
assert_line_count_eq "minimal custom-command: single line" "$output" 1
assert_contains "minimal custom: shows completed" "$output" "custom-command: completed"

echo ""

# ---------------------------------------------------------------------------
# Test 12: File auto-save — filename sanitization
# ---------------------------------------------------------------------------
echo "[ 12/12 ] File auto-save — filename sanitization"

SAVE_PROJECT7="$TMPDIR_BASE/save-test-7"
mkdir -p "$SAVE_PROJECT7/.codex-collab"

# Command name with leading slash
saved_path=$(
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  save_report "/codex-debate" "Slash prefix test" "$SAVE_PROJECT7" '{}'
)

if [[ -n "$saved_path" && -f "$saved_path" ]]; then
  basename_file=$(basename "$saved_path")
  # Should NOT start with a slash or hyphen in the filename
  if echo "$basename_file" | grep -qE "^codex-debate-"; then
    ok "filename sanitized: leading slash removed"
  else
    fail "filename sanitized: expected 'codex-debate-...' got '$basename_file'"
  fi
else
  fail "save_report with /codex-debate: file not created"
fi

# Command name with special characters
saved_path=$(
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  save_report "my:custom/cmd" "Special char test" "$SAVE_PROJECT7" '{}'
)

if [[ -n "$saved_path" && -f "$saved_path" ]]; then
  basename_file=$(basename "$saved_path")
  # Special characters should be replaced with hyphens
  if echo "$basename_file" | grep -qE "^my-custom-cmd-"; then
    ok "filename sanitized: special chars replaced"
  else
    # Still pass if it's any valid filename without the special chars
    if ! echo "$basename_file" | grep -q '[:/]'; then
      ok "filename sanitized: no special chars in filename (got: $basename_file)"
    else
      fail "filename sanitized: still has special chars in '$basename_file'"
    fi
  fi
else
  fail "save_report with special chars: file not created"
fi

echo ""

# ===========================================================================
# Summary
# ===========================================================================
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
