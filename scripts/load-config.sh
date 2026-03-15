#!/usr/bin/env bash
# load-config.sh — codex-collab 2-tier config loader utility
#
# Loads configuration from YAML files with 2-tier hierarchy:
#   1. Global:  ~/.claude/codex-collab-config.yaml
#   2. Project: .codex-collab/config.yaml (overrides global)
#
# Usage:
#   # Source for shell functions:
#   source scripts/load-config.sh
#   load_config                    # loads merged config into CODEX_CONFIG_* vars
#   config_get "debate.max_rounds" # returns a specific value
#
#   # Or run directly for JSON output:
#   ./scripts/load-config.sh [--project-root <dir>] [--key <dotted.key>]
#
# Environment variables set after load_config:
#   CODEX_CONFIG_LOADED=1          — config was loaded successfully
#   CODEX_CONFIG_JSON              — full merged config as JSON string
#   CODEX_CONFIG_SOURCE            — "global+project" | "global" | "project" | "defaults"
#
# Exit codes:
#   0 — config loaded (possibly from defaults)
#   1 — fatal error (no python3 available)

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CODEX_GLOBAL_CONFIG="${CODEX_GLOBAL_CONFIG:-$HOME/.claude/codex-collab-config.yaml}"
CODEX_PROJECT_ROOT="${CODEX_PROJECT_ROOT:-$(pwd)}"
CODEX_PROJECT_CONFIG="${CODEX_PROJECT_ROOT}/.codex-collab/config.yaml"

# ---------------------------------------------------------------------------
# Default config (embedded YAML as heredoc for python parsing)
# ---------------------------------------------------------------------------
CODEX_DEFAULT_CONFIG_YAML=$(cat <<'DEFAULTS'
session:
  auto_create: true
  auto_name_prefix: "auto"
debate:
  default_rounds: 3
  max_additional_rounds: 2
  auto_apply_result: false
safety:
  auto_trigger_hooks: true
  require_approval: true
  block_dangerous_mode: true
status:
  auto_summary: true
  auto_save: true
  summary_format: "compact"
  verbosity: "normal"
  max_lines: 20
rules:
  max_cascade_depth: 3
  enabled: true
codex:
  binary_path: "codex"
  default_model: "gpt-5.4"
  timeout_seconds: 120
DEFAULTS
)

# ---------------------------------------------------------------------------
# Python helper — parses YAML files and merges with hierarchy
# ---------------------------------------------------------------------------
_config_python_merge() {
  local global_path="$1"
  local project_path="$2"
  local defaults_yaml="$3"
  local query_key="${4:-}"

  python3 - "$global_path" "$project_path" "$query_key" <<'PYEOF'
import sys
import json
import os

# ---------------------------------------------------------------------------
# Minimal YAML parser (no external dependencies)
# Handles the subset of YAML used in codex-collab configs:
#   - key: value pairs
#   - nested maps (indentation-based)
#   - string, int, float, bool values
#   - comments (#)
# Does NOT handle: anchors, aliases, multi-line strings, flow syntax, sequences
# ---------------------------------------------------------------------------

def parse_yaml_simple(text):
    """Parse a simple YAML string into a nested dict."""
    result = {}
    stack = [(result, -1)]  # (current_dict, indent_level)

    for line in text.splitlines():
        # Skip empty lines and comments
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue

        # Calculate indentation
        indent = len(line) - len(line.lstrip())

        # Pop stack to find parent at correct indentation
        while len(stack) > 1 and stack[-1][1] >= indent:
            stack.pop()

        parent_dict = stack[-1][0]

        # Parse key: value
        if ':' not in stripped:
            continue

        colon_idx = stripped.index(':')
        key = stripped[:colon_idx].strip().strip('"').strip("'")
        value_str = stripped[colon_idx + 1:].strip()

        if not value_str:
            # Nested map — value will be filled by subsequent lines
            new_dict = {}
            parent_dict[key] = new_dict
            stack.append((new_dict, indent))
        else:
            # Scalar value — parse type
            parent_dict[key] = parse_scalar(value_str)

    return result


def parse_scalar(value_str):
    """Parse a YAML scalar value string into a Python type."""
    # Remove inline comments
    if ' #' in value_str:
        value_str = value_str[:value_str.index(' #')].strip()

    # Remove quotes
    if (value_str.startswith('"') and value_str.endswith('"')) or \
       (value_str.startswith("'") and value_str.endswith("'")):
        return value_str[1:-1]

    # Boolean
    if value_str.lower() in ('true', 'yes', 'on'):
        return True
    if value_str.lower() in ('false', 'no', 'off'):
        return False

    # Null
    if value_str.lower() in ('null', '~', ''):
        return None

    # Number
    try:
        if '.' in value_str:
            return float(value_str)
        return int(value_str)
    except ValueError:
        pass

    return value_str


def deep_merge(base, override):
    """Deep merge override dict into base dict. Override wins for scalars."""
    merged = dict(base)
    for key, value in override.items():
        if key in merged and isinstance(merged[key], dict) and isinstance(value, dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = value
    return merged


def read_yaml_file(path):
    """Read and parse a YAML file. Returns (dict, error_string_or_None)."""
    if not os.path.isfile(path):
        return None, "not_found"
    try:
        with open(path, 'r', encoding='utf-8') as f:
            content = f.read()
        if not content.strip():
            return None, "empty"
        parsed = parse_yaml_simple(content)
        if not isinstance(parsed, dict):
            return None, "malformed"
        return parsed, None
    except Exception as e:
        return None, str(e)


def get_nested(d, dotted_key):
    """Get a value from a nested dict using dotted key notation."""
    keys = dotted_key.split('.')
    current = d
    for k in keys:
        if not isinstance(current, dict) or k not in current:
            return None
        current = current[k]
    return current


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
global_path = sys.argv[1]
project_path = sys.argv[2]
query_key = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else None

# Parse defaults (embedded in env var)
defaults_yaml = os.environ.get('CODEX_DEFAULT_CONFIG_YAML', '')
defaults = parse_yaml_simple(defaults_yaml) if defaults_yaml else {}

# Load global config
global_config, global_err = read_yaml_file(global_path)
# Load project config
project_config, project_err = read_yaml_file(project_path)

# Build source indicator
sources = []
if global_config is not None:
    sources.append("global")
if project_config is not None:
    sources.append("project")

# Merge: defaults ← global ← project
merged = dict(defaults)
if global_config is not None:
    merged = deep_merge(merged, global_config)
if project_config is not None:
    merged = deep_merge(merged, project_config)

source_str = "+".join(sources) if sources else "defaults"

# Enforce safety invariants that cannot be overridden
if "safety" in merged:
    merged["safety"]["require_approval"] = True  # ALWAYS require approval
if "debate" in merged:
    mar = merged["debate"].get("max_additional_rounds", 2)
    merged["debate"]["max_additional_rounds"] = min(max(int(mar), 0), 2)
if "rules" in merged:
    mcd = merged["rules"].get("max_cascade_depth", 3)
    merged["rules"]["max_cascade_depth"] = min(max(int(mcd), 1), 3)

# Build output
output = {
    "_meta": {
        "source": source_str,
        "global_path": global_path,
        "project_path": project_path,
        "global_status": "loaded" if global_config is not None else (global_err or "not_found"),
        "project_status": "loaded" if project_config is not None else (project_err or "not_found"),
    },
    "config": merged
}

if query_key:
    value = get_nested(merged, query_key)
    print(json.dumps(value) if value is not None else "null")
else:
    print(json.dumps(output, indent=2, ensure_ascii=False))

PYEOF
}

# ---------------------------------------------------------------------------
# Shell API functions
# ---------------------------------------------------------------------------

load_config() {
  local project_root_arg="${1:-$CODEX_PROJECT_ROOT}"

  # Skip if config already loaded for the SAME project (performance optimization)
  if [[ "${CODEX_CONFIG_LOADED:-0}" == "1" && -n "${CODEX_CONFIG_JSON:-}" && "${CODEX_CONFIG_CACHE_KEY:-}" == "$project_root_arg" ]]; then
    return 0
  fi

  # Validate python3 is available
  if ! command -v python3 &>/dev/null; then
    echo "[codex-collab] WARNING: python3 not found — config loading requires python3." >&2
    echo "[codex-collab] Using hardcoded defaults. Install python3 to enable custom configuration." >&2
    echo "[codex-collab]   macOS: xcode-select --install  |  Linux: apt install python3" >&2
    export CODEX_CONFIG_LOADED=0
    export CODEX_CONFIG_SOURCE="defaults"
    export CODEX_CONFIG_JSON='{"session":{"auto_create":true,"auto_name_prefix":"auto"},"debate":{"default_rounds":3,"max_additional_rounds":2,"auto_apply_result":false},"safety":{"auto_trigger_hooks":true,"require_approval":true,"block_dangerous_mode":true},"status":{"auto_summary":true,"auto_save":true,"summary_format":"compact","verbosity":"normal","max_lines":20},"rules":{"max_cascade_depth":3,"enabled":true},"codex":{"binary_path":"codex","default_model":"gpt-5.4","timeout_seconds":120}}'
    return 0
  fi

  local project_root="${1:-$CODEX_PROJECT_ROOT}"
  local project_config="${project_root}/.codex-collab/config.yaml"

  export CODEX_DEFAULT_CONFIG_YAML
  local result
  result=$(_config_python_merge "$CODEX_GLOBAL_CONFIG" "$project_config" "$CODEX_DEFAULT_CONFIG_YAML" "")

  if [[ $? -ne 0 ]]; then
    echo "[codex-collab] WARNING: Config loading failed, using defaults" >&2
    export CODEX_CONFIG_LOADED=0
    export CODEX_CONFIG_SOURCE="defaults"
    export CODEX_CONFIG_JSON="{}"
    return 0
  fi

  export CODEX_CONFIG_LOADED=1
  export CODEX_CONFIG_SOURCE
  CODEX_CONFIG_SOURCE=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin)['_meta']['source'])" 2>/dev/null || echo "defaults")
  export CODEX_CONFIG_JSON
  CODEX_CONFIG_JSON=$(echo "$result" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['config']))" 2>/dev/null || echo "{}")
  export CODEX_CONFIG_CACHE_KEY="$project_root_arg"

  return 0
}

config_get() {
  # Get a specific config value by dotted key (e.g., "debate.max_rounds")
  local key="$1"
  local default_value="${2:-}"

  if ! command -v python3 &>/dev/null; then
    echo "[codex-collab] WARNING: python3 not found — returning default for '${key}'" >&2
    echo "$default_value"
    return 0
  fi

  # If config is already loaded, query from cached JSON
  if [[ "${CODEX_CONFIG_LOADED:-0}" == "1" && -n "${CODEX_CONFIG_JSON:-}" ]]; then
    local value
    value=$(echo "$CODEX_CONFIG_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
keys = '${key}'.split('.')
current = data
for k in keys:
    if not isinstance(current, dict) or k not in current:
        print('__NULL__')
        sys.exit(0)
    current = current[k]
if current is None:
    print('__NULL__')
else:
    print(current if not isinstance(current, bool) else str(current).lower())
" 2>/dev/null)
    if [[ "$value" == "__NULL__" || -z "$value" ]]; then
      echo "$default_value"
    else
      echo "$value"
    fi
    return 0
  fi

  # Config not loaded yet — do a one-shot query
  local project_root="${CODEX_PROJECT_ROOT:-$(pwd)}"
  local project_config="${project_root}/.codex-collab/config.yaml"

  export CODEX_DEFAULT_CONFIG_YAML
  local value
  value=$(_config_python_merge "$CODEX_GLOBAL_CONFIG" "$project_config" "$CODEX_DEFAULT_CONFIG_YAML" "$key" 2>/dev/null)

  if [[ $? -ne 0 || "$value" == "null" || -z "$value" ]]; then
    echo "$default_value"
  else
    # Strip JSON quotes if present
    value="${value//\"/}"
    echo "$value"
  fi
  return 0
}

config_dump() {
  # Dump full merged config as formatted JSON
  if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
    load_config
  fi
  echo "$CODEX_CONFIG_JSON" | python3 -m json.tool 2>/dev/null || echo "$CODEX_CONFIG_JSON"
}

# ---------------------------------------------------------------------------
# CLI mode — run directly for JSON output
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Script is being executed directly (not sourced)
  PROJECT_ROOT="$(pwd)"
  QUERY_KEY=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-root) PROJECT_ROOT="$2"; shift 2 ;;
      --key)          QUERY_KEY="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: load-config.sh [--project-root <dir>] [--key <dotted.key>]"
        echo ""
        echo "Loads codex-collab config with 2-tier hierarchy:"
        echo "  Global:  ~/.claude/codex-collab-config.yaml"
        echo "  Project: <project-root>/.codex-collab/config.yaml"
        echo ""
        echo "Options:"
        echo "  --project-root <dir>   Project root directory (default: cwd)"
        echo "  --key <key>            Get specific value (e.g., debate.max_rounds)"
        echo "  --help, -h             Show this help"
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  CODEX_PROJECT_ROOT="$PROJECT_ROOT"
  CODEX_PROJECT_CONFIG="${PROJECT_ROOT}/.codex-collab/config.yaml"

  if ! command -v python3 &>/dev/null; then
    echo "[codex-collab] WARNING: python3 not found — config loading requires python3." >&2
    echo "[codex-collab] Using hardcoded defaults. Install python3 to enable custom configuration." >&2
    echo "[codex-collab]   macOS: xcode-select --install  |  Linux: apt install python3" >&2
    echo '{"_meta":{"source":"defaults","global_status":"skipped","project_status":"skipped"},"config":{"session":{"auto_create":true,"auto_name_prefix":"auto"},"debate":{"default_rounds":3,"max_additional_rounds":2},"safety":{"require_approval":true,"block_dangerous_mode":true},"status":{"auto_summary":true,"verbosity":"normal","max_lines":20},"rules":{"max_cascade_depth":3,"enabled":true},"codex":{"binary_path":"codex","default_model":"gpt-5.4","timeout_seconds":120}}}'
    exit 0
  fi

  export CODEX_DEFAULT_CONFIG_YAML
  _config_python_merge "$CODEX_GLOBAL_CONFIG" "$CODEX_PROJECT_CONFIG" "$CODEX_DEFAULT_CONFIG_YAML" "$QUERY_KEY"
fi
