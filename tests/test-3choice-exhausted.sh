#!/usr/bin/env bash
# test-3choice-exhausted.sh — Verify exactly 3 choices are shown when max rounds exhausted
#
# Tests Sub-AC 2 of AC 8: When max rounds are exhausted, the QuickPick UI
# presents exactly 3 end-of-debate choices (excluding "additional round").
#
# Usage:
#   ./tests/test-3choice-exhausted.sh
#
# Exit codes:
#   0 — all tests pass
#   1 — one or more tests failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Counters
PASS=0
FAIL=0
TOTAL=0

# Colors
GREEN="\033[32m"
RED="\033[31m"
RESET="\033[0m"
BOLD="\033[1m"

pass() {
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "  ${GREEN}✓${RESET} $1"
}

fail() {
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "  ${RED}✗${RESET} $1"
  if [[ -n "${2:-}" ]]; then
    echo -e "    ${RED}→ $2${RESET}"
  fi
}

echo ""
echo -e "${BOLD}=== 3-Choice QuickPick When Max Rounds Exhausted ===${RESET}"
echo ""

# ---------------------------------------------------------------------------
# Source the scripts (debate-result-handler.sh internally sources the same
# deps as display-non-consensus-choices.sh, so source it first, then overlay)
# ---------------------------------------------------------------------------

# Source debate-result-handler.sh first (it sources debate-round-cap.sh internally)
source "${PROJECT_ROOT}/scripts/debate-result-handler.sh" 2>/dev/null || true

# Source display-non-consensus-choices.sh — skip re-sourcing debate-round-cap.sh
# by pretending the config is already loaded
export CODEX_CONFIG_LOADED=1
source "${PROJECT_ROOT}/scripts/display-non-consensus-choices.sh" 2>/dev/null || true

# Override debate-round-cap functions for testing with controlled values
get_effective_max_rounds() { echo "5"; }
get_default_rounds() { echo "3"; }
get_max_additional_rounds() { echo "2"; }
is_within_cap() {
  local round="${1:-0}"
  [[ "$round" -le 5 ]]
}

# Sample debate result JSON
RESULT_JSON='{"topic":"Test debate topic","consensus_reached":false,"rounds":5,"codex_position":"Use REST API","claude_position":"Use GraphQL","codex_confidence":0.7,"claude_confidence":0.8}'

# ===========================================================================
echo -e "${BOLD}Group 1: display-non-consensus-choices.sh — 3-choice menu${RESET}"
# ===========================================================================

# Test: When rounds exhausted (5/5), menu should NOT contain "ANOTHER"
output=$(display_non_consensus_choices "$RESULT_JSON" "5" "test-session" 2>/dev/null || true)

if echo "$output" | grep -q "ANOTHER"; then
  fail "1.1 Menu should NOT contain 'ANOTHER' when max rounds exhausted" "Found 'ANOTHER' in output"
else
  pass "1.1 Menu excludes 'ANOTHER' option when max rounds exhausted"
fi

# Test: Should contain exactly 3 numbered choices [1], [2], [3]
if echo "$output" | grep -qE '\[1\].*CLAUDE' && \
   echo "$output" | grep -qE '\[2\].*CODEX' && \
   echo "$output" | grep -qE '\[3\].*DISCARD'; then
  pass "1.2 Menu shows [1] CLAUDE, [2] CODEX, [3] DISCARD"
else
  fail "1.2 Expected [1] CLAUDE, [2] CODEX, [3] DISCARD" "Output: $(echo "$output" | grep -E '\[[0-9]\]')"
fi

# Test: Should NOT contain [4]
if echo "$output" | grep -qE '\[4\]'; then
  fail "1.3 Menu should NOT contain [4] in 3-choice mode" "Found [4] in output"
else
  pass "1.3 No [4] option present in 3-choice mode"
fi

# Test: Reply hint should say "1, 2, or 3" not "1, 2, 3, or 4"
if echo "$output" | grep -q "1, 2, or 3"; then
  pass "1.4 Reply hint says '1, 2, or 3'"
else
  fail "1.4 Reply hint should say '1, 2, or 3'" "Output: $(echo "$output" | grep -i 'reply')"
fi

# Test: Header should contain "Max debate rounds exhausted"
if echo "$output" | grep -qi "max.*round.*exhausted"; then
  pass "1.5 Header mentions max rounds exhausted"
else
  fail "1.5 Header should mention max rounds exhausted"
fi

# ===========================================================================
echo ""
echo -e "${BOLD}Group 2: display-non-consensus-choices.sh — 4-choice menu (rounds available)${RESET}"
# ===========================================================================

# When rounds NOT exhausted (3/5), should show 4 choices
output_4=$(display_non_consensus_choices "$RESULT_JSON" "3" "test-session" 2>/dev/null || true)

if echo "$output_4" | grep -q "ANOTHER"; then
  pass "2.1 Menu contains 'ANOTHER' when rounds are available"
else
  fail "2.1 Menu should contain 'ANOTHER' when rounds available"
fi

if echo "$output_4" | grep -qE '\[4\].*DISCARD'; then
  pass "2.2 Discard is [4] in 4-choice mode"
else
  fail "2.2 Discard should be [4] in 4-choice mode"
fi

if echo "$output_4" | grep -q "1, 2, 3, or 4"; then
  pass "2.3 Reply hint says '1, 2, 3, or 4' in 4-choice mode"
else
  fail "2.3 Reply hint should say '1, 2, 3, or 4' in 4-choice mode"
fi

# ===========================================================================
echo ""
echo -e "${BOLD}Group 3: parse_non_consensus_choice — 3-choice mode parsing${RESET}"
# ===========================================================================

# In 3-choice mode (can_add_round=false), "3" should map to discard
choice=$(parse_non_consensus_choice "3" "false" 2>/dev/null || true)
if [[ "$choice" == "discard" ]]; then
  pass "3.1 Input '3' maps to 'discard' in 3-choice mode"
else
  fail "3.1 Input '3' should map to 'discard' in 3-choice mode" "Got: $choice"
fi

# "discard" keyword still works
choice=$(parse_non_consensus_choice "discard" "false" 2>/dev/null || true)
if [[ "$choice" == "discard" ]]; then
  pass "3.2 Input 'discard' maps to 'discard' in 3-choice mode"
else
  fail "3.2 Input 'discard' should map to 'discard'" "Got: $choice"
fi

# "another" keyword should return round_cap_exceeded
choice=$(parse_non_consensus_choice "another" "false" 2>/dev/null || true)
if [[ "$choice" == "round_cap_exceeded" ]]; then
  pass "3.3 Input 'another' returns 'round_cap_exceeded' in 3-choice mode"
else
  fail "3.3 Input 'another' should return 'round_cap_exceeded'" "Got: $choice"
fi

# "1" still maps to adopt_claude
choice=$(parse_non_consensus_choice "1" "false" 2>/dev/null || true)
if [[ "$choice" == "adopt_claude" ]]; then
  pass "3.4 Input '1' maps to 'adopt_claude' in 3-choice mode"
else
  fail "3.4 Input '1' should map to 'adopt_claude'" "Got: $choice"
fi

# "2" still maps to adopt_codex
choice=$(parse_non_consensus_choice "2" "false" 2>/dev/null || true)
if [[ "$choice" == "adopt_codex" ]]; then
  pass "3.5 Input '2' maps to 'adopt_codex' in 3-choice mode"
else
  fail "3.5 Input '2' should map to 'adopt_codex'" "Got: $choice"
fi

# ===========================================================================
echo ""
echo -e "${BOLD}Group 4: parse_non_consensus_choice — 4-choice mode (rounds available)${RESET}"
# ===========================================================================

# In 4-choice mode (can_add_round=true), "3" should map to additional_round
choice=$(parse_non_consensus_choice "3" "true" 2>/dev/null || true)
if [[ "$choice" == "additional_round" ]]; then
  pass "4.1 Input '3' maps to 'additional_round' in 4-choice mode"
else
  fail "4.1 Input '3' should map to 'additional_round' in 4-choice mode" "Got: $choice"
fi

# "4" should map to discard in 4-choice mode
choice=$(parse_non_consensus_choice "4" "true" 2>/dev/null || true)
if [[ "$choice" == "discard" ]]; then
  pass "4.2 Input '4' maps to 'discard' in 4-choice mode"
else
  fail "4.2 Input '4' should map to 'discard' in 4-choice mode" "Got: $choice"
fi

# ===========================================================================
echo ""
echo -e "${BOLD}Group 5: debate-result-handler.sh — present_result_choices 3-choice${RESET}"
# ===========================================================================

# When current_round >= effective_max (5/5), should show 3-choice mode
output=$(present_result_choices "$RESULT_JSON" "test-session" "5" 2>/dev/null || true)

if echo "$output" | grep -q "Max Rounds Exhausted"; then
  pass "5.1 Header shows 'Max Rounds Exhausted' when rounds exhausted"
else
  fail "5.1 Header should show 'Max Rounds Exhausted'" "Output: $(echo "$output" | head -5)"
fi

if echo "$output" | grep -q "Continue debate"; then
  fail "5.2 Should NOT show 'Continue debate' option" "Found 'Continue debate' in output"
else
  pass "5.2 'Continue debate' option excluded when rounds exhausted"
fi

# [3] should be Discard, not Continue
if echo "$output" | grep -qE '\[3\].*Discard'; then
  pass "5.3 [3] is 'Discard both' in 3-choice mode"
else
  fail "5.3 [3] should be 'Discard both' when rounds exhausted"
fi

# Should NOT have [4]
if echo "$output" | grep -qE '\[4\]'; then
  fail "5.4 Should NOT have [4] option" "Found [4] in output"
else
  pass "5.4 No [4] option in 3-choice mode"
fi

# HANDLER_CHOICES_COUNT should be 3
if echo "$output" | grep -q "HANDLER_CHOICES_COUNT=3"; then
  pass "5.5 HANDLER_CHOICES_COUNT=3 when max rounds exhausted"
else
  fail "5.5 HANDLER_CHOICES_COUNT should be 3" "Output: $(echo "$output" | grep HANDLER_CHOICES_COUNT)"
fi

# HANDLER_MAX_ROUNDS_EXHAUSTED should be true
if echo "$output" | grep -q "HANDLER_MAX_ROUNDS_EXHAUSTED=true"; then
  pass "5.6 HANDLER_MAX_ROUNDS_EXHAUSTED=true when rounds exhausted"
else
  fail "5.6 HANDLER_MAX_ROUNDS_EXHAUSTED should be true" "Output: $(echo "$output" | grep HANDLER_MAX_ROUNDS)"
fi

# ===========================================================================
echo ""
echo -e "${BOLD}Group 6: debate-result-handler.sh — parse_user_choice 3-choice mode${RESET}"
# ===========================================================================

# In 3-choice mode (max_rounds_exhausted=true), "3" should map to discard
choice=$(parse_user_choice "3" "true" 2>/dev/null || true)
if [[ "$choice" == "discard" ]]; then
  pass "6.1 parse_user_choice '3' with max_exhausted=true → discard"
else
  fail "6.1 parse_user_choice '3' should map to discard" "Got: $choice"
fi

# "continue" keyword should map to discard with notice
choice=$(parse_user_choice "continue" "true" 2>/dev/null || true)
if [[ "$choice" == "discard" ]]; then
  pass "6.2 parse_user_choice 'continue' with max_exhausted=true → discard"
else
  fail "6.2 parse_user_choice 'continue' should map to discard when exhausted" "Got: $choice"
fi

# In 4-choice mode (max_rounds_exhausted=false), "3" should map to continue
choice=$(parse_user_choice "3" "false" 2>/dev/null || true)
if [[ "$choice" == "continue" ]]; then
  pass "6.3 parse_user_choice '3' with max_exhausted=false → continue"
else
  fail "6.3 parse_user_choice '3' should map to continue in 4-choice mode" "Got: $choice"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "═══════════════════════════════════════════"
echo -e "${BOLD}Results: ${PASS} passed, ${FAIL} failed (${TOTAL} total)${RESET}"
echo "═══════════════════════════════════════════"

if [[ "$FAIL" -gt 0 ]]; then
  echo -e "${RED}FAIL${RESET}"
  exit 1
else
  echo -e "${GREEN}ALL PASSED${RESET}"
  exit 0
fi
