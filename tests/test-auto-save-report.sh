#!/usr/bin/env bash
# test-auto-save-report.sh — Unit tests for auto-save report logic
#
# Tests:
#   1. Reports directory auto-creation
#   2. Timestamped filename generation
#   3. Report content includes metadata header
#   4. save_report function creates file with correct content
#   5. Auto-save disabled when auto_save=false
#   6. Auto-save enabled by default
#   7. Report file includes result JSON when provided
#   8. Multiple reports create separate files
#   9. Reports directory under project root (not cwd)
#  10. save_report returns file path on success
#  11. Command name sanitization in filenames
#  12. emit_post_command_summary auto-saves full report
#
# Usage:
#   bash tests/test-auto-save-report.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed

set -euo pipefail

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required to run auto-save report tests" >&2
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

assert_file_exists() {
  local label="$1" filepath="$2"
  if [[ -f "$filepath" ]]; then
    ok "$label"
  else
    fail "$label — file not found: $filepath"
  fi
}

assert_dir_exists() {
  local label="$1" dirpath="$2"
  if [[ -d "$dirpath" ]]; then
    ok "$label"
  else
    fail "$label — directory not found: $dirpath"
  fi
}

# ---------------------------------------------------------------------------
# Test Setup
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/status-summary.sh"

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

echo "=== codex-collab auto-save report tests ==="
echo ""

# ---------------------------------------------------------------------------
# Test 1: Reports directory auto-creation
# ---------------------------------------------------------------------------
echo "[ 1/12 ] Reports directory auto-creation"

PROJECT1="$TMPDIR_BASE/project1"
mkdir -p "$PROJECT1"
# No .codex-collab/reports/ yet

(
  export CODEX_STATUS_AUTO_SAVE="true"
  export CODEX_STATUS_VERBOSITY="minimal"
  export CODEX_PROJECT_ROOT="$PROJECT1"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  save_report "codex-debate" "test content" "$PROJECT1" >/dev/null 2>&1
)

assert_dir_exists "reports dir auto-created" "$PROJECT1/.codex-collab/reports"

# Check a file was created
file_count=$(find "$PROJECT1/.codex-collab/reports" -name "*.txt" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$file_count" -ge 1 ]]; then
  ok "report file created in reports dir (found $file_count file(s))"
else
  fail "report file should be created in reports dir"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 2: Timestamped filename generation
# ---------------------------------------------------------------------------
echo "[ 2/12 ] Timestamped filename format"

PROJECT2="$TMPDIR_BASE/project2"
mkdir -p "$PROJECT2"

filepath=$(
  export CODEX_STATUS_AUTO_SAVE="true"
  export CODEX_PROJECT_ROOT="$PROJECT2"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  save_report "codex-evaluate" "evaluation content" "$PROJECT2"
)

# Filename should match: codex-evaluate-YYYYMMDD-HHMMSS.txt
filename="$(basename "$filepath")"
if echo "$filename" | grep -qE '^codex-evaluate-[0-9]{8}-[0-9]{6}\.txt$'; then
  ok "filename matches timestamped pattern: $filename"
else
  fail "filename should match codex-evaluate-YYYYMMDD-HHMMSS.txt, got: $filename"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 3: Report content includes metadata header
# ---------------------------------------------------------------------------
echo "[ 3/12 ] Report metadata header"

assert_file_exists "report file exists" "$filepath"

content="$(cat "$filepath")"
assert_contains "header: title" "$content" "# codex-collab Summary Report"
assert_contains "header: command" "$content" "# Command:   codex-evaluate"
assert_contains "header: generated" "$content" "# Generated:"
assert_contains "header: project" "$content" "# Project:   $PROJECT2"
assert_contains "body: content" "$content" "evaluation content"

echo ""

# ---------------------------------------------------------------------------
# Test 4: save_report with result JSON
# ---------------------------------------------------------------------------
echo "[ 4/12 ] Report with result JSON metadata"

PROJECT4="$TMPDIR_BASE/project4"
mkdir -p "$PROJECT4"

filepath4=$(
  export CODEX_PROJECT_ROOT="$PROJECT4"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  save_report "codex-debate" "debate summary" "$PROJECT4" '{"consensus":"true","rounds":3}'
)

content4="$(cat "$filepath4")"
assert_contains "result JSON in header" "$content4" '# Result:    {"consensus":"true","rounds":3}'

echo ""

# ---------------------------------------------------------------------------
# Test 5: Auto-save disabled when auto_save=false
# ---------------------------------------------------------------------------
echo "[ 5/12 ] Auto-save disabled"

PROJECT5="$TMPDIR_BASE/project5"
mkdir -p "$PROJECT5"

output5=$(
  export CODEX_STATUS_AUTO_SAVE="false"
  export CODEX_STATUS_VERBOSITY="minimal"
  export CODEX_PROJECT_ROOT="$PROJECT5"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-debate" '{"consensus":"true"}' 2>/dev/null
)

# Summary should still display
assert_contains "summary still displayed" "$output5" "Debate: consensus=true"

# But no reports directory should be created
if [[ ! -d "$PROJECT5/.codex-collab/reports" ]]; then
  ok "no reports dir created when auto_save=false"
else
  file_count5=$(find "$PROJECT5/.codex-collab/reports" -name "*.txt" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$file_count5" -eq 0 ]]; then
    ok "no report files when auto_save=false"
  else
    fail "should not create report files when auto_save=false"
  fi
fi

echo ""

# ---------------------------------------------------------------------------
# Test 6: Auto-save enabled by default
# ---------------------------------------------------------------------------
echo "[ 6/12 ] Auto-save enabled by default"

PROJECT6="$TMPDIR_BASE/project6"
mkdir -p "$PROJECT6"

output6=$(
  unset CODEX_STATUS_AUTO_SAVE
  export CODEX_STATUS_VERBOSITY="minimal"
  export CODEX_PROJECT_ROOT="$PROJECT6"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-ask" '{"mode":"read-only"}' 2>/dev/null
)

assert_contains "summary displayed" "$output6" "Ask: mode=read-only"
assert_dir_exists "reports dir auto-created by default" "$PROJECT6/.codex-collab/reports"

file_count6=$(find "$PROJECT6/.codex-collab/reports" -name "codex-ask-*.txt" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$file_count6" -ge 1 ]]; then
  ok "report file auto-saved by default"
else
  fail "report file should be auto-saved by default"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 7: Report file includes result JSON when provided
# ---------------------------------------------------------------------------
echo "[ 7/12 ] Result JSON in auto-saved report"

PROJECT7="$TMPDIR_BASE/project7"
mkdir -p "$PROJECT7"

(
  unset CODEX_STATUS_AUTO_SAVE
  export CODEX_STATUS_VERBOSITY="normal"
  export CODEX_PROJECT_ROOT="$PROJECT7"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  generate_command_summary "codex-evaluate" '{"confidence":"0.92","issue_count":"2"}' 2>/dev/null
)

report7=$(find "$PROJECT7/.codex-collab/reports" -name "codex-evaluate-*.txt" -print -quit 2>/dev/null)
if [[ -n "$report7" ]]; then
  content7="$(cat "$report7")"
  assert_contains "result JSON in auto-saved report" "$content7" '{"confidence":"0.92","issue_count":"2"}'
else
  fail "auto-saved report file should exist"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 8: Multiple reports create separate files
# ---------------------------------------------------------------------------
echo "[ 8/12 ] Multiple reports create separate files"

PROJECT8="$TMPDIR_BASE/project8"
mkdir -p "$PROJECT8"

(
  unset CODEX_STATUS_AUTO_SAVE
  export CODEX_STATUS_VERBOSITY="minimal"
  export CODEX_PROJECT_ROOT="$PROJECT8"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  save_report "codex-debate" "report one" "$PROJECT8" >/dev/null
  sleep 1  # Ensure different timestamp
  save_report "codex-evaluate" "report two" "$PROJECT8" >/dev/null
)

file_count8=$(find "$PROJECT8/.codex-collab/reports" -name "*.txt" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$file_count8" -ge 2 ]]; then
  ok "multiple reports created ($file_count8 files)"
else
  fail "expected at least 2 report files, got $file_count8"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 9: Reports under project root, not cwd
# ---------------------------------------------------------------------------
echo "[ 9/12 ] Reports under project root"

PROJECT9="$TMPDIR_BASE/project9"
mkdir -p "$PROJECT9"
OTHER_DIR="$TMPDIR_BASE/other-dir"
mkdir -p "$OTHER_DIR"

(
  cd "$OTHER_DIR"
  export CODEX_STATUS_AUTO_SAVE="true"
  export CODEX_PROJECT_ROOT="$PROJECT9"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  save_report "codex-ask" "ask content" "$PROJECT9" >/dev/null 2>&1
)

assert_dir_exists "reports in project root" "$PROJECT9/.codex-collab/reports"
if [[ ! -d "$OTHER_DIR/.codex-collab/reports" ]]; then
  ok "no reports in cwd when project root differs"
else
  fail "should not create reports in cwd when project root is different"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 10: save_report returns file path
# ---------------------------------------------------------------------------
echo "[ 10/12 ] save_report returns file path"

PROJECT10="$TMPDIR_BASE/project10"
mkdir -p "$PROJECT10"

returned_path=$(
  export CODEX_PROJECT_ROOT="$PROJECT10"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  save_report "codex-debate" "test content" "$PROJECT10"
)

if [[ "$returned_path" == *".codex-collab/reports/codex-debate-"*".txt" ]]; then
  ok "save_report returns valid file path"
else
  fail "save_report should return report file path, got: $returned_path"
fi

assert_file_exists "returned path is a real file" "$returned_path"

echo ""

# ---------------------------------------------------------------------------
# Test 11: Command name sanitization in filenames
# ---------------------------------------------------------------------------
echo "[ 11/12 ] Command name sanitization"

PROJECT11="$TMPDIR_BASE/project11"
mkdir -p "$PROJECT11"

filepath11=$(
  export CODEX_PROJECT_ROOT="$PROJECT11"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  save_report "/codex-debate" "sanitized test" "$PROJECT11"
)

filename11="$(basename "$filepath11")"
# Leading / should be stripped
if echo "$filename11" | grep -qE '^codex-debate-[0-9]{8}-[0-9]{6}\.txt$'; then
  ok "leading slash stripped from command name"
else
  fail "command name not sanitized properly, got: $filename11"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 12: get_status_config includes auto_save
# ---------------------------------------------------------------------------
echo "[ 12/12 ] get_status_config includes auto_save"

output12=$(
  export CODEX_STATUS_AUTO_SAVE="true"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  get_status_config
)

assert_contains "auto_save in config output" "$output12" "auto_save=true"

# Test with auto_save=false
output12b=$(
  export CODEX_STATUS_AUTO_SAVE="false"
  unset CODEX_CONFIG_LOADED
  source "$SCRIPT"
  get_status_config
)

assert_contains "auto_save=false in config output" "$output12b" "auto_save=false"

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
