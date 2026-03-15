#!/usr/bin/env bash
# test-config-loader.sh — Unit tests for codex-collab 2-tier config hierarchy
#
# Tests the config loading logic:
#   1. Global-only config (~/.claude/codex-collab-config.yaml)
#   2. Project-only config (.codex-collab/config.yaml)
#   3. Both configs present (project overrides global)
#   4. Missing config files (falls back to schema defaults)
#   5. Malformed YAML files (graceful degradation)
#   6. Malformed project with valid global
#   7. Config with comments, empty lines, quoted values
#
# The config loader is implemented as a Python3 module that mirrors the 2-tier
# merge behavior: defaults ← global ← project (highest priority).
#
# Usage:
#   bash tests/test-config-loader.sh
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed

set -euo pipefail

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required to run config loader tests" >&2
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

# Run a Python test and check result
# Usage: run_test "label" "python_expression_returning_bool"
run_test() {
  local label="$1"
  local py_expr="$2"
  if python3 -c "$py_expr" 2>/dev/null; then
    ok "$label"
  else
    fail "$label"
  fi
}

# ---------------------------------------------------------------------------
# Test Setup — tmpdir + config loader module
# ---------------------------------------------------------------------------
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

GLOBAL_DIR="$TMPDIR_BASE/home/.claude"
PROJECT_DIR="$TMPDIR_BASE/project/.codex-collab"
mkdir -p "$GLOBAL_DIR" "$PROJECT_DIR"

GLOBAL_CONFIG="$GLOBAL_DIR/codex-collab-config.yaml"
PROJECT_CONFIG="$PROJECT_DIR/config.yaml"

# Write the config loader module to tmpdir
CONFIG_LOADER="$TMPDIR_BASE/config_loader.py"
cat > "$CONFIG_LOADER" <<'PYEOF'
"""
codex-collab 2-tier config loader.

Hierarchy: schema defaults <- global config <- project config (highest wins)
"""
import re
import sys
import os

# Schema defaults (from schemas/config.json)
DEFAULTS = {
    "session.auto_create": "true",
    "session.auto_name_prefix": "auto",
    "debate.default_rounds": "3",
    "debate.max_additional_rounds": "2",
    "debate.auto_apply_result": "false",
    "safety.auto_trigger_hooks": "true",
    "safety.require_approval": "true",
    "safety.block_dangerous_mode": "true",
    "status.auto_summary": "true",
    "status.summary_format": "compact",
    "status.verbosity": "normal",
    "status.max_lines": "20",
    "rules.max_cascade_depth": "3",
    "rules.enabled": "true",
    "codex.binary_path": "codex",
    "codex.default_model": "gpt-5.4",
    "codex.timeout_seconds": "120",
}


def parse_yaml_config(filepath):
    """Parse a simple YAML config file into a flat dotted-key dict.

    Supports:
      - Section headers (top-level keys ending with colon)
      - Indented key-value pairs under sections
      - Comments (lines starting with #)
      - Quoted values (single and double)
      - Top-level dotted keys (e.g., session.auto_create: true)

    Returns:
      tuple: (dict of key-value pairs, bool indicating parse success)
    """
    result = {}
    current_section = ""

    if not os.path.isfile(filepath):
        return result, False

    try:
        with open(filepath, "r", errors="replace") as f:
            lines = f.readlines()
    except Exception:
        return result, False

    for raw_line in lines:
        line = raw_line.rstrip("\n\r")

        # Skip empty lines and comments
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        # Remove inline comments (not inside quotes)
        if " #" in stripped and not (stripped.count('"') % 2) and not (stripped.count("'") % 2):
            stripped = stripped[:stripped.index(" #")].rstrip()

        # Section header: no leading whitespace, word followed by colon only
        section_match = re.match(r'^([a-zA-Z_]\w*):\s*$', line)
        if section_match:
            current_section = section_match.group(1)
            continue

        # Indented key-value under a section
        indent_match = re.match(r'^\s+([a-zA-Z_]\w*):\s+(.+)$', line)
        if indent_match and current_section:
            key = f"{current_section}.{indent_match.group(1)}"
            value = indent_match.group(2).strip()
            # Strip quotes
            if (value.startswith('"') and value.endswith('"')) or \
               (value.startswith("'") and value.endswith("'")):
                value = value[1:-1]
            result[key] = value
            continue

        # Top-level dotted key
        dotted_match = re.match(r'^([a-zA-Z_][\w.]*\w):\s+(.+)$', stripped)
        if dotted_match:
            key = dotted_match.group(1)
            value = dotted_match.group(2).strip()
            if (value.startswith('"') and value.endswith('"')) or \
               (value.startswith("'") and value.endswith("'")):
                value = value[1:-1]
            result[key] = value
            current_section = ""
            continue

    return result, True


def load_config(global_path, project_path):
    """Load and merge configs: defaults <- global <- project.

    Returns:
      tuple: (merged config dict, list of warnings)
    """
    merged = dict(DEFAULTS)
    warnings = []

    # Layer 1: global config
    if os.path.isfile(global_path):
        global_values, ok = parse_yaml_config(global_path)
        if ok:
            merged.update(global_values)
        else:
            warnings.append("global_config_unreadable")

    # Layer 2: project config (overrides global)
    if os.path.isfile(project_path):
        project_values, ok = parse_yaml_config(project_path)
        if ok:
            merged.update(project_values)
        else:
            warnings.append("project_config_unreadable")

    return merged, warnings
PYEOF

echo "=== codex-collab config loader unit tests ==="
echo ""

# ---------------------------------------------------------------------------
# Test 1: Global-only config
# ---------------------------------------------------------------------------
echo "[ 1/7 ] Global-only config"

cat > "$GLOBAL_CONFIG" <<'YAML'
# Global configuration
session:
  auto_create: false
  auto_name_prefix: global-sess

debate:
  default_rounds: 5
  auto_apply_result: true

codex:
  timeout_seconds: 300
YAML

rm -f "$PROJECT_CONFIG"

python3 - "$CONFIG_LOADER" "$GLOBAL_CONFIG" "$PROJECT_CONFIG" <<'PYTEST'
import sys
sys.path.insert(0, "/dev/null")  # no-op
exec(open(sys.argv[1]).read())  # load config_loader module

cfg, warnings = load_config(sys.argv[2], sys.argv[3])

assertions = [
    ("session.auto_create", "false"),
    ("session.auto_name_prefix", "global-sess"),
    ("debate.default_rounds", "5"),
    ("debate.auto_apply_result", "true"),
    ("codex.timeout_seconds", "300"),
    # Non-overridden keys keep defaults
    ("safety.require_approval", "true"),
    ("status.summary_format", "compact"),
    ("debate.max_additional_rounds", "2"),
]

fail_count = 0
for key, expected in assertions:
    actual = cfg.get(key, "<MISSING>")
    if actual == expected:
        print(f"  ✓ global: {key} = '{expected}'")
    else:
        print(f"  ✗ global: {key} — expected='{expected}', got='{actual}'", file=sys.stderr)
        fail_count += 1

sys.exit(1 if fail_count > 0 else 0)
PYTEST
RESULT=$?
if [[ $RESULT -eq 0 ]]; then
  ok "Global-only config: all assertions passed"
else
  fail "Global-only config: some assertions failed"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 2: Project-only config
# ---------------------------------------------------------------------------
echo "[ 2/7 ] Project-only config"

rm -f "$GLOBAL_CONFIG"
cat > "$PROJECT_CONFIG" <<'YAML'
# Project-specific overrides
session:
  auto_name_prefix: proj-sess

debate:
  default_rounds: 2
  max_additional_rounds: 1

status:
  summary_format: detailed

rules:
  max_cascade_depth: 2
YAML

python3 - "$CONFIG_LOADER" "$GLOBAL_CONFIG" "$PROJECT_CONFIG" <<'PYTEST'
import sys
exec(open(sys.argv[1]).read())

cfg, warnings = load_config(sys.argv[2], sys.argv[3])

assertions = [
    ("session.auto_name_prefix", "proj-sess"),
    ("debate.default_rounds", "2"),
    ("debate.max_additional_rounds", "1"),
    ("status.summary_format", "detailed"),
    ("rules.max_cascade_depth", "2"),
    # Defaults preserved
    ("session.auto_create", "true"),
    ("safety.block_dangerous_mode", "true"),
    ("codex.binary_path", "codex"),
]

fail_count = 0
for key, expected in assertions:
    actual = cfg.get(key, "<MISSING>")
    if actual == expected:
        print(f"  ✓ project: {key} = '{expected}'")
    else:
        print(f"  ✗ project: {key} — expected='{expected}', got='{actual}'", file=sys.stderr)
        fail_count += 1

sys.exit(1 if fail_count > 0 else 0)
PYTEST
RESULT=$?
if [[ $RESULT -eq 0 ]]; then
  ok "Project-only config: all assertions passed"
else
  fail "Project-only config: some assertions failed"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 3: Both configs — project overrides global
# ---------------------------------------------------------------------------
echo "[ 3/7 ] Both configs (project overrides global)"

cat > "$GLOBAL_CONFIG" <<'YAML'
session:
  auto_create: false
  auto_name_prefix: global-prefix

debate:
  default_rounds: 5
  auto_apply_result: true

status:
  auto_summary: false
  summary_format: detailed

codex:
  binary_path: /usr/local/bin/codex
  timeout_seconds: 300
YAML

cat > "$PROJECT_CONFIG" <<'YAML'
session:
  auto_name_prefix: project-prefix

debate:
  default_rounds: 4

codex:
  timeout_seconds: 60
YAML

python3 - "$CONFIG_LOADER" "$GLOBAL_CONFIG" "$PROJECT_CONFIG" <<'PYTEST'
import sys
exec(open(sys.argv[1]).read())

cfg, warnings = load_config(sys.argv[2], sys.argv[3])

assertions = [
    # Project overrides global
    ("session.auto_name_prefix", "project-prefix"),
    ("debate.default_rounds", "4"),
    ("codex.timeout_seconds", "60"),
    # Global values where project doesn't override
    ("session.auto_create", "false"),
    ("debate.auto_apply_result", "true"),
    ("status.auto_summary", "false"),
    ("status.summary_format", "detailed"),
    ("codex.binary_path", "/usr/local/bin/codex"),
    # Schema defaults where neither sets value
    ("safety.require_approval", "true"),
    ("rules.enabled", "true"),
]

fail_count = 0
for key, expected in assertions:
    actual = cfg.get(key, "<MISSING>")
    if actual == expected:
        print(f"  ✓ merge: {key} = '{expected}'")
    else:
        print(f"  ✗ merge: {key} — expected='{expected}', got='{actual}'", file=sys.stderr)
        fail_count += 1

sys.exit(1 if fail_count > 0 else 0)
PYTEST
RESULT=$?
if [[ $RESULT -eq 0 ]]; then
  ok "Both configs merge: all assertions passed"
else
  fail "Both configs merge: some assertions failed"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 4: No config files — all defaults
# ---------------------------------------------------------------------------
echo "[ 4/7 ] No config files — all defaults"

rm -f "$GLOBAL_CONFIG" "$PROJECT_CONFIG"

python3 - "$CONFIG_LOADER" "$GLOBAL_CONFIG" "$PROJECT_CONFIG" <<'PYTEST'
import sys
exec(open(sys.argv[1]).read())

cfg, warnings = load_config(sys.argv[2], sys.argv[3])

# Verify ALL defaults from schema
expected_defaults = {
    "session.auto_create": "true",
    "session.auto_name_prefix": "auto",
    "debate.default_rounds": "3",
    "debate.max_additional_rounds": "2",
    "debate.auto_apply_result": "false",
    "safety.auto_trigger_hooks": "true",
    "safety.require_approval": "true",
    "safety.block_dangerous_mode": "true",
    "status.auto_summary": "true",
    "status.summary_format": "compact",
    "status.verbosity": "normal",
    "status.max_lines": "20",
    "rules.max_cascade_depth": "3",
    "rules.enabled": "true",
    "codex.binary_path": "codex",
    "codex.default_model": "gpt-5.4",
    "codex.timeout_seconds": "120",
}

fail_count = 0
for key, expected in expected_defaults.items():
    actual = cfg.get(key, "<MISSING>")
    if actual == expected:
        print(f"  ✓ defaults: {key} = '{expected}'")
    else:
        print(f"  ✗ defaults: {key} — expected='{expected}', got='{actual}'", file=sys.stderr)
        fail_count += 1

# No warnings when files don't exist
if len(warnings) == 0:
    print("  ✓ defaults: no warnings emitted")
else:
    print(f"  ✗ defaults: unexpected warnings: {warnings}", file=sys.stderr)
    fail_count += 1

sys.exit(1 if fail_count > 0 else 0)
PYTEST
RESULT=$?
if [[ $RESULT -eq 0 ]]; then
  ok "No config files: all 15 defaults verified"
else
  fail "No config files: some defaults incorrect"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 5: Malformed global config — graceful degradation
# ---------------------------------------------------------------------------
echo "[ 5/7 ] Malformed global config — graceful degradation"

# Write binary-like content that won't parse as YAML
printf '\x00\x01INVALID{{{not::: yaml\n\ttabs\x00everywhere' > "$GLOBAL_CONFIG"
rm -f "$PROJECT_CONFIG"

python3 - "$CONFIG_LOADER" "$GLOBAL_CONFIG" "$PROJECT_CONFIG" <<'PYTEST'
import sys
exec(open(sys.argv[1]).read())

cfg, warnings = load_config(sys.argv[2], sys.argv[3])

# Should fall back to defaults since global file is malformed
assertions = [
    ("session.auto_create", "true"),
    ("debate.default_rounds", "3"),
    ("codex.binary_path", "codex"),
    ("safety.require_approval", "true"),
]

fail_count = 0
for key, expected in assertions:
    actual = cfg.get(key, "<MISSING>")
    if actual == expected:
        print(f"  ✓ malformed-global: {key} = '{expected}' (default)")
    else:
        print(f"  ✗ malformed-global: {key} — expected='{expected}', got='{actual}'", file=sys.stderr)
        fail_count += 1

sys.exit(1 if fail_count > 0 else 0)
PYTEST
RESULT=$?
if [[ $RESULT -eq 0 ]]; then
  ok "Malformed global config: graceful fallback to defaults"
else
  fail "Malformed global config: failed to fall back"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 6: Malformed project config — global + defaults preserved
# ---------------------------------------------------------------------------
echo "[ 6/7 ] Malformed project config — global + defaults preserved"

cat > "$GLOBAL_CONFIG" <<'YAML'
debate:
  default_rounds: 7
codex:
  timeout_seconds: 200
YAML

# Write garbled YAML for project config
cat > "$PROJECT_CONFIG" <<'YAML'
{{{{invalid yaml
  : broken : : : keys
  [unterminated array
YAML

python3 - "$CONFIG_LOADER" "$GLOBAL_CONFIG" "$PROJECT_CONFIG" <<'PYTEST'
import sys
exec(open(sys.argv[1]).read())

cfg, warnings = load_config(sys.argv[2], sys.argv[3])

assertions = [
    # Global values should be preserved
    ("debate.default_rounds", "7"),
    ("codex.timeout_seconds", "200"),
    # Defaults for everything else
    ("session.auto_create", "true"),
    ("safety.block_dangerous_mode", "true"),
]

fail_count = 0
for key, expected in assertions:
    actual = cfg.get(key, "<MISSING>")
    if actual == expected:
        print(f"  ✓ malformed-project: {key} = '{expected}'")
    else:
        print(f"  ✗ malformed-project: {key} — expected='{expected}', got='{actual}'", file=sys.stderr)
        fail_count += 1

sys.exit(1 if fail_count > 0 else 0)
PYTEST
RESULT=$?
if [[ $RESULT -eq 0 ]]; then
  ok "Malformed project config: global values and defaults preserved"
else
  fail "Malformed project config: merge failed"
fi

echo ""

# ---------------------------------------------------------------------------
# Test 7: Config with comments, empty lines, quoted values
# ---------------------------------------------------------------------------
echo "[ 7/7 ] Config with comments, empty lines, and quoted values"

cat > "$GLOBAL_CONFIG" <<'YAML'
# This is a full-line comment

session:
  # Disable auto-create for CI environments
  auto_create: false
  auto_name_prefix: "ci-build"

# Codex settings
codex:
  binary_path: '/opt/codex/bin/codex'
  default_model: "gpt-5.4-turbo"
YAML

rm -f "$PROJECT_CONFIG"

python3 - "$CONFIG_LOADER" "$GLOBAL_CONFIG" "$PROJECT_CONFIG" <<'PYTEST'
import sys
exec(open(sys.argv[1]).read())

cfg, warnings = load_config(sys.argv[2], sys.argv[3])

assertions = [
    ("session.auto_create", "false"),
    ("session.auto_name_prefix", "ci-build"),
    ("codex.binary_path", "/opt/codex/bin/codex"),
    ("codex.default_model", "gpt-5.4-turbo"),
    # Unset keys still default
    ("debate.default_rounds", "3"),
]

fail_count = 0
for key, expected in assertions:
    actual = cfg.get(key, "<MISSING>")
    if actual == expected:
        print(f"  ✓ comments: {key} = '{expected}'")
    else:
        print(f"  ✗ comments: {key} — expected='{expected}', got='{actual}'", file=sys.stderr)
        fail_count += 1

sys.exit(1 if fail_count > 0 else 0)
PYTEST
RESULT=$?
if [[ $RESULT -eq 0 ]]; then
  ok "Comments and quoted values: parsed correctly"
else
  fail "Comments and quoted values: parse failed"
fi

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
