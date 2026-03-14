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

Write the session JSON with `status: "active"`, `project: "$(pwd)"`.

### Find Active Session

```bash
# Find active session for current project
grep -l "\"status\": \"active\"" "$SESSION_DIR"/*.json 2>/dev/null | while read f; do
  if grep -q "\"project\": \"$(pwd)\"" "$f"; then
    echo "$f"
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

## Codex Session ID Tracking

When `codex-delegator` invokes Codex CLI without `--ephemeral`, the CLI creates a persistent session. The session ID from Codex should be stored in `codex_session_id` for `resume`/`fork` operations.

## History Append

After each command execution, append a history entry to the session's `history` array using the Edit tool on the session JSON file.
