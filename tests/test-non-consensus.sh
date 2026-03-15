#!/usr/bin/env bash
# test-non-consensus.sh — Tests for non-consensus detection logic
#
# Validates:
#   1. Non-consensus detected when no participant agrees
#   2. Consensus correctly identified when agrees_with_opponent=true
#   3. Both proposals returned in non-consensus result
#   4. Divergence score calculated correctly
#   5. Convergence trend analysis works
#   6. JSONL fixture parsing
#   7. Edge cases (empty rounds, single round, etc.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR"

PASS=0
FAIL=0

pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }

check_json_field() {
  local json="$1" field="$2" expected="$3" label="$4"
  local actual
  actual=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
keys = sys.argv[2].split('.')
c = d
for k in keys:
    if isinstance(c, dict): c = c.get(k, '')
    elif isinstance(c, list):
        try: c = c[int(k)]
        except: c = ''
    else: c = ''
if isinstance(c, bool): print('true' if c else 'false')
elif isinstance(c, (list, dict)): print(json.dumps(c))
else: print(c)
" "$json" "$field" 2>/dev/null)
  if [[ "$actual" == "$expected" ]]; then
    pass "$label"
  else
    fail "$label (expected: $expected, got: $actual)"
  fi
}

echo "=== Non-Consensus Detection Tests ==="
echo ""

# ---------------------------------------------------------------------------
# Test 1: Non-consensus detection with paired rounds
# ---------------------------------------------------------------------------
echo "--- Test Group 1: Non-consensus with paired rounds ---"

NON_CONSENSUS_ROUNDS='[
  {"round":1,"codex":{"position":"Use microservices","confidence":0.85,"key_arguments":["Scale","Independence"],"agrees_with_opponent":false},"claude":{"position":"Use monolith","confidence":0.80,"key_arguments":["Simplicity"],"agrees_with_opponent":false}},
  {"round":2,"codex":{"position":"Still microservices","confidence":0.75,"key_arguments":["Growth"],"agrees_with_opponent":false},"claude":{"position":"Still monolith","confidence":0.78,"key_arguments":["Pragmatic"],"agrees_with_opponent":false}}
]'

result=$(bash -c 'source scripts/detect-non-consensus.sh 2>/dev/null; detect_non_consensus "$0" "$1"' "$NON_CONSENSUS_ROUNDS" "Architecture" 2>/dev/null)

check_json_field "$result" "consensus_state" "non-consensus" "1.1 Detects non-consensus state"
check_json_field "$result" "consensus_reached" "false" "1.2 consensus_reached is false"
check_json_field "$result" "total_rounds" "2" "1.3 Total rounds counted correctly"
check_json_field "$result" "codex_proposal.position" "Still microservices" "1.4 Codex final proposal captured"
check_json_field "$result" "claude_proposal.position" "Still monolith" "1.5 Claude final proposal captured"
check_json_field "$result" "codex_proposal.confidence" "0.75" "1.6 Codex confidence captured"
check_json_field "$result" "claude_proposal.confidence" "0.78" "1.7 Claude confidence captured"

echo ""

# ---------------------------------------------------------------------------
# Test 2: Consensus detection (should NOT return non-consensus)
# ---------------------------------------------------------------------------
echo "--- Test Group 2: Consensus correctly identified ---"

CONSENSUS_ROUNDS='[
  {"round":1,"codex":{"position":"Use REST","confidence":0.8,"key_arguments":["Simple"],"agrees_with_opponent":false},"claude":{"position":"Use GraphQL","confidence":0.7,"key_arguments":["Flexible"],"agrees_with_opponent":false}},
  {"round":2,"codex":{"position":"REST with OpenAPI","confidence":0.85,"key_arguments":["Best of both"],"agrees_with_opponent":true},"claude":{"position":"Agreed","confidence":0.85,"key_arguments":["Practical"],"agrees_with_opponent":true}}
]'

result=$(bash -c 'source scripts/detect-non-consensus.sh 2>/dev/null; detect_non_consensus "$0" "$1"' "$CONSENSUS_ROUNDS" "API Design" 2>/dev/null)

check_json_field "$result" "consensus_state" "consensus" "2.1 Detects consensus state"
check_json_field "$result" "consensus_reached" "true" "2.2 consensus_reached is true"
check_json_field "$result" "consensus_round" "2" "2.3 Consensus round identified"

echo ""

# ---------------------------------------------------------------------------
# Test 3: Codex-only consensus (one side agrees)
# ---------------------------------------------------------------------------
echo "--- Test Group 3: One-sided agreement detection ---"

ONE_SIDED='[
  {"round":1,"codex":{"position":"A","confidence":0.8,"key_arguments":["X"],"agrees_with_opponent":false},"claude":{"position":"B","confidence":0.7,"key_arguments":["Y"],"agrees_with_opponent":false}},
  {"round":2,"codex":{"position":"A revised","confidence":0.6,"key_arguments":["Z"],"agrees_with_opponent":true},"claude":{"position":"B still","confidence":0.75,"key_arguments":["W"],"agrees_with_opponent":false}}
]'

result=$(bash -c 'source scripts/detect-non-consensus.sh 2>/dev/null; detect_non_consensus "$0" "$1"' "$ONE_SIDED" "Test" 2>/dev/null)

check_json_field "$result" "consensus_state" "consensus" "3.1 One-sided agreement counts as consensus"

echo ""

# ---------------------------------------------------------------------------
# Test 4: Divergence score and convergence trend
# ---------------------------------------------------------------------------
echo "--- Test Group 4: Divergence metrics ---"

DIVERGING_ROUNDS='[
  {"round":1,"codex":{"position":"A","confidence":0.5,"key_arguments":["X"],"agrees_with_opponent":false},"claude":{"position":"B","confidence":0.5,"key_arguments":["Y"],"agrees_with_opponent":false}},
  {"round":2,"codex":{"position":"A++","confidence":0.9,"key_arguments":["X+"],"agrees_with_opponent":false},"claude":{"position":"B++","confidence":0.3,"key_arguments":["Y+"],"agrees_with_opponent":false}}
]'

result=$(bash -c 'source scripts/detect-non-consensus.sh 2>/dev/null; detect_non_consensus "$0" "$1"' "$DIVERGING_ROUNDS" "Diverge test" 2>/dev/null)

check_json_field "$result" "convergence_trend" "diverging" "4.1 Diverging trend detected when confidence gap widens"
check_json_field "$result" "consensus_state" "non-consensus" "4.2 Diverging rounds produce non-consensus"

# Verify divergence score is present and numeric
div_score=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print('ok' if 0 <= d.get('divergence_score',0) <= 1 else 'bad')" "$result" 2>/dev/null)
if [[ "$div_score" == "ok" ]]; then
  pass "4.3 Divergence score in valid range [0.0, 1.0]"
else
  fail "4.3 Divergence score out of range"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 5: Both proposals include key_arguments
# ---------------------------------------------------------------------------
echo "--- Test Group 5: Both proposals have key arguments ---"

result=$(bash -c 'source scripts/detect-non-consensus.sh 2>/dev/null; detect_non_consensus "$0" "$1"' "$NON_CONSENSUS_ROUNDS" "Args test" 2>/dev/null)

codex_args=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get('codex_proposal',{}).get('key_arguments',[])))" "$result" 2>/dev/null)
claude_args=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get('claude_proposal',{}).get('key_arguments',[])))" "$result" 2>/dev/null)

if [[ "$codex_args" -gt 0 ]]; then
  pass "5.1 Codex proposal has key arguments ($codex_args)"
else
  fail "5.1 Codex proposal missing key arguments"
fi

if [[ "$claude_args" -gt 0 ]]; then
  pass "5.2 Claude proposal has key arguments ($claude_args)"
else
  fail "5.2 Claude proposal missing key arguments"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 6: JSONL fixture parsing
# ---------------------------------------------------------------------------
echo "--- Test Group 6: JSONL fixture parsing ---"

result=$(bash -c 'source scripts/detect-non-consensus.sh 2>/dev/null; detect_non_consensus_from_jsonl "$0" "$1"' "tests/fixtures/debate-non-consensus.jsonl" "JSONL test" 2>/dev/null)

check_json_field "$result" "consensus_state" "non-consensus" "6.1 Non-consensus JSONL fixture detected correctly"
check_json_field "$result" "total_rounds" "3" "6.2 All 3 rounds parsed from JSONL"

# Consensus fixture should be detected as consensus
result=$(bash -c 'source scripts/detect-non-consensus.sh 2>/dev/null; detect_non_consensus_from_jsonl "$0" "$1"' "tests/fixtures/debate-consensus.jsonl" "Consensus JSONL" 2>/dev/null)

check_json_field "$result" "consensus_state" "consensus" "6.3 Consensus JSONL fixture detected as consensus"

echo ""

# ---------------------------------------------------------------------------
# Test 7: Edge cases
# ---------------------------------------------------------------------------
echo "--- Test Group 7: Edge cases ---"

# Empty rounds
result=$(bash -c 'source scripts/detect-non-consensus.sh 2>/dev/null; detect_non_consensus "[]" "Empty"' 2>/dev/null)
check_json_field "$result" "consensus_state" "unknown" "7.1 Empty rounds return unknown state"

# Single round non-consensus
SINGLE='[{"round":1,"codex":{"position":"A","confidence":0.8,"key_arguments":["X"],"agrees_with_opponent":false},"claude":{"position":"B","confidence":0.7,"key_arguments":["Y"],"agrees_with_opponent":false}}]'
result=$(bash -c 'source scripts/detect-non-consensus.sh 2>/dev/null; detect_non_consensus "$0" "$1"' "$SINGLE" "Single" 2>/dev/null)
check_json_field "$result" "consensus_state" "non-consensus" "7.2 Single round without agreement is non-consensus"
check_json_field "$result" "total_rounds" "1" "7.3 Single round count correct"

# is_non_consensus function
bash -c '
source scripts/detect-non-consensus.sh 2>/dev/null
rounds='"'"'[{"round":1,"codex":{"position":"A","confidence":0.8,"agrees_with_opponent":false},"claude":{"position":"B","confidence":0.7,"agrees_with_opponent":false}}]'"'"'
if is_non_consensus "$rounds"; then exit 0; else exit 1; fi
' 2>/dev/null
if [[ $? -eq 0 ]]; then
  pass "7.4 is_non_consensus returns 0 for non-consensus"
else
  fail "7.4 is_non_consensus should return 0 for non-consensus"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 8: Round positions array
# ---------------------------------------------------------------------------
echo "--- Test Group 8: Round positions tracking ---"

result=$(bash -c 'source scripts/detect-non-consensus.sh 2>/dev/null; detect_non_consensus "$0" "$1"' "$NON_CONSENSUS_ROUNDS" "Positions" 2>/dev/null)

rp_count=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d.get('round_positions',[])))" "$result" 2>/dev/null)
if [[ "$rp_count" -eq 2 ]]; then
  pass "8.1 Round positions array has correct count ($rp_count)"
else
  fail "8.1 Round positions count wrong (expected 2, got $rp_count)"
fi

check_json_field "$result" "round_positions.0.round" "1" "8.2 First round position has round number"
check_json_field "$result" "round_positions.0.codex_confidence" "0.85" "8.3 Round 1 codex confidence tracked"

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== Results ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [[ "$FAIL" -gt 0 ]]; then
  echo "❌ Some tests failed!"
  exit 1
else
  echo "✅ All tests passed!"
  exit 0
fi
