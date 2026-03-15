#!/usr/bin/env bash
# test-session-auto-create.sh — Tests for session auto-creation logic
#
# Validates that /debate, /evaluate, /ask auto-create session from config
# defaults when no active session exists.
#
# Usage: ./tests/test-session-auto-create.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
TOTAL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}✓${NC} $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $label"
    echo -e "    expected: ${YELLOW}${expected}${NC}"
    echo -e "    actual:   ${YELLOW}${actual}${NC}"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$actual" == *"$expected"* ]]; then
    echo -e "  ${GREEN}✓${NC} $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $label"
    echo -e "    expected to contain: ${YELLOW}${expected}${NC}"
    echo -e "    actual:              ${YELLOW}${actual}${NC}"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [[ -f "$path" ]]; then
    echo -e "  ${GREEN}✓${NC} $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $label (file not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Setup: use a temp directory for sessions to avoid polluting real data
# ---------------------------------------------------------------------------
ORIGINAL_HOME="$HOME"
TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude"

# Use a fake project root
FAKE_PROJECT=$(mktemp -d)
mkdir -p "$FAKE_PROJECT/.codex-collab"

cleanup() {
  export HOME="$ORIGINAL_HOME"
  rm -rf "$TEST_HOME" "$FAKE_PROJECT"
}
trap cleanup EXIT

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║    test-session-auto-create.sh — Session Auto-Creation      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ---------------------------------------------------------------------------
# Test 1: ensure_session creates session when none exists (auto_create=true)
# ---------------------------------------------------------------------------
echo "── Test 1: Auto-create session when none exists ──"

cd "$FAKE_PROJECT"
export CODEX_PROJECT_ROOT="$FAKE_PROJECT"
export CODEX_CONFIG_LOADED=0

# Source the script
source "$PROJECT_ROOT/scripts/session-auto-create.sh"

# Run ensure_session and capture output via temp file (avoid subshell losing exports)
_test_outfile=$(mktemp)
ensure_session "$FAKE_PROJECT" > "$_test_outfile" 2>&1
exit_code=$?
output=$(cat "$_test_outfile")
rm -f "$_test_outfile"

assert_eq "ensure_session exits 0" "0" "$exit_code"
assert_contains "Output contains auto-creation message" "세션 자동 생성" "$output"
assert_eq "SESSION_AUTO_CREATED is true" "true" "${SESSION_AUTO_CREATED:-}"
assert_contains "SESSION_ID starts with codex-" "codex-" "${SESSION_ID:-}"
assert_contains "SESSION_NAME starts with auto-" "auto-" "${SESSION_NAME:-}"
assert_file_exists "Session JSON file created" "${SESSION_FILE:-/nonexistent}"

# Verify JSON content
if [[ -f "${SESSION_FILE:-}" ]]; then
  session_status=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['status'])")
  session_auto=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['auto_created'])")
  session_project=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['project'])")

  assert_eq "Session status is active" "active" "$session_status"
  assert_eq "auto_created is True" "True" "$session_auto"
  assert_eq "Project path matches" "$FAKE_PROJECT" "$session_project"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 2: ensure_session finds existing session (no duplicate creation)
# ---------------------------------------------------------------------------
echo "── Test 2: Find existing session (no duplicate) ──"

export CODEX_CONFIG_LOADED=0
prev_session_id="${SESSION_ID:-}"

source "$PROJECT_ROOT/scripts/session-auto-create.sh"
_test_outfile=$(mktemp)
ensure_session "$FAKE_PROJECT" > "$_test_outfile" 2>&1
exit_code2=$?
rm -f "$_test_outfile"

assert_eq "ensure_session exits 0" "0" "$exit_code2"
assert_eq "SESSION_ID matches previous" "$prev_session_id" "${SESSION_ID:-}"
assert_eq "SESSION_AUTO_CREATED is false (pre-existing)" "false" "${SESSION_AUTO_CREATED:-}"

echo ""

# ---------------------------------------------------------------------------
# Test 3: auto_create=false blocks session creation
# ---------------------------------------------------------------------------
echo "── Test 3: auto_create=false blocks creation ──"

# Clean up previous session
rm -f "$TEST_HOME/.claude/codex-sessions"/*.json

# Create project config with auto_create: false
cat > "$FAKE_PROJECT/.codex-collab/config.yaml" <<'EOF'
session:
  auto_create: false
EOF

export CODEX_CONFIG_LOADED=0
export CODEX_PROJECT_ROOT="$FAKE_PROJECT"

source "$PROJECT_ROOT/scripts/session-auto-create.sh"
_test_outfile=$(mktemp)
ensure_session "$FAKE_PROJECT" > "$_test_outfile" 2>&1 || exit_code3=$?
exit_code3=${exit_code3:-0}
output3=$(cat "$_test_outfile")
rm -f "$_test_outfile"

assert_eq "ensure_session exits 1 (blocked)" "1" "$exit_code3"
assert_contains "Output contains session start guide" "/codex-session start" "$output3"

echo ""

# ---------------------------------------------------------------------------
# Test 4: Custom auto_name_prefix from config
# ---------------------------------------------------------------------------
echo "── Test 4: Custom auto_name_prefix from config ──"

# Clean up previous sessions
rm -f "$TEST_HOME/.claude/codex-sessions"/*.json

# Set custom prefix
cat > "$FAKE_PROJECT/.codex-collab/config.yaml" <<'EOF'
session:
  auto_create: true
  auto_name_prefix: "my-project"
EOF

export CODEX_CONFIG_LOADED=0
export CODEX_PROJECT_ROOT="$FAKE_PROJECT"

source "$PROJECT_ROOT/scripts/session-auto-create.sh"
_test_outfile=$(mktemp)
ensure_session "$FAKE_PROJECT" > "$_test_outfile" 2>&1
exit_code4=$?
rm -f "$_test_outfile"

assert_eq "ensure_session exits 0" "0" "$exit_code4"
assert_contains "SESSION_NAME uses custom prefix" "my-project-" "${SESSION_NAME:-}"
assert_eq "SESSION_AUTO_CREATED is true" "true" "${SESSION_AUTO_CREATED:-}"

echo ""

# ---------------------------------------------------------------------------
# Test 5: find_active_session returns 1 when no sessions dir exists
# ---------------------------------------------------------------------------
echo "── Test 5: No sessions directory ──"

rm -rf "$TEST_HOME/.claude/codex-sessions"

source "$PROJECT_ROOT/scripts/session-auto-create.sh"
find_active_session "$FAKE_PROJECT" 2>/dev/null || exit_code5=$?
exit_code5=${exit_code5:-0}

assert_eq "find_active_session returns 1" "1" "$exit_code5"

echo ""

# ---------------------------------------------------------------------------
# Test 6: Session JSON schema integrity
# ---------------------------------------------------------------------------
echo "── Test 6: Session JSON schema integrity ──"

# Clean up previous sessions
rm -f "$TEST_HOME/.claude/codex-sessions"/*.json

export CODEX_CONFIG_LOADED=0
cat > "$FAKE_PROJECT/.codex-collab/config.yaml" <<'EOF'
session:
  auto_create: true
  auto_name_prefix: "test"
EOF

source "$PROJECT_ROOT/scripts/session-auto-create.sh"
ensure_session "$FAKE_PROJECT" >/dev/null 2>&1

if [[ -f "${SESSION_FILE:-}" ]]; then
  # Verify all required fields exist
  has_all_fields=$(python3 -c "
import json
with open('$SESSION_FILE') as f:
    d = json.load(f)
required = ['id', 'name', 'project', 'auto_created', 'codex_session_id', 'created_at', 'ended_at', 'status', 'history']
missing = [k for k in required if k not in d]
print('true' if not missing else 'missing: ' + ', '.join(missing))
")
  assert_eq "All required fields present" "true" "$has_all_fields"

  ended_at=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['ended_at'])")
  assert_eq "ended_at is None" "None" "$ended_at"

  codex_sid=$(python3 -c "import json; print(json.load(open('$SESSION_FILE'))['codex_session_id'])")
  assert_eq "codex_session_id is None" "None" "$codex_sid"

  history=$(python3 -c "import json; print(len(json.load(open('$SESSION_FILE'))['history']))")
  assert_eq "history is empty array" "0" "$history"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 7: CLI mode (direct execution)
# ---------------------------------------------------------------------------
echo "── Test 7: CLI mode (direct execution) ──"

rm -f "$TEST_HOME/.claude/codex-sessions"/*.json
cat > "$FAKE_PROJECT/.codex-collab/config.yaml" <<'EOF'
session:
  auto_create: true
EOF

export CODEX_CONFIG_LOADED=0
cli_output=$(bash "$PROJECT_ROOT/scripts/session-auto-create.sh" --project-root "$FAKE_PROJECT" 2>&1)
cli_exit=$?

assert_eq "CLI mode exits 0" "0" "$cli_exit"
assert_contains "CLI output contains auto-creation message" "세션 자동 생성" "$cli_output"

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "════════════════════════════════════════════════════════════════"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${TOTAL} total"
echo "════════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
