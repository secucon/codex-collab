#!/usr/bin/env bash
# validate-plugin.sh — codex-collab plugin integrity validator
#
# Checks:
#   1. plugin.json exists and is valid JSON
#   2. All files/directories referenced in plugin.json exist
#   3. schemas/evaluation.json and schemas/debate.json are valid JSON
#      and contain required JSON-Schema fields
#   4. hooks/hooks.json is valid JSON and contains required hook keys
#
# Usage:
#   ./scripts/validate-plugin.sh [--plugin-root <dir>]
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
PASS=0
FAIL=0
ERRORS=()

ok()  { echo "  ✓ $*"; PASS=$((PASS + 1)); }
err() { echo "  ✗ $*" >&2; ERRORS+=("$*"); FAIL=$((FAIL + 1)); }

# Determine plugin root (default: directory containing this script's parent)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"

# Accept optional --plugin-root override
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plugin-root) PLUGIN_ROOT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "=== codex-collab plugin validator ==="
echo "Plugin root: $PLUGIN_ROOT"
echo ""

# ---------------------------------------------------------------------------
# Section 1: plugin.json — existence and JSON validity
# ---------------------------------------------------------------------------
echo "[ 1/4 ] plugin.json validity"

PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

if [[ ! -f "$PLUGIN_JSON" ]]; then
  err "plugin.json not found at: $PLUGIN_JSON"
else
  ok "plugin.json exists"

  if command -v python3 &>/dev/null; then
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PLUGIN_JSON" 2>/dev/null; then
      ok "plugin.json is valid JSON"
    else
      err "plugin.json is NOT valid JSON"
    fi
  elif command -v node &>/dev/null; then
    if node -e "JSON.parse(require('fs').readFileSync('$PLUGIN_JSON','utf8'))" 2>/dev/null; then
      ok "plugin.json is valid JSON (via node)"
    else
      err "plugin.json is NOT valid JSON"
    fi
  else
    err "No JSON parser available (need python3 or node)"
  fi
fi

echo ""

# ---------------------------------------------------------------------------
# Section 2: Referenced files/directories in plugin.json
# ---------------------------------------------------------------------------
echo "[ 2/4 ] Referenced files/directories existence"

if [[ -f "$PLUGIN_JSON" ]]; then
  # Extract agent file paths (lines containing "./agents/")
  AGENT_FILES=()
  while IFS= read -r line; do
    # Strip leading/trailing whitespace and quotes
    path="${line//\"/}"
    path="${path//,/}"
    path="${path// /}"
    AGENT_FILES+=("$path")
  done < <(grep -o '"\.\/agents\/[^"]*"' "$PLUGIN_JSON" | tr -d '"')

  for rel_path in "${AGENT_FILES[@]}"; do
    abs_path="$PLUGIN_ROOT/${rel_path#./}"
    if [[ -f "$abs_path" ]]; then
      ok "Agent file exists: $rel_path"
    else
      err "Agent file MISSING: $rel_path (expected at $abs_path)"
    fi
  done

  # Check commands directory
  if grep -q '"./commands/"' "$PLUGIN_JSON" || grep -q '"commands"' "$PLUGIN_JSON"; then
    COMMANDS_DIR="$PLUGIN_ROOT/commands"
    if [[ -d "$COMMANDS_DIR" ]]; then
      CMD_COUNT=$(find "$COMMANDS_DIR" -name "*.md" | wc -l | tr -d ' ')
      ok "commands/ directory exists ($CMD_COUNT .md files)"
    else
      err "commands/ directory MISSING: $COMMANDS_DIR"
    fi
  fi

  # Check skills directory
  if grep -q '"./skills/"' "$PLUGIN_JSON" || grep -q '"skills"' "$PLUGIN_JSON"; then
    SKILLS_DIR="$PLUGIN_ROOT/skills"
    if [[ -d "$SKILLS_DIR" ]]; then
      SKILL_COUNT=$(find "$SKILLS_DIR" -name "SKILL.md" | wc -l | tr -d ' ')
      ok "skills/ directory exists ($SKILL_COUNT SKILL.md files)"
    else
      err "skills/ directory MISSING: $SKILLS_DIR"
    fi
  fi
else
  err "Skipping file-reference checks (plugin.json not found)"
fi

echo ""

# ---------------------------------------------------------------------------
# Section 3: Schema files — existence, JSON validity, and required fields
# ---------------------------------------------------------------------------
echo "[ 3/4 ] Schema file validity"

SCHEMAS_DIR="$PLUGIN_ROOT/schemas"

check_schema() {
  local schema_name="$1"
  local schema_path="$SCHEMAS_DIR/$schema_name"
  local required_fields=("${@:2}")

  if [[ ! -f "$schema_path" ]]; then
    err "Schema file MISSING: schemas/$schema_name"
    return
  fi
  ok "Schema exists: schemas/$schema_name"

  # Validate JSON
  local parse_ok=0
  if command -v python3 &>/dev/null; then
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$schema_path" 2>/dev/null; then
      parse_ok=1
    fi
  elif command -v node &>/dev/null; then
    if node -e "JSON.parse(require('fs').readFileSync('$schema_path','utf8'))" 2>/dev/null; then
      parse_ok=1
    fi
  fi

  if [[ $parse_ok -eq 1 ]]; then
    ok "Schema is valid JSON: schemas/$schema_name"
  else
    err "Schema is NOT valid JSON: schemas/$schema_name"
    return
  fi

  # Check required top-level fields
  for field in "${required_fields[@]}"; do
    if grep -q "\"$field\"" "$schema_path"; then
      ok "Schema field present [$field]: schemas/$schema_name"
    else
      err "Schema field MISSING [$field]: schemas/$schema_name"
    fi
  done
}

check_schema "evaluation.json" "\$schema" "\$id" "title" "type" "properties" "required"
check_schema "debate.json"     "\$schema" "\$id" "title" "type" "properties" "required"

echo ""

# ---------------------------------------------------------------------------
# Section 4: hooks.json — existence, JSON validity, and required structure
# ---------------------------------------------------------------------------
echo "[ 4/4 ] hooks/hooks.json validity"

HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

if [[ ! -f "$HOOKS_JSON" ]]; then
  err "hooks.json not found at: $HOOKS_JSON"
else
  ok "hooks.json exists"

  # Validate JSON
  hooks_parse_ok=0
  if command -v python3 &>/dev/null; then
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$HOOKS_JSON" 2>/dev/null; then
      hooks_parse_ok=1
    fi
  elif command -v node &>/dev/null; then
    if node -e "JSON.parse(require('fs').readFileSync('$HOOKS_JSON','utf8'))" 2>/dev/null; then
      hooks_parse_ok=1
    fi
  fi

  if [[ $hooks_parse_ok -eq 1 ]]; then
    ok "hooks.json is valid JSON"
  else
    err "hooks.json is NOT valid JSON"
  fi

  # Verify required structural keys are present
  for key in "hooks" "PreToolUse" "description" "matcher" "command"; do
    if grep -q "\"$key\"" "$HOOKS_JSON"; then
      ok "hooks.json contains required key: $key"
    else
      err "hooks.json MISSING required key: $key"
    fi
  done

  # Count PreToolUse hooks (expect at least 4 per AC 3)
  if command -v python3 &>/dev/null && [[ $hooks_parse_ok -eq 1 ]]; then
    HOOK_COUNT=$(python3 - "$HOOKS_JSON" <<'EOF'
import json, sys
data = json.load(open(sys.argv[1]))
hooks = data.get("hooks", {}).get("PreToolUse", [])
print(len(hooks))
EOF
    )
    if [[ "$HOOK_COUNT" -ge 4 ]]; then
      ok "hooks.json has $HOOK_COUNT PreToolUse hooks (minimum 4 required)"
    else
      err "hooks.json only has $HOOK_COUNT PreToolUse hook(s); minimum 4 required"
    fi
  fi

  # Verify safety-critical hook patterns are present
  for pattern in "full-auto" "dangerously" "write\|--edit\|-w " "codex-session"; do
    if grep -qE "$pattern" "$HOOKS_JSON"; then
      ok "Safety hook pattern present: $pattern"
    else
      err "Safety hook pattern MISSING: $pattern"
    fi
  done
fi

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== Summary ==="
echo "Passed : $PASS"
echo "Failed : $FAIL"

if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo ""
  echo "Errors:"
  for e in "${ERRORS[@]}"; do
    echo "  - $e"
  done
fi

echo ""
if [[ $FAIL -gt 0 ]]; then
  echo "RESULT: FAIL ($FAIL check(s) failed)"
  exit 1
else
  echo "RESULT: PASS — all checks passed"
  exit 0
fi
