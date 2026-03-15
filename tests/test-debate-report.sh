#!/usr/bin/env bash
# test-debate-report.sh — Tests for scripts/debate-report.sh
#
# Validates:
#   1. Round collector lifecycle (init → collect → get → cleanup)
#   2. Report assembly with per-round summaries and confidence scores
#   3. Report formatting (text output with summary table)
#   4. JSON output structure and field completeness
#   5. Confidence statistics (averages, trends, convergence)
#   6. Consensus detection in assembled reports
#   7. Non-consensus scenario handling
#   8. Edge cases (empty rounds, single round)
#
# Usage: bash tests/test-debate-report.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PASS=0
FAIL=0

# Disable auto-save for tests
export CODEX_STATUS_AUTO_SAVE="false"
export CODEX_PROJECT_ROOT="$PROJECT_ROOT"

# Source the script under test
source "${PROJECT_ROOT}/scripts/debate-report.sh"

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------
pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    pass "$msg"
  else
    fail "$msg (expected to contain: '$needle')"
  fi
}

assert_not_empty() {
  local value="$1" msg="$2"
  if [[ -n "$value" ]]; then
    pass "$msg"
  else
    fail "$msg (was empty)"
  fi
}

assert_equals() {
  local actual="$1" expected="$2" msg="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$msg"
  else
    fail "$msg (expected: '$expected', got: '$actual')"
  fi
}

json_val() {
  python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    keys = sys.argv[2].split('.')
    c = d
    for k in keys:
        if isinstance(c, dict): c = c[k]
        elif isinstance(c, list): c = c[int(k)]
        else: c = None; break
    if isinstance(c, bool): print('true' if c else 'false')
    elif c is None: print('')
    else: print(c)
except Exception: print('')
" "$1" "$2" 2>/dev/null
}

# 3-round consensus test data
ROUNDS_CONSENSUS='[{"round":1,"codex":{"position":"Use classes","confidence":0.8,"key_arguments":["encapsulation"],"agrees_with_opponent":false,"counterpoints":[]},"claude":{"position":"Use functions","confidence":0.7,"key_arguments":["composability"],"agrees_with_opponent":false,"counterpoints":["classes add overhead"]}},{"round":2,"codex":{"position":"Hybrid approach","confidence":0.75,"key_arguments":["best of both"],"agrees_with_opponent":false,"counterpoints":[]},"claude":{"position":"Hybrid with functional core","confidence":0.8,"key_arguments":["testability"],"agrees_with_opponent":false,"counterpoints":[]}},{"round":3,"codex":{"position":"Functional core + wrappers","confidence":0.85,"key_arguments":["matches patterns"],"agrees_with_opponent":true,"counterpoints":[]},"claude":{"position":"Functional core + wrappers","confidence":0.85,"key_arguments":["maintainable"],"agrees_with_opponent":true,"counterpoints":[]}}]'

# 2-round non-consensus test data
ROUNDS_NO_CONSENSUS='[{"round":1,"codex":{"position":"Redis","confidence":0.9,"key_arguments":["fast","distributed"],"agrees_with_opponent":false,"counterpoints":[]},"claude":{"position":"SQLite","confidence":0.85,"key_arguments":["simple","zero-config"],"agrees_with_opponent":false,"counterpoints":["Redis needs infra"]}},{"round":2,"codex":{"position":"Redis with fallback","confidence":0.88,"key_arguments":["speed matters"],"agrees_with_opponent":false,"counterpoints":[]},"claude":{"position":"SQLite is sufficient","confidence":0.82,"key_arguments":["no network overhead"],"agrees_with_opponent":false,"counterpoints":[]}}]'

echo "=== Test Group 1: Round Collector Lifecycle ==="

init_report_collector
assert_not_empty "$_REPORT_COLLECTOR_FILE" "Collector file created"

# Collect 2 rounds
collect_round_summary 1 \
  '{"position":"A","confidence":0.8,"key_arguments":["arg1"],"agrees_with_opponent":false}' \
  '{"position":"B","confidence":0.7,"key_arguments":["arg2"],"agrees_with_opponent":false}'

collect_round_summary 2 \
  '{"position":"A+","confidence":0.85,"key_arguments":["arg3"],"agrees_with_opponent":true}' \
  '{"position":"A+","confidence":0.82,"key_arguments":["arg4"],"agrees_with_opponent":true}'

collected=$(get_collected_rounds)
round_count=$(python3 -c "import json; print(len(json.loads('$collected')))" 2>/dev/null)
assert_equals "$round_count" "2" "Collected 2 rounds"

# Check round 1 data
r1_codex_conf=$(json_val "$collected" "0.codex.confidence")
assert_equals "$r1_codex_conf" "0.8" "Round 1 Codex confidence is 0.8"

r1_claude_pos=$(json_val "$collected" "0.claude.position")
assert_equals "$r1_claude_pos" "B" "Round 1 Claude position captured"

cleanup_report_collector
assert_equals "$_REPORT_COLLECTOR_FILE" "" "Collector file cleaned up"

echo ""
echo "=== Test Group 2: Report Assembly — Consensus Scenario ==="

report_json=$(assemble_debate_report "Classes vs functions" 5 3 2 "$ROUNDS_CONSENSUS")

assert_equals "$(json_val "$report_json" "total_rounds")" "3" "Total rounds = 3"
assert_equals "$(json_val "$report_json" "consensus_reached")" "true" "Consensus reached = true"
assert_equals "$(json_val "$report_json" "consensus_round")" "3" "Consensus at round 3"
assert_equals "$(json_val "$report_json" "max_rounds")" "5" "Max rounds = 5"
assert_equals "$(json_val "$report_json" "default_rounds")" "3" "Default rounds = 3"
assert_equals "$(json_val "$report_json" "max_additional_rounds")" "2" "Max additional = 2"
assert_equals "$(json_val "$report_json" "report_version")" "2.1.0" "Report version = 2.1.0"
assert_not_empty "$(json_val "$report_json" "generated_at")" "Generated timestamp present"

echo ""
echo "=== Test Group 3: Per-Round Summaries ==="

rs_count=$(python3 -c "import json; r=json.loads('$report_json'); print(len(r['round_summaries']))" 2>/dev/null)
assert_equals "$rs_count" "3" "3 round summaries present"

# Check round 1 summary fields
r1_codex_pos=$(python3 -c "import json; r=json.loads('$report_json'); print(r['round_summaries'][0]['codex_position'])" 2>/dev/null)
assert_equals "$r1_codex_pos" "Use classes" "R1 Codex position"

r1_consensus=$(python3 -c "import json; r=json.loads('$report_json'); print(r['round_summaries'][0]['consensus'])" 2>/dev/null)
assert_equals "$r1_consensus" "No" "R1 consensus = No"

r3_consensus=$(python3 -c "import json; r=json.loads('$report_json'); print(r['round_summaries'][2]['consensus'])" 2>/dev/null)
assert_equals "$r3_consensus" "Yes" "R3 consensus = Yes"

echo ""
echo "=== Test Group 4: Confidence Statistics ==="

codex_avg=$(json_val "$report_json" "confidence.codex_average")
assert_equals "$codex_avg" "0.8" "Codex avg confidence = 0.8"

claude_avg=$(json_val "$report_json" "confidence.claude_average")
assert_equals "$claude_avg" "0.783" "Claude avg confidence = 0.783"

codex_final=$(json_val "$report_json" "confidence.codex_final")
assert_equals "$codex_final" "0.85" "Codex final confidence = 0.85"

convergence=$(json_val "$report_json" "confidence.convergence")
assert_equals "$convergence" "converging" "Convergence = converging"

codex_trend=$(json_val "$report_json" "confidence.codex_trend")
assert_equals "$codex_trend" "stable" "Codex trend = stable"

claude_trend=$(json_val "$report_json" "confidence.claude_trend")
assert_equals "$claude_trend" "increasing" "Claude trend = increasing"

# Per-round confidence arrays
codex_r1_conf=$(python3 -c "import json; r=json.loads('$report_json'); print(r['confidence']['codex_per_round'][0])" 2>/dev/null)
assert_equals "$codex_r1_conf" "0.8" "Codex per-round[0] = 0.8"

codex_r3_conf=$(python3 -c "import json; r=json.loads('$report_json'); print(r['confidence']['codex_per_round'][2])" 2>/dev/null)
assert_equals "$codex_r3_conf" "0.85" "Codex per-round[2] = 0.85"

echo ""
echo "=== Test Group 5: Report Assembly — Non-Consensus ==="

nc_report=$(assemble_debate_report "Redis vs SQLite" 5 3 2 "$ROUNDS_NO_CONSENSUS")

assert_equals "$(json_val "$nc_report" "consensus_reached")" "false" "Non-consensus: reached = false"
assert_equals "$(json_val "$nc_report" "consensus_round")" "" "Non-consensus: round = null"
assert_equals "$(json_val "$nc_report" "total_rounds")" "2" "Non-consensus: 2 rounds"

nc_divergence=$(json_val "$nc_report" "confidence.convergence")
assert_not_empty "$nc_divergence" "Non-consensus: convergence field present"

echo ""
echo "=== Test Group 6: Text Formatting ==="

formatted=$(format_debate_report "$report_json" "normal")

assert_contains "$formatted" "## Debate Report" "Header present"
assert_contains "$formatted" "### Topic" "Topic section present"
assert_contains "$formatted" "Classes vs functions" "Topic text present"
assert_contains "$formatted" "### Round Summary" "Round summary section present"
assert_contains "$formatted" "| Round |" "Summary table header present"
assert_contains "$formatted" "Codex Conf" "Codex confidence column present"
assert_contains "$formatted" "Claude Conf" "Claude confidence column present"
assert_contains "$formatted" "80%" "Confidence percentage formatted"
assert_contains "$formatted" "Yes" "Consensus Yes marker present"
assert_contains "$formatted" "### Consensus Reached" "Consensus section present"
assert_contains "$formatted" "### Confidence Statistics" "Confidence stats section present"
assert_contains "$formatted" "### Recommendation" "Recommendation section present"

echo ""
echo "=== Test Group 7: Verbose Formatting ==="

verbose=$(format_debate_report "$report_json" "verbose")

assert_contains "$verbose" "### Confidence Path" "Verbose: confidence path present"
assert_contains "$verbose" "### Round Configuration" "Verbose: round config present"
assert_contains "$verbose" "hard cap: 2" "Verbose: hard cap mentioned"
assert_contains "$verbose" "Round 1: Codex 80%" "Verbose: per-round confidence in path"

echo ""
echo "=== Test Group 8: Minimal Formatting ==="

minimal=$(format_debate_report "$report_json" "minimal")

# Minimal should NOT have confidence stats or path
if echo "$minimal" | grep -q "### Confidence Statistics"; then
  fail "Minimal: should NOT have confidence stats"
else
  pass "Minimal: no confidence stats section (correct)"
fi

if echo "$minimal" | grep -q "### Confidence Path"; then
  fail "Minimal: should NOT have confidence path"
else
  pass "Minimal: no confidence path section (correct)"
fi

assert_contains "$minimal" "### Round Summary" "Minimal: still has round summary table"

echo ""
echo "=== Test Group 9: Edge Cases ==="

# Empty rounds
empty_report=$(assemble_debate_report "Empty test" 3 3 0 "[]")
assert_equals "$(json_val "$empty_report" "total_rounds")" "0" "Empty: 0 rounds"
assert_equals "$(json_val "$empty_report" "consensus_reached")" "false" "Empty: no consensus"

# Single round
single='[{"round":1,"codex":{"position":"X","confidence":0.9,"key_arguments":["a"],"agrees_with_opponent":false},"claude":{"position":"Y","confidence":0.8,"key_arguments":["b"],"agrees_with_opponent":false}}]'
single_report=$(assemble_debate_report "Single round" 3 3 0 "$single")
assert_equals "$(json_val "$single_report" "total_rounds")" "1" "Single: 1 round"
assert_equals "$(json_val "$single_report" "confidence.codex_trend")" "stable" "Single: trend = stable"

echo ""
echo "=== Test Group 10: Confidence Quick Accessors ==="

conf=$(get_round_confidence 2 "codex" "$ROUNDS_CONSENSUS")
assert_equals "$conf" "0.75" "get_round_confidence R2 codex = 0.75"

conf=$(get_round_confidence 1 "claude" "$ROUNDS_CONSENSUS")
assert_equals "$conf" "0.7" "get_round_confidence R1 claude = 0.7"

summary=$(get_confidence_summary "$ROUNDS_CONSENSUS")
assert_not_empty "$summary" "get_confidence_summary returns data"
assert_equals "$(json_val "$summary" "total_rounds")" "3" "Confidence summary: 3 rounds"

echo ""
echo "=== Test Group 11: CLI Mode ==="

# JSON format
cli_json=$(bash "${PROJECT_ROOT}/scripts/debate-report.sh" --rounds "$ROUNDS_CONSENSUS" --topic "CLI test" --format json)
assert_not_empty "$cli_json" "CLI JSON output not empty"
assert_equals "$(json_val "$cli_json" "topic")" "CLI test" "CLI: topic matches"
assert_equals "$(json_val "$cli_json" "total_rounds")" "3" "CLI: 3 rounds"

# Text format
cli_text=$(bash "${PROJECT_ROOT}/scripts/debate-report.sh" --rounds "$ROUNDS_CONSENSUS" --topic "CLI test" --format text --verbosity normal)
assert_contains "$cli_text" "## Debate Report" "CLI text: header present"
assert_contains "$cli_text" "CLI test" "CLI text: topic present"

# Confidence-only mode
cli_conf=$(bash "${PROJECT_ROOT}/scripts/debate-report.sh" --confidence-only "$ROUNDS_CONSENSUS")
assert_not_empty "$cli_conf" "CLI confidence-only output not empty"
assert_equals "$(json_val "$cli_conf" "total_rounds")" "3" "CLI confidence-only: 3 rounds"

echo ""
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
