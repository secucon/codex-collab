#!/usr/bin/env bash
# status-summary.sh — codex-collab status summary generator (v2.1.0)
#
# Two modes of operation:
#   1. Session state summary — current session status, participants, recent actions
#   2. Command completion summary — post-command result summary
#
# Configuration (from 2-tier config hierarchy):
#   status.auto_summary:   enable/disable auto summary (default: true)
#   status.auto_save:      enable/disable auto-save to reports dir (default: true)
#   status.summary_format: "compact" or "detailed" (default: compact)
#   status.verbosity:      "minimal" | "normal" | "verbose" (default: normal)
#   status.max_lines:      1–100 (default: 20)
#
# Usage:
#   # Source for shell functions:
#   source scripts/status-summary.sh
#   generate_status_summary          # session state summary
#   generate_command_summary "codex-debate" '{"rounds":3}' "sess-id"
#
#   # Or run directly:
#   ./scripts/status-summary.sh [--format compact|detailed] [--verbosity minimal|normal|verbose]
#                               [--max-lines N] [--project-root <dir>]
#                               [--command <cmd> --result <json>]
#
# Requires: python3, scripts/load-config.sh (for config_get)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_DIR="${HOME}/.claude/codex-sessions"

# Source config loader if not already loaded
if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
  # shellcheck source=load-config.sh
  if [[ -f "${SCRIPT_DIR}/load-config.sh" ]]; then
    source "${SCRIPT_DIR}/load-config.sh"
  fi
fi

# ---------------------------------------------------------------------------
# Status Configuration Defaults (overridden by config or env)
# ---------------------------------------------------------------------------
_STATUS_AUTO_SUMMARY="${CODEX_STATUS_AUTO_SUMMARY:-true}"
_STATUS_AUTO_SAVE="${CODEX_STATUS_AUTO_SAVE:-true}"
_STATUS_FORMAT="${CODEX_STATUS_FORMAT:-compact}"
_STATUS_VERBOSITY="${CODEX_STATUS_VERBOSITY:-normal}"
_STATUS_MAX_LINES="${CODEX_STATUS_MAX_LINES:-20}"

# ---------------------------------------------------------------------------
# Load status config from merged config
# ---------------------------------------------------------------------------
_load_status_config() {
  # Priority: env vars (CODEX_STATUS_*) > config_get (2-tier YAML) > defaults
  if declare -f config_get &>/dev/null; then
    _STATUS_AUTO_SUMMARY="${CODEX_STATUS_AUTO_SUMMARY:-$(config_get 'status.auto_summary' 'true')}"
    _STATUS_AUTO_SAVE="${CODEX_STATUS_AUTO_SAVE:-$(config_get 'status.auto_save' 'true')}"
    _STATUS_FORMAT="${CODEX_STATUS_FORMAT:-$(config_get 'status.summary_format' 'compact')}"
    _STATUS_VERBOSITY="${CODEX_STATUS_VERBOSITY:-$(config_get 'status.verbosity' 'normal')}"
    _STATUS_MAX_LINES="${CODEX_STATUS_MAX_LINES:-$(config_get 'status.max_lines' '20')}"
  else
    _STATUS_AUTO_SUMMARY="${CODEX_STATUS_AUTO_SUMMARY:-true}"
    _STATUS_AUTO_SAVE="${CODEX_STATUS_AUTO_SAVE:-true}"
    _STATUS_FORMAT="${CODEX_STATUS_FORMAT:-compact}"
    _STATUS_VERBOSITY="${CODEX_STATUS_VERBOSITY:-normal}"
    _STATUS_MAX_LINES="${CODEX_STATUS_MAX_LINES:-20}"
  fi

  # Validate verbosity
  case "$_STATUS_VERBOSITY" in
    minimal|normal|verbose) ;;
    *) _STATUS_VERBOSITY="normal" ;;
  esac

  # Validate format
  case "$_STATUS_FORMAT" in
    compact|detailed) ;;
    *) _STATUS_FORMAT="compact" ;;
  esac

  # Validate max_lines (1–100)
  if ! [[ "$_STATUS_MAX_LINES" =~ ^[0-9]+$ ]] || \
     [[ "$_STATUS_MAX_LINES" -lt 1 ]] || \
     [[ "$_STATUS_MAX_LINES" -gt 100 ]]; then
    _STATUS_MAX_LINES=20
  fi
}

# ---------------------------------------------------------------------------
# Truncate output to max_lines
# ---------------------------------------------------------------------------
_truncate_output() {
  local max_lines="$1"
  local input
  input="$(cat)"
  local line_count
  line_count="$(echo "$input" | wc -l | tr -d ' ')"

  if [[ "$line_count" -le "$max_lines" ]]; then
    echo "$input"
  elif [[ "$max_lines" -le 1 ]]; then
    echo "... ($line_count lines truncated)"
  else
    echo "$input" | head -n "$((max_lines - 1))"
    echo "... ($((line_count - max_lines + 1)) more lines truncated)"
  fi
}

# ---------------------------------------------------------------------------
# JSON value extraction (minimal, no jq dependency)
# ---------------------------------------------------------------------------
_json_val() {
  local json="$1"
  local key="$2"
  local default="${3:-}"

  if command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    keys = sys.argv[2].split('.')
    current = data
    for k in keys:
        if isinstance(current, dict) and k in current:
            current = current[k]
        else:
            print(sys.argv[3] if len(sys.argv) > 3 else '')
            sys.exit(0)
    if current is None:
        print(sys.argv[3] if len(sys.argv) > 3 else '')
    elif isinstance(current, bool):
        print('true' if current else 'false')
    else:
        print(current)
except Exception:
    print(sys.argv[3] if len(sys.argv) > 3 else '')
" "$json" "$key" "$default" 2>/dev/null
  else
    echo "$default"
  fi
}

# ===========================================================================
# PART 1: Command Completion Summaries
# ===========================================================================

# ---------------------------------------------------------------------------
# Command summary — minimal verbosity
# ---------------------------------------------------------------------------
_cmd_summary_minimal() {
  local command="$1"
  local result_json="$2"

  case "$command" in
    codex-debate|/codex-debate)
      local consensus
      consensus="$(_json_val "$result_json" "consensus" "unknown")"
      echo "[codex-collab] Debate: consensus=$consensus"
      ;;
    codex-evaluate|/codex-evaluate)
      local confidence
      confidence="$(_json_val "$result_json" "confidence" "N/A")"
      echo "[codex-collab] Evaluate: confidence=$confidence"
      ;;
    codex-ask|/codex-ask)
      local mode
      mode="$(_json_val "$result_json" "mode" "read-only")"
      echo "[codex-collab] Ask: mode=$mode completed"
      ;;
    *)
      echo "[codex-collab] $command: completed"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Command summary — normal verbosity
# ---------------------------------------------------------------------------
_cmd_summary_normal() {
  local command="$1"
  local result_json="$2"
  local session_id="${3:-}"

  local lines=()

  case "$command" in
    codex-debate|/codex-debate)
      local rounds consensus topic
      rounds="$(_json_val "$result_json" "rounds" "N/A")"
      consensus="$(_json_val "$result_json" "consensus" "unknown")"
      topic="$(_json_val "$result_json" "topic" "")"
      lines+=("[codex-collab] Debate Summary")
      lines+=("  Command:   /codex-debate")
      [[ -n "$topic" ]] && lines+=("  Topic:     $topic")
      lines+=("  Rounds:    $rounds")
      lines+=("  Consensus: $consensus")
      [[ -n "$session_id" ]] && lines+=("  Session:   $session_id")
      ;;
    codex-evaluate|/codex-evaluate)
      local confidence issues target
      confidence="$(_json_val "$result_json" "confidence" "N/A")"
      issues="$(_json_val "$result_json" "issue_count" "0")"
      target="$(_json_val "$result_json" "target" "")"
      lines+=("[codex-collab] Evaluation Summary")
      lines+=("  Command:    /codex-evaluate")
      [[ -n "$target" ]] && lines+=("  Target:     $target")
      lines+=("  Confidence: $confidence")
      lines+=("  Issues:     $issues")
      [[ -n "$session_id" ]] && lines+=("  Session:    $session_id")
      ;;
    codex-ask|/codex-ask)
      local mode prompt_summary
      mode="$(_json_val "$result_json" "mode" "read-only")"
      prompt_summary="$(_json_val "$result_json" "prompt_summary" "")"
      lines+=("[codex-collab] Ask Summary")
      lines+=("  Command: /codex-ask")
      lines+=("  Mode:    $mode")
      [[ -n "$prompt_summary" ]] && lines+=("  Prompt:  $prompt_summary")
      [[ -n "$session_id" ]] && lines+=("  Session: $session_id")
      ;;
    *)
      lines+=("[codex-collab] Command Summary")
      lines+=("  Command: $command")
      lines+=("  Status:  completed")
      [[ -n "$session_id" ]] && lines+=("  Session: $session_id")
      ;;
  esac

  printf '%s\n' "${lines[@]}"
}

# ---------------------------------------------------------------------------
# Command summary — verbose
# ---------------------------------------------------------------------------
_cmd_summary_verbose() {
  local command="$1"
  local result_json="$2"
  local session_id="${3:-}"

  # Start with normal summary
  _cmd_summary_normal "$command" "$result_json" "$session_id"

  # Add extra detail section
  echo "  ---"

  case "$command" in
    codex-debate|/codex-debate)
      local auto_apply final_position
      auto_apply="$(_json_val "$result_json" "auto_apply" "false")"
      final_position="$(_json_val "$result_json" "final_position" "")"
      echo "  Auto-apply: $auto_apply"
      [[ -n "$final_position" ]] && echo "  Position:   $final_position"
      ;;
    codex-evaluate|/codex-evaluate)
      local severity cross_verified
      severity="$(_json_val "$result_json" "max_severity" "")"
      cross_verified="$(_json_val "$result_json" "cross_verified" "false")"
      [[ -n "$severity" ]] && echo "  Severity:       $severity"
      echo "  Cross-verified: $cross_verified"
      ;;
    codex-ask|/codex-ask)
      local response_length
      response_length="$(_json_val "$result_json" "response_length" "")"
      [[ -n "$response_length" ]] && echo "  Response len: $response_length chars"
      ;;
  esac

  echo "  Timestamp:  $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"
}

# ===========================================================================
# PART 1.5: Auto-Save Report Logic
# ===========================================================================

# ---------------------------------------------------------------------------
# Internal: generate a timestamped report filename
# Format: <command>-<YYYYMMDD>-<HHMMSS>.txt
# ---------------------------------------------------------------------------
_generate_report_filename() {
  local command="$1"
  local timestamp
  timestamp="$(date -u +%Y%m%d-%H%M%S 2>/dev/null || date +%Y%m%d-%H%M%S)"

  # Sanitize command name for filename (remove leading /, replace non-alnum)
  local safe_cmd
  safe_cmd="$(echo "$command" | sed 's|^/||; s|[^a-zA-Z0-9_-]|-|g')"

  echo "${safe_cmd}-${timestamp}.txt"
}

# ---------------------------------------------------------------------------
# Internal: ensure reports directory exists
# Creates .codex-collab/reports/ under the project root if it doesn't exist
# Args: [project_root]
# Returns: the reports directory path via stdout
# ---------------------------------------------------------------------------
_ensure_reports_dir() {
  local project_root="${1:-${CODEX_PROJECT_ROOT:-$(pwd)}}"
  local reports_dir="${project_root}/.codex-collab/reports"

  if [[ ! -d "$reports_dir" ]]; then
    mkdir -p "$reports_dir" 2>/dev/null || {
      echo "[codex-collab] WARNING: Could not create reports directory: $reports_dir" >&2
      return 1
    }
  fi

  echo "$reports_dir"
}

# ---------------------------------------------------------------------------
# Public: save_report
# Writes a summary report to .codex-collab/reports/ with timestamped filename
#
# Args: command content [project_root] [result_json]
#   command:      Command name (codex-debate, codex-evaluate, etc.)
#   content:      The summary text to save
#   project_root: Project directory (default: CODEX_PROJECT_ROOT or cwd)
#   result_json:  Optional result JSON to include in report metadata
#
# Returns:
#   0 + prints saved file path on success
#   1 on failure (with warning to stderr)
# ---------------------------------------------------------------------------
save_report() {
  local command="${1:-}"
  local content="${2:-}"
  local project_root="${3:-${CODEX_PROJECT_ROOT:-$(pwd)}}"
  local result_json="${4:-}"

  if [[ -z "$command" || -z "$content" ]]; then
    echo "[codex-collab] WARNING: save_report requires command and content" >&2
    return 1
  fi

  # Ensure reports directory exists
  local reports_dir
  reports_dir="$(_ensure_reports_dir "$project_root")" || return 1

  # Generate timestamped filename
  local filename
  filename="$(_generate_report_filename "$command")"
  local filepath="${reports_dir}/${filename}"

  # Build report with metadata header
  {
    echo "# codex-collab Summary Report"
    echo "# Command:   $command"
    echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"
    echo "# Project:   $project_root"
    if [[ -n "$result_json" && "$result_json" != "{}" ]]; then
      echo "# Result:    $result_json"
    fi
    echo "#"
    echo ""
    echo "$content"
  } > "$filepath" 2>/dev/null || {
    echo "[codex-collab] WARNING: Could not write report to: $filepath" >&2
    return 1
  }

  echo "$filepath"
  return 0
}

# ---------------------------------------------------------------------------
# Internal: auto-save a report if auto_save is enabled
# Called internally after generating a summary
# Args: command output [project_root] [result_json]
# ---------------------------------------------------------------------------
_auto_save_report() {
  local command="$1"
  local output="$2"
  local project_root="${3:-${CODEX_PROJECT_ROOT:-$(pwd)}}"
  local result_json="${4:-}"

  # Check if auto_save is enabled
  if [[ "$_STATUS_AUTO_SAVE" != "true" ]]; then
    return 0
  fi

  # Skip saving empty output
  if [[ -z "$output" ]]; then
    return 0
  fi

  local saved_path
  saved_path="$(save_report "$command" "$output" "$project_root" "$result_json" 2>/dev/null)" || return 0

  if [[ -n "$saved_path" ]]; then
    echo "[codex-collab] 📄 Report saved: $saved_path" >&2
  fi
}

# ---------------------------------------------------------------------------
# Public: generate_command_summary
# Generate a status summary after command completion
# Args: command result_json [session_id]
# ---------------------------------------------------------------------------
generate_command_summary() {
  local command="${1:-}"
  local result_json="${2:-'{}'}"
  local session_id="${3:-}"

  # Load config
  _load_status_config

  # Check if auto_summary is enabled
  if [[ "$_STATUS_AUTO_SUMMARY" == "false" ]]; then
    return 0
  fi

  # Validate inputs
  if [[ -z "$command" ]]; then
    echo "[codex-collab] ERROR: command name required for status summary" >&2
    return 1
  fi

  # Generate summary based on verbosity
  local output
  case "$_STATUS_VERBOSITY" in
    minimal)
      output="$(_cmd_summary_minimal "$command" "$result_json")"
      ;;
    verbose)
      output="$(_cmd_summary_verbose "$command" "$result_json" "$session_id")"
      ;;
    *)  # normal (default)
      output="$(_cmd_summary_normal "$command" "$result_json" "$session_id")"
      ;;
  esac

  # Apply format wrapper for detailed mode
  if [[ "$_STATUS_FORMAT" == "detailed" ]]; then
    local border
    border="$(printf '─%.0s' {1..50})"
    output="${border}"$'\n'"${output}"$'\n'"${border}"
  fi

  # Apply max_lines truncation
  local final_output
  final_output="$(echo "$output" | _truncate_output "$_STATUS_MAX_LINES")"

  # Auto-save report to .codex-collab/reports/ if enabled
  _auto_save_report "$command" "$final_output" "" "$result_json"

  echo "$final_output"
}

# ===========================================================================
# PART 2: Session State Summaries (original functionality)
# ===========================================================================

# ---------------------------------------------------------------------------
# Internal: collect raw session state as JSON
# ---------------------------------------------------------------------------
_collect_session_state() {
  local project_root="${1:-$(pwd)}"

  python3 - "$project_root" "$SESSION_DIR" <<'PYEOF'
import sys
import json
import os
import glob
from datetime import datetime

project_root = sys.argv[1]
session_dir = sys.argv[2]

state = {
    "active_sessions": [],
    "ended_sessions": [],
    "pending_debates": [],
    "recent_actions": [],
    "total_interactions": 0,
    "participants": ["Claude"],
    "project": project_root,
}

session_files = sorted(glob.glob(os.path.join(session_dir, "*.json")), reverse=True)

for sf in session_files:
    try:
        with open(sf, "r", encoding="utf-8") as f:
            session = json.load(f)
    except (json.JSONDecodeError, IOError):
        continue

    # Filter by project
    if session.get("project") != project_root:
        continue

    sid = session.get("id", "unknown")
    name = session.get("name", "unnamed")
    status = session.get("status", "unknown")
    created = session.get("created_at", "")
    history = session.get("history", [])
    codex_sid = session.get("codex_session_id")

    session_info = {
        "id": sid,
        "name": name,
        "status": status,
        "created_at": created,
        "history_count": len(history),
        "has_codex_session": codex_sid is not None,
    }

    if status == "active":
        state["active_sessions"].append(session_info)
        if codex_sid:
            if "Codex (GPT-5.4)" not in state["participants"]:
                state["participants"].append("Codex (GPT-5.4)")
    else:
        state["ended_sessions"].append(session_info)

    # Collect recent actions (last 5 across all sessions for this project)
    for entry in reversed(history):
        if len(state["recent_actions"]) >= 5:
            break
        action = {
            "command": entry.get("command", "unknown"),
            "timestamp": entry.get("timestamp", ""),
            "summary": entry.get("prompt_summary", "")[:80],
            "mode": entry.get("mode", "read-only"),
            "session_name": name,
        }
        # Check for pending/ongoing debates
        if entry.get("command") == "codex-debate":
            sr = entry.get("structured_result")
            if sr and isinstance(sr, dict):
                consensus = sr.get("consensus_reached", False)
                if not consensus:
                    state["pending_debates"].append({
                        "topic": entry.get("prompt_summary", "")[:60],
                        "session": name,
                        "rounds_completed": sr.get("rounds_completed", 0),
                    })
        state["recent_actions"].append(action)

    state["total_interactions"] += len(history)

print(json.dumps(state, ensure_ascii=False))
PYEOF
}

# ---------------------------------------------------------------------------
# Format session state: compact (3 lines)
# ---------------------------------------------------------------------------
_format_compact() {
  local state_json="$1"

  python3 - "$state_json" <<'PYEOF'
import sys
import json

state = json.loads(sys.argv[1])

active = state["active_sessions"]
participants = state["participants"]
recent = state["recent_actions"]
pending = state["pending_debates"]
total = state["total_interactions"]

lines = []

# Line 1: Session status + participants
if active:
    s = active[0]
    p_str = " + ".join(participants)
    lines.append(f"Session: \"{s['name']}\" (active) | Participants: {p_str} | Interactions: {s['history_count']}")
else:
    lines.append("Session: none active | Use /codex-session start <name> to begin")

# Line 2: Pending debates + recent action
if pending:
    d = pending[0]
    lines.append(f"Pending debate: \"{d['topic']}\" (round {d['rounds_completed']}) | {len(pending)} total pending")
elif recent:
    a = recent[0]
    cmd = a["command"]
    mode_tag = f" [{a['mode']}]" if a.get("mode") else ""
    lines.append(f"Last action: /{cmd}{mode_tag} — {a['summary']}")
else:
    lines.append("No recent actions")

# Line 3: Summary stats
ended_count = len(state["ended_sessions"])
lines.append(f"Total: {total} interactions | {len(active)} active, {ended_count} ended sessions")

print("\n".join(lines))
PYEOF
}

# ---------------------------------------------------------------------------
# Format session state: detailed (5 lines)
# ---------------------------------------------------------------------------
_format_detailed() {
  local state_json="$1"

  python3 - "$state_json" <<'PYEOF'
import sys
import json

state = json.loads(sys.argv[1])

active = state["active_sessions"]
participants = state["participants"]
recent = state["recent_actions"]
pending = state["pending_debates"]
total = state["total_interactions"]
ended = state["ended_sessions"]

lines = []

# Line 1: Session status
if active:
    s = active[0]
    lines.append(f"Session: \"{s['name']}\" ({s['id']}) — active since {s['created_at'][:10]}")
else:
    lines.append("Session: none active | Use /codex-session start <name> to begin")

# Line 2: Participants + Codex session link
p_str = " + ".join(participants)
codex_linked = any(s.get("has_codex_session") for s in active)
link_status = "linked" if codex_linked else "not yet linked"
lines.append(f"Participants: {p_str} | Codex session: {link_status}")

# Line 3: Pending debates
if pending:
    topics = [f"\"{d['topic']}\" (R{d['rounds_completed']})" for d in pending[:3]]
    lines.append(f"Pending debates: {', '.join(topics)}")
else:
    lines.append("No pending debates")

# Line 4: Recent actions (up to 3)
if recent:
    action_strs = []
    for a in recent[:3]:
        mode_tag = f"[{a['mode']}]" if a.get("mode") else ""
        action_strs.append(f"/{a['command']}{mode_tag}")
    lines.append(f"Recent: {' > '.join(action_strs)}")
else:
    lines.append("No recent actions")

# Line 5: Summary stats
lines.append(f"Stats: {total} interactions | {len(active)} active, {len(ended)} ended sessions | Project: {state['project']}")

print("\n".join(lines))
PYEOF
}

# ---------------------------------------------------------------------------
# Public: get_session_state
# Returns raw JSON session state for current project
# ---------------------------------------------------------------------------
get_session_state() {
  local project_root="${1:-$(pwd)}"

  if ! command -v python3 &>/dev/null; then
    echo '{"error": "python3 required"}' >&2
    return 1
  fi

  if [[ ! -d "$SESSION_DIR" ]]; then
    echo '{"active_sessions":[],"ended_sessions":[],"pending_debates":[],"recent_actions":[],"total_interactions":0,"participants":["Claude"],"project":"'"$project_root"'"}'
    return 0
  fi

  _collect_session_state "$project_root"
}

# ---------------------------------------------------------------------------
# Public: generate_status_summary
# Generate formatted session state summary
# Args: [format] [project_root]
# ---------------------------------------------------------------------------
generate_status_summary() {
  local format="${1:-}"
  local project_root="${2:-$(pwd)}"

  # Load config
  _load_status_config

  # Check if auto_summary is enabled
  if [[ "$_STATUS_AUTO_SUMMARY" == "false" ]]; then
    return 0
  fi

  # Determine format from config if not specified
  if [[ -z "$format" ]]; then
    format="$_STATUS_FORMAT"
  fi

  if ! command -v python3 &>/dev/null; then
    echo "[codex-collab] Status unavailable (python3 required)" >&2
    return 1
  fi

  # Collect state
  local state_json
  if [[ -d "$SESSION_DIR" ]]; then
    state_json=$(_collect_session_state "$project_root")
  else
    state_json='{"active_sessions":[],"ended_sessions":[],"pending_debates":[],"recent_actions":[],"total_interactions":0,"participants":["Claude"],"project":"'"$project_root"'"}'
  fi

  local output
  output="[codex-collab] Status Summary"$'\n'"─────────────────────────────"$'\n'

  case "$format" in
    detailed)
      output+="$(_format_detailed "$state_json")"
      ;;
    compact|*)
      output+="$(_format_compact "$state_json")"
      ;;
  esac

  # Apply max_lines truncation
  echo "$output" | _truncate_output "$_STATUS_MAX_LINES"
}

# ---------------------------------------------------------------------------
# Public: should_auto_summary
# Check if auto-summary is enabled in config
# Returns 0 (true) if enabled, 1 (false) if disabled
# ---------------------------------------------------------------------------
should_auto_summary() {
  _load_status_config
  if [[ "$_STATUS_AUTO_SUMMARY" == "true" ]]; then
    return 0
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Public: emit_post_command_summary
# The primary pipeline integration point — called as the FINAL step of every
# command in the workflow-orchestrator pipeline.
# Combines: 1) per-command completion line + 2) session state summary
#
# Args: command status [mode] [extra_info] [project_root]
#   command:    codex-ask | codex-evaluate | codex-debate | codex-session
#   status:     success | error | partial
#   mode:       read-only | write | (empty for session commands)
#   extra_info: command-specific detail (e.g., "quality: good, confidence: 0.85")
#   project_root: project directory (default: cwd)
#
# Example:
#   emit_post_command_summary "codex-ask" "success" "read-only"
#   emit_post_command_summary "codex-evaluate" "success" "read-only" "quality: good, confidence: 0.85"
#   emit_post_command_summary "codex-debate" "success" "" "3 round(s), consensus reached"
#   emit_post_command_summary "codex-session" "success" "" "started: \"리팩토링 작업\""
# ---------------------------------------------------------------------------
emit_post_command_summary() {
  local command="${1:-}"
  local status="${2:-success}"
  local mode="${3:-}"
  local extra_info="${4:-}"
  local project_root="${5:-$(pwd)}"

  # Load config
  _load_status_config

  # Check if auto_summary is enabled
  if [[ "$_STATUS_AUTO_SUMMARY" == "false" ]]; then
    return 0
  fi

  if [[ -z "$command" ]]; then
    return 0
  fi

  # --- Part 1: Per-command completion line ---
  local icon
  case "$status" in
    success) icon="✓" ;;
    error)   icon="✗" ;;
    partial) icon="△" ;;
    *)       icon="•" ;;
  esac

  local label
  case "$command" in
    codex-ask|/codex-ask)           label="Codex Ask" ;;
    codex-evaluate|/codex-evaluate) label="Codex Evaluate" ;;
    codex-debate|/codex-debate)     label="Codex Debate" ;;
    codex-session|/codex-session)   label="Session" ;;
    *)                              label="$command" ;;
  esac

  local completion_line="[codex-collab] ${icon} ${label}"

  case "$status" in
    success) completion_line+=" completed" ;;
    error)   completion_line+=" failed" ;;
    partial) completion_line+=" partially completed" ;;
  esac

  # Add mode if present
  if [[ -n "$mode" && "$mode" != "none" ]]; then
    completion_line+=" (${mode})"
  fi

  # Add extra info (e.g., quality/confidence for evaluate, rounds for debate)
  if [[ -n "$extra_info" ]]; then
    completion_line+=" — ${extra_info}"
  fi

  echo "$completion_line"

  # --- Part 2: Session state summary ---
  # Only emit if python3 is available; fail gracefully otherwise
  if ! command -v python3 &>/dev/null; then
    echo "[codex-collab] ⚠ Status summary unavailable (python3 required)"
    return 0
  fi

  # Collect and format session state
  local state_json
  if [[ -d "$SESSION_DIR" ]]; then
    state_json=$(_collect_session_state "$project_root" 2>/dev/null) || true
  fi

  if [[ -z "${state_json:-}" ]]; then
    state_json='{"active_sessions":[],"ended_sessions":[],"pending_debates":[],"recent_actions":[],"total_interactions":0,"participants":["Claude"],"project":"'"$project_root"'"}'
  fi

  local format="$_STATUS_FORMAT"
  local session_output=""

  echo "[codex-collab] Status Summary"
  echo "─────────────────────────────"

  local status_output=""
  case "$format" in
    detailed)
      status_output="$(_format_detailed "$state_json" 2>/dev/null)" || status_output="📋 Status details unavailable"
      ;;
    compact|*)
      status_output="$(_format_compact "$state_json" 2>/dev/null)" || status_output="📋 Status details unavailable"
      ;;
  esac

  echo "$status_output"

  # --- Part 3: Auto-save full report ---
  local full_report="${completion_line}"$'\n'"[codex-collab] Status Summary"$'\n'"─────────────────────────────"$'\n'"${status_output}"
  _auto_save_report "$command" "$full_report" "$project_root"

  return 0
}

# ===========================================================================
# PART 3: Forced Summary on Max-Round Exhaustion
# ===========================================================================

# ---------------------------------------------------------------------------
# Public: generate_max_round_exhaustion_summary
# Generates and auto-saves a forced summary report when a debate exhausts
# its maximum allowed rounds. This is called AFTER the user makes their
# 4-choice selection, ensuring a summary is always produced regardless of
# which choice was made (apply_claude, apply_codex, discard, or blocked continue).
#
# This function is designed to be called by debate-result-handler.sh when
# it detects that current_round >= effective_max.
#
# Args:
#   $1 — debate result JSON
#   $2 — user's choice (apply_claude | apply_codex | discard | continue)
#   $3 — choice status (applied | informational | discarded | blocked_cap)
#   $4 — current round number
#   $5 — effective max rounds
#   $6 — session ID (optional)
#   $7 — project root (optional, default: cwd)
#
# Output: Formatted summary to stdout
# Side effects: Auto-saves report to .codex-collab/reports/ if auto_save enabled
# Returns: 0 always (summary generation should never block the pipeline)
# ---------------------------------------------------------------------------
generate_max_round_exhaustion_summary() {
  local result_json="${1:-'{}'}"
  local choice="${2:-unknown}"
  local choice_status="${3:-unknown}"
  local current_round="${4:-0}"
  local effective_max="${5:-5}"
  local session_id="${6:-}"
  local project_root="${7:-${CODEX_PROJECT_ROOT:-$(pwd)}}"

  # Load config
  _load_status_config

  # Build the forced summary
  local topic rounds consensus
  topic="$(_json_val "$result_json" "topic" "Unknown topic")"
  rounds="$(_json_val "$result_json" "rounds" "$current_round")"
  consensus="$(_json_val "$result_json" "consensus" "false")"

  local choice_label
  case "$choice" in
    apply_claude)  choice_label="Applied Claude's proposal" ;;
    apply_codex)   choice_label="Applied Codex (GPT-5.4)'s proposal" ;;
    discard)       choice_label="Discarded both proposals" ;;
    continue)      choice_label="Continue requested (blocked — cap reached)" ;;
    *)             choice_label="$choice" ;;
  esac

  local status_icon
  case "$choice_status" in
    applied)        status_icon="✅" ;;
    informational)  status_icon="📝" ;;
    discarded)      status_icon="❌" ;;
    blocked_cap)    status_icon="🚫" ;;
    *)              status_icon="⏳" ;;
  esac

  local output=""
  output+="[codex-collab] ⚠ Max-Round Exhaustion Summary"
  output+=$'\n'"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  output+=$'\n'"  Topic:       ${topic}"
  output+=$'\n'"  Rounds:      ${current_round} of ${effective_max} (maximum reached)"
  output+=$'\n'"  Consensus:   $([ "$consensus" = "true" ] && echo "reached" || echo "not reached")"
  output+=$'\n'"  Decision:    ${status_icon} ${choice_label}"
  [[ -n "$session_id" ]] && output+=$'\n'"  Session:     ${session_id}"
  output+=$'\n'"  Generated:   $(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"
  output+=$'\n'"━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Add per-round position summary if verbose
  if [[ "$_STATUS_VERBOSITY" == "verbose" ]]; then
    local round_positions
    round_positions="$(_json_val "$result_json" "round_positions" "")"
    if [[ -n "$round_positions" && "$round_positions" != "" ]]; then
      output+=$'\n'"  Per-round positions: ${round_positions}"
    fi

    local divergence_score
    divergence_score="$(_json_val "$result_json" "divergence_score" "")"
    if [[ -n "$divergence_score" ]]; then
      output+=$'\n'"  Divergence:  ${divergence_score}"
    fi

    local convergence_trend
    convergence_trend="$(_json_val "$result_json" "convergence_trend" "")"
    if [[ -n "$convergence_trend" ]]; then
      output+=$'\n'"  Trend:       ${convergence_trend}"
    fi
  fi

  # Display to stdout
  echo "$output"

  # Force auto-save regardless of user choice — this is the key behavior:
  # max-round exhaustion reports are ALWAYS saved to ensure audit trail
  local exhaustion_result_json
  exhaustion_result_json=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
except:
    data = {}
data['max_round_exhausted'] = True
data['effective_max'] = int(sys.argv[2])
data['user_choice'] = sys.argv[3]
data['choice_status'] = sys.argv[4]
print(json.dumps(data, ensure_ascii=False))
" "$result_json" "$effective_max" "$choice" "$choice_status" 2>/dev/null || echo "$result_json")

  # Save the report (force save even if auto_save is disabled for exhaustion reports)
  local saved_path
  saved_path="$(save_report "codex-debate-exhaustion" "$output" "$project_root" "$exhaustion_result_json" 2>/dev/null)" || true

  if [[ -n "${saved_path:-}" ]]; then
    echo "[codex-collab] 📄 Max-round exhaustion report saved: $saved_path"
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Public: is_max_round_exhausted
# Quick check: did the debate exhaust its maximum rounds?
# Args:
#   $1 — current round number
#   $2 — effective max rounds
# Returns: 0 if exhausted, 1 if not
# ---------------------------------------------------------------------------
is_max_round_exhausted() {
  local current_round="${1:-0}"
  local effective_max="${2:-5}"

  if [[ "$current_round" -ge "$effective_max" ]]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Public: get_status_config
# Returns current status config as key=value lines (for testing)
# ---------------------------------------------------------------------------
get_status_config() {
  _load_status_config
  echo "auto_summary=$_STATUS_AUTO_SUMMARY"
  echo "auto_save=$_STATUS_AUTO_SAVE"
  echo "summary_format=$_STATUS_FORMAT"
  echo "verbosity=$_STATUS_VERBOSITY"
  echo "max_lines=$_STATUS_MAX_LINES"
}

# ---------------------------------------------------------------------------
# CLI mode — run directly
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  FORMAT=""
  PROJECT_ROOT="$(pwd)"
  CLI_COMMAND=""
  CLI_RESULT="{}"
  CLI_SESSION=""
  CLI_VERBOSITY=""
  CLI_MAX_LINES=""
  CLI_AUTO_SAVE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --format)       FORMAT="$2"; shift 2 ;;
      --project-root) PROJECT_ROOT="$2"; shift 2 ;;
      --command)      CLI_COMMAND="$2"; shift 2 ;;
      --result)       CLI_RESULT="$2"; shift 2 ;;
      --session)      CLI_SESSION="$2"; shift 2 ;;
      --verbosity)    CLI_VERBOSITY="$2"; shift 2 ;;
      --max-lines)    CLI_MAX_LINES="$2"; shift 2 ;;
      --auto-save)    CLI_AUTO_SAVE="$2"; shift 2 ;;
      --json)
        # Output raw JSON state
        get_session_state "$PROJECT_ROOT"
        exit $?
        ;;
      --help|-h)
        echo "Usage: status-summary.sh [options]"
        echo ""
        echo "Generates status summaries for codex-collab."
        echo ""
        echo "Session state mode (default):"
        echo "  --format <fmt>       compact (3 lines) or detailed (5 lines)"
        echo "  --project-root <dir> Project root directory (default: cwd)"
        echo "  --json               Output raw session state as JSON"
        echo ""
        echo "Command completion mode:"
        echo "  --command <cmd>      Command name (codex-debate, codex-evaluate, codex-ask)"
        echo "  --result <json>      Result JSON string"
        echo "  --session <id>       Session ID"
        echo ""
        echo "Config overrides:"
        echo "  --verbosity <level>  minimal, normal, or verbose"
        echo "  --max-lines <N>      Max output lines (1–100)"
        echo "  --auto-save <bool>   Enable/disable auto-save to reports (true/false)"
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  # CLI overrides for env
  [[ -n "$FORMAT" ]]        && export CODEX_STATUS_FORMAT="$FORMAT"
  [[ -n "$CLI_VERBOSITY" ]] && export CODEX_STATUS_VERBOSITY="$CLI_VERBOSITY"
  [[ -n "$CLI_MAX_LINES" ]] && export CODEX_STATUS_MAX_LINES="$CLI_MAX_LINES"
  [[ -n "$CLI_AUTO_SAVE" ]] && export CODEX_STATUS_AUTO_SAVE="$CLI_AUTO_SAVE"

  CODEX_PROJECT_ROOT="$PROJECT_ROOT"

  if [[ -n "$CLI_COMMAND" ]]; then
    # Command completion summary mode
    generate_command_summary "$CLI_COMMAND" "$CLI_RESULT" "$CLI_SESSION"
  else
    # Session state summary mode
    generate_status_summary "$FORMAT" "$PROJECT_ROOT"
  fi
fi
