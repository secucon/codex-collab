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
  local current_branch
  current_branch=$(git -C "$project_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  local current_remote
  current_remote=$(git -C "$project_root" remote get-url origin 2>/dev/null | sed 's|[^@]*@||;s|\.git$||' || echo "")

  if [[ ! -d "$SESSIONS_DIR" ]]; then
    return 1
  fi

  # Staged lookup: exact match → legacy fallback → remote fallback
  local exact_match="" legacy_match="" remote_match=""

  for session_file in "$SESSIONS_DIR"/*.json; do
    [[ -f "$session_file" ]] || continue

    local match_result
    match_result=$(python3 - "$session_file" "$project_root" "$current_branch" "$current_remote" <<'PYEOF'
import json, sys

session_file = sys.argv[1]
project_root = sys.argv[2]
current_branch = sys.argv[3]
current_remote = sys.argv[4]

with open(session_file) as f:
    d = json.load(f)

if d.get('status') != 'active':
    sys.exit(1)

session_project = d.get('project', '')
session_branch = d.get('branch')
session_remote = d.get('git_remote', '')
# Sanitize stored remote (strip credentials)
if '@' in session_remote:
    session_remote = session_remote.split('@', 1)[1]
session_remote = session_remote.rstrip('.git')

result = {'id': d['id'], 'name': d['name'], 'match_type': 'none'}

if session_project == project_root:
    if session_branch is not None and session_branch == current_branch:
        result['match_type'] = 'exact'
    elif session_branch is None or session_branch == 'unknown':
        result['match_type'] = 'legacy'
elif current_remote and session_remote and session_remote == current_remote:
    if session_branch is None or session_branch == current_branch or session_branch == 'unknown':
        result['match_type'] = 'remote'

if result['match_type'] == 'none':
    sys.exit(1)

print(json.dumps(result))
PYEOF
    ) || continue

    local match_type
    match_type=$(echo "$match_result" | python3 -c "import json,sys; print(json.load(sys.stdin)['match_type'])")

    case "$match_type" in
      exact)  exact_match="$match_result|$session_file" ;;
      legacy) [[ -z "$legacy_match" ]] && legacy_match="$match_result|$session_file" ;;
      remote) [[ -z "$remote_match" ]] && remote_match="$match_result|$session_file" ;;
    esac

    # Early exit on exact match
    [[ -n "$exact_match" ]] && break
  done

  # Select best match: exact > legacy > remote
  local best_match="${exact_match:-${legacy_match:-${remote_match:-}}}"
  if [[ -z "$best_match" ]]; then
    return 1
  fi

  local match_json="${best_match%%|*}"
  SESSION_FILE="${best_match##*|}"
  SESSION_ID=$(echo "$match_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
  SESSION_NAME=$(echo "$match_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['name'])")
  SESSION_AUTO_CREATED="false"
  export SESSION_ID SESSION_NAME SESSION_FILE SESSION_AUTO_CREATED
  return 0
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

  local current_branch
  current_branch=$(git -C "$project_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  local git_remote
  # Sanitize remote URL: strip credentials (user:pass@) and trailing .git
  git_remote=$(git -C "$project_root" remote get-url origin 2>/dev/null | sed 's|://[^@]*@|://|;s|\.git$||' || echo "")

  python3 - "$SESSION_FILE" "$SESSION_ID" "$SESSION_NAME" "$project_root" "$created_at" "$current_branch" "$git_remote" <<'PYEOF'
import json, sys

session_file = sys.argv[1]
session = {
    "id": sys.argv[2],
    "name": sys.argv[3],
    "project": sys.argv[4],
    "branch": sys.argv[6],
    "git_remote": sys.argv[7] if len(sys.argv) > 7 else "",
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
