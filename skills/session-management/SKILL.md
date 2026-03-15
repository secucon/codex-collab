---
name: session-management
description: Use when managing Codex collaboration sessions — creating, listing, ending, or deleting sessions. Provides session storage patterns, schema, and lifecycle logic.
---

# Session Management Guide

## Session Storage

All sessions are stored in `~/.claude/codex-sessions/` as individual JSON files.

```bash
SESSION_DIR="$HOME/.claude/codex-sessions"
mkdir -p "$SESSION_DIR"
```

## Session ID Generation

```bash
SESSION_ID="codex-$(date +%s)-$(head -c 2 /dev/urandom | xxd -p)"
```

## Session File Schema

```json
{
  "id": "codex-1710400000-a1b2",
  "name": "User-provided session name",
  "project": "/absolute/path/to/project",
  "branch": "main",
  "codex_session_id": null,
  "created_at": "2026-03-14T12:00:00Z",
  "ended_at": null,
  "status": "active",
  "history": [
    {
      "command": "codex-ask",
      "timestamp": "2026-03-14T12:01:00Z",
      "prompt_summary": "First 100 chars of prompt...",
      "mode": "read-only",
      "codex_response_summary": "First 200 chars of response...",
      "structured_result": null
    }
  ]
}
```

## Operations

### Create Session

```bash
SESSION_FILE="$SESSION_DIR/$SESSION_ID.json"
```

Write the session JSON with `status: "active"`, `project: "$(pwd)"`, `branch: "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"`.

### Find Active Session

```bash
# Find active session for current project AND branch
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
grep -l "\"status\": \"active\"" "$SESSION_DIR"/*.json 2>/dev/null | while read f; do
  if grep -q "\"project\": \"$(pwd)\"" "$f"; then
    # Check branch match (with backward compatibility for sessions without branch field)
    if grep -q "\"branch\": \"$CURRENT_BRANCH\"" "$f" || ! grep -q '"branch"' "$f"; then
      echo "$f"
    fi
  fi
done
```

Then use Read tool to load the session data.

### End Session

Update `status` to `"ended"` and set `ended_at` to current ISO 8601 timestamp.

### Delete Session

```bash
rm "$SESSION_DIR/<session-id>.json"
```

### List Sessions (current project only)

Read all `*.json` files, filter by `project == $(pwd)`, display as table.

## Active Session Index (Performance Optimization)

To avoid scanning all session files on every command, maintain an index file:

```bash
ACTIVE_INDEX="$SESSION_DIR/.active-sessions.json"
```

The index maps `project+branch` to session file path:

```json
{
  "/path/to/project::main": "codex-1710400000-a1b2.json",
  "/path/to/other::feature/auth": "codex-1710500000-c3d4.json"
}
```

### Index Maintenance
- **On session create**: Add entry `"${project}::${branch}": "${session_id}.json"`
- **On session end/delete**: Remove the corresponding entry
- **On lookup**: Read index first (O(1) lookup), fall back to full scan if index is missing or stale
- **Staleness check**: If indexed file doesn't exist or status != active, remove entry and fall back to scan
- **Atomic writes**: Always write to a temp file first, then rename (avoids corruption on concurrent access):
  ```bash
  # Safe index update pattern
  python3 -c "..." > "${ACTIVE_INDEX}.tmp" && mv "${ACTIVE_INDEX}.tmp" "$ACTIVE_INDEX"
  ```
- **Validation**: After reading from index, verify the session file's `status`, `project`, and `branch` match before returning

```bash
# Fast lookup via index
lookup_active_index() {
  local project="$1" branch="$2"
  local key="${project}::${branch}"
  if [[ -f "$ACTIVE_INDEX" ]]; then
    local session_file
    session_file=$(python3 -c "
import json, sys
with open('${ACTIVE_INDEX}') as f:
    idx = json.load(f)
print(idx.get('${key}', ''))
" 2>/dev/null)
    if [[ -n "$session_file" && -f "$SESSION_DIR/$session_file" ]]; then
      echo "$SESSION_DIR/$session_file"
      return 0
    fi
  fi
  return 1
}
```

## Codex Session ID Tracking

When `codex-delegator` invokes Codex CLI without `--ephemeral`, the CLI creates a persistent session. The session ID from Codex should be stored in `codex_session_id` for `resume`/`fork` operations.

## History Append

After each command execution, append a history entry to the session's `history` array using the Edit tool on the session JSON file.
