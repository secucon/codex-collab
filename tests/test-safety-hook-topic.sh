#!/usr/bin/env bash
# test-safety-hook-topic.sh — Tests for safety-hook-topic.sh
#
# Validates:
#   - Severity detection from hook output (explicit tags + content patterns)
#   - Topic derivation for each hook type (write-mode, full-auto, write-flag)
#   - should_propose_debate correctly gates on severity + config
#   - format_debate_proposal produces expected structure
#   - analyze_hook_for_debate full pipeline JSON output
#   - build_proposal_record session history JSON
#   - Edge cases: empty input, unknown patterns, long prompts

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the script under test
source "${PROJECT_DIR}/scripts/load-config.sh"
source "${PROJECT_DIR}/scripts/safety-hook-topic.sh"

# Test counters
PASSED=0
FAILED=0
TOTAL=0

# Test helper
assert_eq() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"
  TOTAL=$((TOTAL + 1))

  if [[ "$actual" == "$expected" ]]; then
    echo "  ✅ ${test_name}"
    PASSED=$((PASSED + 1))
  else
    echo "  ❌ ${test_name}"
    echo "     Expected: ${expected}"
    echo "     Actual:   ${actual}"
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() {
  local test_name="$1"
  local needle="$2"
  local haystack="$3"
  TOTAL=$((TOTAL + 1))

  if [[ "$haystack" == *"$needle"* ]]; then
    echo "  ✅ ${test_name}"
    PASSED=$((PASSED + 1))
  else
    echo "  ❌ ${test_name}"
    echo "     Expected to contain: ${needle}"
    echo "     Actual: ${haystack}"
    FAILED=$((FAILED + 1))
  fi
}

assert_exit_code() {
  local test_name="$1"
  local expected_code="$2"
  shift 2
  TOTAL=$((TOTAL + 1))

  set +e
  "$@" >/dev/null 2>&1
  local actual_code=$?
  set -e

  if [[ "$actual_code" == "$expected_code" ]]; then
    echo "  ✅ ${test_name}"
    PASSED=$((PASSED + 1))
  else
    echo "  ❌ ${test_name}"
    echo "     Expected exit: ${expected_code}, Got: ${actual_code}"
    FAILED=$((FAILED + 1))
  fi
}

echo "============================================"
echo " Testing safety-hook-topic.sh"
echo "============================================"
echo ""

# ========================================================================
# Group 1: Severity Detection — Explicit Tags
# ========================================================================
echo "--- Group 1: Severity Detection (Explicit Tags) ---"

assert_eq "critical tag" "critical" \
  "$(detect_hook_severity '[codex-collab] [SEVERITY:critical] BLOCKED: dangerous mode')"

assert_eq "warning tag" "warning" \
  "$(detect_hook_severity '[codex-collab] [SEVERITY:warning] WARNING: full-auto mode')"

assert_eq "caution tag" "caution" \
  "$(detect_hook_severity '[codex-collab] [SEVERITY:caution] SESSION NOTICE: No active session')"

assert_eq "info tag" "info" \
  "$(detect_hook_severity '[codex-collab] [SEVERITY:info] Informational message')"

echo ""

# ========================================================================
# Group 2: Severity Detection — Content Pattern Fallback
# ========================================================================
echo "--- Group 2: Severity Detection (Content Patterns) ---"

assert_eq "BLOCKED pattern" "critical" \
  "$(detect_hook_severity 'BLOCKED: Operation not allowed')"

assert_eq "WARNING + full-auto" "warning" \
  "$(detect_hook_severity 'WARNING: Codex will run in full-auto mode')"

assert_eq "WARNING + file changes" "warning" \
  "$(detect_hook_severity 'WARNING: This may file changes in working directory')"

assert_eq "WARNING + modify" "warning" \
  "$(detect_hook_severity 'WARNING: Codex may modify files')"

assert_eq "WRITE-MODE pattern" "caution" \
  "$(detect_hook_severity 'WRITE-MODE ENFORCEMENT: Codex is about to make file changes')"

assert_eq "ENFORCEMENT pattern" "caution" \
  "$(detect_hook_severity 'ENFORCEMENT: Review the prompt carefully')"

assert_eq "SESSION NOTICE pattern" "info" \
  "$(detect_hook_severity 'SESSION NOTICE: No active codex-collab session')"

assert_eq "empty input" "info" \
  "$(detect_hook_severity '')"

assert_eq "unknown pattern" "info" \
  "$(detect_hook_severity 'Some unrelated message')"

echo ""

# ========================================================================
# Group 3: Topic Derivation — Write-Mode Hook
# ========================================================================
echo "--- Group 3: Topic Derivation (Write-Mode) ---"

local_topic=$(derive_debate_topic \
  "WRITE-MODE ENFORCEMENT: Codex is about to make file changes" \
  "codex exec --write src/auth.py" \
  "이 파일의 보안 취약점을 수정해줘")

assert_contains "write-mode topic has Korean prefix" "이 작업에서 파일 수정이 안전한가?" "$local_topic"
assert_contains "write-mode topic has prompt" "보안 취약점을 수정해줘" "$local_topic"
assert_contains "write-mode topic has file" "auth.py" "$local_topic"

echo ""

# ========================================================================
# Group 4: Topic Derivation — Full-Auto Hook
# ========================================================================
echo "--- Group 4: Topic Derivation (Full-Auto) ---"

local_topic=$(derive_debate_topic \
  "[SEVERITY:warning] WARNING: Codex will run in full-auto mode" \
  "codex exec --full-auto" \
  "Refactor the entire codebase")

assert_contains "full-auto topic has risk assessment" "full-auto" "$local_topic"
assert_contains "full-auto topic has context" "Refactor the entire codebase" "$local_topic"

echo ""

# ========================================================================
# Group 5: Topic Derivation — Write Flag Hook
# ========================================================================
echo "--- Group 5: Topic Derivation (Write Flag) ---"

local_topic=$(derive_debate_topic \
  "WARNING: may cause file changes" \
  "codex exec --write src/db.py src/models.py" \
  "")

assert_contains "write-flag topic has review" "파일 변경 작업의 범위와 안전성 검토" "$local_topic"
assert_contains "write-flag topic has files" "db.py" "$local_topic"

echo ""

# ========================================================================
# Group 6: Topic Derivation — Fallback / Generic
# ========================================================================
echo "--- Group 6: Topic Derivation (Fallback) ---"

local_topic=$(derive_debate_topic \
  "Some unknown hook warning" \
  "codex exec something" \
  "Do something risky")

assert_contains "fallback topic has safety review" "안전성 검토" "$local_topic"
assert_contains "fallback topic has prompt" "Do something risky" "$local_topic"

# No prompt case
local_topic=$(derive_debate_topic "Some unknown hook" "codex exec" "")
assert_contains "fallback no-prompt has generic" "Safety review required" "$local_topic"

echo ""

# ========================================================================
# Group 7: should_propose_debate
# ========================================================================
echo "--- Group 7: should_propose_debate ---"

assert_exit_code "caution triggers proposal" 0 \
  should_propose_debate "[SEVERITY:caution] WRITE-MODE ENFORCEMENT"

assert_exit_code "warning triggers proposal" 0 \
  should_propose_debate "[SEVERITY:warning] WARNING: full-auto mode"

assert_exit_code "critical does NOT trigger" 1 \
  should_propose_debate "[SEVERITY:critical] BLOCKED"

assert_exit_code "info does NOT trigger" 1 \
  should_propose_debate "[SEVERITY:info] SESSION NOTICE"

assert_exit_code "empty does NOT trigger" 1 \
  should_propose_debate ""

echo ""

# ========================================================================
# Group 8: Hook Type Labels
# ========================================================================
echo "--- Group 8: Hook Type Labels ---"

assert_eq "write-mode label" "Write-Mode Enforcement" \
  "$(get_hook_type_label 'WRITE-MODE detected')"

assert_eq "full-auto label" "Full-Auto Mode Warning" \
  "$(get_hook_type_label 'full-auto mode detected')"

assert_eq "file changes label" "File Modification Warning" \
  "$(get_hook_type_label 'may cause file changes')"

assert_eq "blocked label" "Dangerous Mode Blocked" \
  "$(get_hook_type_label 'BLOCKED: not allowed')"

assert_eq "session label" "Session Notice" \
  "$(get_hook_type_label 'SESSION NOTICE: no active session')"

assert_eq "unknown label" "Safety Hook" \
  "$(get_hook_type_label 'some random text')"

echo ""

# ========================================================================
# Group 9: format_debate_proposal
# ========================================================================
echo "--- Group 9: format_debate_proposal ---"

proposal=$(format_debate_proposal \
  "WRITE-MODE ENFORCEMENT: Codex is about to make file changes" \
  "이 작업에서 파일 수정이 안전한가? (Write-mode safety review)" \
  "caution")

assert_contains "proposal has severity" "severity: caution" "$proposal"
assert_contains "proposal has topic" "Write-mode safety review" "$proposal"
assert_contains "proposal has Y option" "[Y] Start debate" "$proposal"
assert_contains "proposal has N option" "[N] Proceed without debate" "$proposal"
assert_contains "proposal has C option" "[C] Cancel" "$proposal"
assert_contains "proposal has rounds info" "Rounds:" "$proposal"

echo ""

# ========================================================================
# Group 10: analyze_hook_for_debate (Full Pipeline)
# ========================================================================
echo "--- Group 10: analyze_hook_for_debate ---"

set +e
analysis=$(analyze_hook_for_debate \
  "[SEVERITY:warning] WARNING: Codex will run in full-auto mode and may modify files" \
  "codex exec --full-auto" \
  "Refactor everything")
exit_code=$?
set -e

assert_eq "warning analysis returns 0" "0" "$exit_code"
assert_contains "analysis has severity" '"severity": "warning"' "$analysis"
assert_contains "analysis has should_propose true" '"should_propose": true' "$analysis"
assert_contains "analysis has topic" '"topic":' "$analysis"
assert_contains "analysis has hook_type" '"hook_type":' "$analysis"

set +e
analysis=$(analyze_hook_for_debate \
  "[SEVERITY:critical] BLOCKED: dangerous mode" \
  "codex exec --dangerously" \
  "")
exit_code=$?
set -e

assert_eq "critical analysis returns 1" "1" "$exit_code"
assert_contains "critical has should_propose false" '"should_propose": false' "$analysis"

echo ""

# ========================================================================
# Group 11: build_proposal_record
# ========================================================================
echo "--- Group 11: build_proposal_record ---"

record=$(build_proposal_record \
  "caution" \
  "Write-mode safety review" \
  "Write-Mode Enforcement" \
  "accepted" \
  "WRITE-MODE ENFORCEMENT: ...")

assert_contains "record has type" '"type": "safety-hook-debate-proposal"' "$record"
assert_contains "record has severity" '"severity": "caution"' "$record"
assert_contains "record has decision" '"decision": "accepted"' "$record"
assert_contains "record has trigger_source" '"trigger_source": "safety_hook"' "$record"
assert_contains "record has timestamp" '"timestamp":' "$record"

echo ""

# ========================================================================
# Group 12: Prompt Truncation
# ========================================================================
echo "--- Group 12: Prompt Truncation ---"

# 150-char prompt should be truncated to 100 + "..."
long_prompt="This is a very long prompt that exceeds the 100 character limit and should be truncated properly by the derive_debate_topic function for safety"
local_topic=$(derive_debate_topic \
  "WRITE-MODE ENFORCEMENT: making changes" \
  "codex exec --write" \
  "$long_prompt")

# The topic should NOT contain the full 150-char prompt
assert_contains "truncated prompt has ellipsis" "..." "$local_topic"
assert_contains "truncated prompt has beginning" "This is a very long prompt" "$local_topic"

echo ""

# ========================================================================
# Group 13: File Extraction
# ========================================================================
echo "--- Group 13: File Extraction ---"

topic_with_files=$(derive_debate_topic \
  "WARNING: may cause file changes" \
  "codex exec --write src/auth.py src/models/user.js tests/test_auth.py" \
  "")

assert_contains "extracts .py files" "auth.py" "$topic_with_files"
assert_contains "extracts .js files" "user.js" "$topic_with_files"

echo ""

# ========================================================================
# Group 14: CLI Mode
# ========================================================================
echo "--- Group 14: CLI Mode ---"

# Test severity mode
cli_severity=$(bash "${PROJECT_DIR}/scripts/safety-hook-topic.sh" \
  --hook-output "[SEVERITY:warning] WARNING: full-auto mode may modify files" \
  --mode severity 2>/dev/null)
assert_eq "CLI severity mode" "warning" "$cli_severity"

# Test topic mode
cli_topic=$(bash "${PROJECT_DIR}/scripts/safety-hook-topic.sh" \
  --hook-output "WRITE-MODE ENFORCEMENT: file changes" \
  --command "codex exec --write src/app.py" \
  --prompt "Fix the bug" \
  --mode topic 2>/dev/null)
assert_contains "CLI topic mode" "파일 수정이 안전한가" "$cli_topic"

# Test analyze mode (default)
cli_analysis=$(bash "${PROJECT_DIR}/scripts/safety-hook-topic.sh" \
  --hook-output "[SEVERITY:caution] WRITE-MODE ENFORCEMENT: changes" \
  --command "codex exec --write" \
  --mode analyze 2>/dev/null || true)
assert_contains "CLI analyze mode has JSON" '"severity"' "$cli_analysis"

echo ""

# ========================================================================
# Summary
# ========================================================================
echo "============================================"
echo " Results: ${PASSED}/${TOTAL} passed, ${FAILED} failed"
echo "============================================"

if [[ $FAILED -gt 0 ]]; then
  exit 1
fi
exit 0
