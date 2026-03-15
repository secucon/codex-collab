#!/usr/bin/env bash
# session-auto-create.sh — Auto-create a codex-collab session from config defaults
#
# Called by the workflow-orchestrator when a command (/codex-ask, /codex-evaluate,
# /codex-debate) is invoked without an active session and session.auto_create is true.
#
# Usage:
#   source scripts/session-auto-create.sh
#   ensure_session   # creates session if needed, sets SESSION_* vars
#
# Or run directly:
#   ./scripts/session-auto-create.sh [--project-root <dir>]
#
# Environment variables set on success:
#   SESSION_ID          — the session ID (e.g., codex-1710400000-a1b2)
#   SESSION_NAME        — the session name (e.g., auto-1710400000)
#   SESSION_FILE        — path to the session JSON file
#   SESSION_AUTO_CREATED — "true" if session was auto-created, "false" if pre-existing
#
# Exit codes:
#   0 — session available (existing or newly created)
#   1 — no session and auto_create is disabled
#   2 — session creation failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSIONS_DIR="${HOME}/.claude/codex-sessions"

# ---------------------------------------------------------------------------
# Source config loader
# ---------------------------------------------------------------------------
# shellcheck source=load-config.sh
source "${SCRIPT_DIR}/load-config.sh"

# ---------------------------------------------------------------------------
# find_active_session — look for an active session for the current project
# Returns 0 and sets SESSION_* vars if found, returns 1 if not found
# ---------------------------------------------------------------------------
find_active_session() {
  local project_root="${1:-$(pwd)}"

  if [[ ! -d "$SESSIONS_DIR" ]]; then
    return 1
  fi

  # Search for active session matching this project
  for session_file in "$SESSIONS_DIR"/*.json; do
    [[ -f "$session_file" ]] || continue

    local status project
    status=$(python3 -c "
import json, sys
with open('${session_file}') as f:
    d = json.load(f)
print(d.get('status', ''))
" 2>/dev/null || echo "")

    project=$(python3 -c "
import json, sys
with open('${session_file}') as f:
    d = json.load(f)
print(d.get('project', ''))
" 2>/dev/null || echo "")

    if [[ "$status" == "active" && "$project" == "$project_root" ]]; then
      SESSION_FILE="$session_file"
      SESSION_ID=$(python3 -c "
import json
with open('${session_file}') as f:
    print(json.load(f)['id'])
" 2>/dev/null)
      SESSION_NAME=$(python3 -c "
import json
with open('${session_file}') as f:
    print(json.load(f)['name'])
" 2>/dev/null)
      SESSION_AUTO_CREATED="false"
      export SESSION_ID SESSION_NAME SESSION_FILE SESSION_AUTO_CREATED
      return 0
    fi
  done

  return 1
}

# ---------------------------------------------------------------------------
# create_auto_session — create a new session from config defaults
# ---------------------------------------------------------------------------
create_auto_session() {
  local project_root="${1:-$(pwd)}"

  # Load config to get session defaults
  if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
    load_config "$project_root"
  fi

  local auto_name_prefix
  auto_name_prefix=$(config_get "session.auto_name_prefix" "auto")

  local timestamp
  timestamp=$(date +%s)

  local random_suffix
  random_suffix=$(head -c 2 /dev/urandom | xxd -p)

  SESSION_ID="codex-${timestamp}-${random_suffix}"
  SESSION_NAME="${auto_name_prefix}-${timestamp}"
  SESSION_FILE="${SESSIONS_DIR}/${SESSION_ID}.json"
  SESSION_AUTO_CREATED="true"

  # Create sessions directory if needed
  mkdir -p "$SESSIONS_DIR"

  # Write session JSON
  local created_at
  created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  python3 - "$SESSION_FILE" "$SESSION_ID" "$SESSION_NAME" "$project_root" "$created_at" <<'PYEOF'
import json, sys

session_file = sys.argv[1]
session = {
    "id": sys.argv[2],
    "name": sys.argv[3],
    "project": sys.argv[4],
    "auto_created": True,
    "codex_session_id": None,
    "created_at": sys.argv[5],
    "ended_at": None,
    "status": "active",
    "history": []
}

with open(session_file, 'w', encoding='utf-8') as f:
    json.dump(session, f, indent=2, ensure_ascii=False)
PYEOF

  if [[ $? -ne 0 ]]; then
    echo "[codex-collab] ERROR: Failed to create auto-session" >&2
    return 2
  fi

  export SESSION_ID SESSION_NAME SESSION_FILE SESSION_AUTO_CREATED
  echo "[codex-collab] 세션 자동 생성: ${SESSION_NAME} (ID: ${SESSION_ID})"
  return 0
}

# ---------------------------------------------------------------------------
# ensure_session — main entry point
# Finds existing session or auto-creates one based on config
# ---------------------------------------------------------------------------
ensure_session() {
  local project_root="${1:-$(pwd)}"

  # Try to find an existing active session
  if find_active_session "$project_root"; then
    return 0
  fi

  # No active session — check config for auto_create
  if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
    load_config "$project_root"
  fi

  local auto_create
  auto_create=$(config_get "session.auto_create" "true")

  if [[ "$auto_create" != "true" ]]; then
    echo "[codex-collab] 활성 세션이 없습니다. \`/codex-session start <이름>\`으로 시작하세요." >&2
    return 1
  fi

  # Auto-create a new session
  create_auto_session "$project_root"
  return $?
}

# ---------------------------------------------------------------------------
# CLI mode — run directly
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  PROJECT_ROOT="$(pwd)"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project-root) PROJECT_ROOT="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: session-auto-create.sh [--project-root <dir>]"
        echo ""
        echo "Auto-creates a codex-collab session if none exists and session.auto_create is true."
        echo ""
        echo "Options:"
        echo "  --project-root <dir>   Project root directory (default: cwd)"
        echo "  --help, -h             Show this help"
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  ensure_session "$PROJECT_ROOT"
fi
