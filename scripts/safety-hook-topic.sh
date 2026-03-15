#!/usr/bin/env bash
# safety-hook-topic.sh — Derive debate topics from safety hook detection content
#
# When a safety hook fires with severity caution or higher, this script
# analyzes the hook output and originating command context to generate
# a meaningful debate topic for a cross-model safety review.
#
# Usage:
#   # Source for shell functions:
#   source scripts/safety-hook-topic.sh
#   topic=$(derive_debate_topic "$hook_output" "$original_command" "$prompt_summary")
#   severity=$(detect_hook_severity "$hook_output")
#   should_propose=$(should_propose_debate "$hook_output")
#
#   # Or run directly:
#   ./scripts/safety-hook-topic.sh --hook-output "<hook stderr>" [--command "<cmd>"] [--prompt "<prompt>"]
#
# Integration:
#   Called by workflow-orchestrator between PreToolUse hook execution and
#   command execution. Only proposes debates for caution/warning severity.
#
# Environment:
#   Requires load-config.sh to be sourced or CODEX_CONFIG_LOADED=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Ensure config is loaded
# ---------------------------------------------------------------------------
_ensure_config() {
  if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
    # shellcheck source=load-config.sh
    source "${SCRIPT_DIR}/load-config.sh"
    load_config
  fi
}

# ---------------------------------------------------------------------------
# Severity constants
# ---------------------------------------------------------------------------
readonly SEVERITY_INFO="info"
readonly SEVERITY_CAUTION="caution"
readonly SEVERITY_WARNING="warning"
readonly SEVERITY_CRITICAL="critical"

# Severities that trigger debate proposals
readonly DEBATE_TRIGGER_SEVERITIES="caution warning"

# ---------------------------------------------------------------------------
# Detect hook severity from hook output text
#
# Parses the hook stderr output for severity markers:
#   - [SEVERITY:critical] or "BLOCKED" → critical
#   - [SEVERITY:warning] or "WARNING" + mode indicators → warning
#   - [SEVERITY:caution] or "WRITE-MODE" / "ENFORCEMENT" → caution
#   - [SEVERITY:info] or "SESSION" notices → info
#   - Unknown → info (safe default, no debate trigger)
#
# Args:
#   $1 — hook output text (stderr captured from hook execution)
#
# Output: severity level string (info|caution|warning|critical)
# ---------------------------------------------------------------------------
detect_hook_severity() {
  local hook_output="${1:-}"

  if [[ -z "$hook_output" ]]; then
    echo "$SEVERITY_INFO"
    return 0
  fi

  # Check for explicit [SEVERITY:level] tags first (highest priority)
  if [[ "$hook_output" =~ \[SEVERITY:critical\] ]]; then
    echo "$SEVERITY_CRITICAL"
    return 0
  fi
  if [[ "$hook_output" =~ \[SEVERITY:warning\] ]]; then
    echo "$SEVERITY_WARNING"
    return 0
  fi
  if [[ "$hook_output" =~ \[SEVERITY:caution\] ]]; then
    echo "$SEVERITY_CAUTION"
    return 0
  fi
  if [[ "$hook_output" =~ \[SEVERITY:info\] ]]; then
    echo "$SEVERITY_INFO"
    return 0
  fi

  # Fallback: detect severity from content patterns
  if [[ "$hook_output" == *"BLOCKED"* ]]; then
    echo "$SEVERITY_CRITICAL"
    return 0
  fi

  if [[ "$hook_output" == *"WARNING"* ]] && \
     [[ "$hook_output" == *"full-auto"* || "$hook_output" == *"file changes"* || "$hook_output" == *"modify"* ]]; then
    echo "$SEVERITY_WARNING"
    return 0
  fi

  if [[ "$hook_output" == *"WRITE-MODE"* || "$hook_output" == *"ENFORCEMENT"* ]]; then
    echo "$SEVERITY_CAUTION"
    return 0
  fi

  if [[ "$hook_output" == *"SESSION"* && "$hook_output" == *"NOTICE"* ]]; then
    echo "$SEVERITY_INFO"
    return 0
  fi

  # Default: info (no debate trigger)
  echo "$SEVERITY_INFO"
  return 0
}

# ---------------------------------------------------------------------------
# Check whether a debate should be proposed based on hook output
#
# Args:
#   $1 — hook output text
#
# Returns: 0 (true) if debate should be proposed, 1 (false) otherwise
# Also checks config safety.auto_trigger_hooks setting.
# ---------------------------------------------------------------------------
should_propose_debate() {
  local hook_output="${1:-}"

  # Detect severity
  local severity
  severity=$(detect_hook_severity "$hook_output")

  # Only caution and warning trigger proposals
  if [[ "$severity" != "$SEVERITY_CAUTION" && "$severity" != "$SEVERITY_WARNING" ]]; then
    return 1
  fi

  # Check config: safety.auto_trigger_hooks
  _ensure_config
  local auto_trigger
  auto_trigger=$(config_get "safety.auto_trigger_hooks" "true")

  if [[ "$auto_trigger" != "true" ]]; then
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Extract target files from a codex CLI command string
#
# Args:
#   $1 — command string (e.g., "codex exec --write src/auth.py")
#
# Output: space-separated list of detected file paths, or empty
# ---------------------------------------------------------------------------
_extract_target_files() {
  local command="${1:-}"
  local files=""

  # Look for common file extensions in the command
  # Match patterns like: path/to/file.ext
  local found
  found=$(echo "$command" | grep -oE '[a-zA-Z0-9_./-]+\.(py|js|ts|tsx|jsx|rb|go|rs|java|c|cpp|h|hpp|sh|yaml|yml|json|md|sql|html|css)' 2>/dev/null || true)

  if [[ -n "$found" ]]; then
    # Deduplicate and limit to first 3 files
    files=$(echo "$found" | sort -u | head -3 | tr '\n' ', ' | sed 's/,$//')
  fi

  echo "$files"
}

# ---------------------------------------------------------------------------
# Truncate text to a maximum length, appending "..." if truncated
#
# Args:
#   $1 — text to truncate
#   $2 — max length (default: 100)
#
# Output: truncated text
# ---------------------------------------------------------------------------
_truncate() {
  local text="${1:-}"
  local max_len="${2:-100}"

  if [[ ${#text} -le $max_len ]]; then
    echo "$text"
  else
    echo "${text:0:$max_len}..."
  fi
}

# ---------------------------------------------------------------------------
# Derive a debate topic from safety hook context
#
# Generates a meaningful, context-aware debate topic based on:
#   - The hook's detection type (write-mode, full-auto, write flags)
#   - The original user prompt (first 100 chars)
#   - Target file paths mentioned in the command
#
# Args:
#   $1 — hook output text (stderr from hook)
#   $2 — original command string (the codex CLI invocation)
#   $3 — user prompt summary (optional, first 100 chars of user input)
#
# Output: derived debate topic string
# ---------------------------------------------------------------------------
derive_debate_topic() {
  local hook_output="${1:-}"
  local original_command="${2:-}"
  local prompt_summary="${3:-}"

  # Truncate prompt to 100 chars
  prompt_summary=$(_truncate "$prompt_summary" 100)

  # Extract file targets from command
  local target_files
  target_files=$(_extract_target_files "$original_command")

  # Determine topic template based on hook type
  local topic=""

  # Case 1: Write-mode enforcement (WRITE-MODE ENFORCEMENT)
  if [[ "$hook_output" == *"WRITE-MODE"* || "$hook_output" == *"ENFORCEMENT"* ]]; then
    if [[ -n "$prompt_summary" ]]; then
      topic="이 작업에서 파일 수정이 안전한가? (Write-mode safety review: ${prompt_summary})"
    else
      topic="이 작업에서 파일 수정이 안전한가? (Write-mode safety review)"
    fi
    if [[ -n "$target_files" ]]; then
      topic="${topic} [files: ${target_files}]"
    fi

  # Case 2: Full-auto mode warning (--full-auto)
  elif [[ "$hook_output" == *"full-auto"* || "$original_command" == *"--full-auto"* ]]; then
    topic="Codex full-auto 모드의 위험성 평가 — 현재 작업 컨텍스트에서 적절한가? (Full-auto risk assessment)"
    if [[ -n "$prompt_summary" ]]; then
      topic="${topic} — context: ${prompt_summary}"
    fi

  # Case 3: Write flag detected (--write / --edit / -w)
  elif [[ "$hook_output" == *"file changes"* || "$original_command" =~ --(write|edit)|-w[[:space:]] ]]; then
    if [[ -n "$target_files" ]]; then
      topic="파일 변경 작업의 범위와 안전성 검토 (File modification scope review: ${target_files})"
    elif [[ -n "$prompt_summary" ]]; then
      topic="파일 변경 작업의 범위와 안전성 검토 (File modification scope review: ${prompt_summary})"
    else
      topic="파일 변경 작업의 범위와 안전성 검토 (File modification scope review)"
    fi

  # Fallback: generic safety review topic
  else
    if [[ -n "$prompt_summary" ]]; then
      topic="안전성 검토가 필요한 작업 (Safety review required: ${prompt_summary})"
    else
      topic="안전성 검토가 필요한 작업 (Safety review required for current operation)"
    fi
  fi

  echo "$topic"
}

# ---------------------------------------------------------------------------
# Get the hook type label for display purposes
#
# Args:
#   $1 — hook output text
#
# Output: human-readable hook type label
# ---------------------------------------------------------------------------
get_hook_type_label() {
  local hook_output="${1:-}"

  if [[ "$hook_output" == *"WRITE-MODE"* ]]; then
    echo "Write-Mode Enforcement"
  elif [[ "$hook_output" == *"full-auto"* ]]; then
    echo "Full-Auto Mode Warning"
  elif [[ "$hook_output" == *"file changes"* ]]; then
    echo "File Modification Warning"
  elif [[ "$hook_output" == *"BLOCKED"* ]]; then
    echo "Dangerous Mode Blocked"
  elif [[ "$hook_output" == *"SESSION"* ]]; then
    echo "Session Notice"
  else
    echo "Safety Hook"
  fi
}

# ---------------------------------------------------------------------------
# Format the full debate proposal display for user approval
#
# This builds the approval prompt shown between hook execution and
# command execution, including the derived topic and round info.
#
# Args:
#   $1 — hook output text (original hook warning)
#   $2 — derived topic (from derive_debate_topic)
#   $3 — severity level (from detect_hook_severity)
#
# Output: formatted proposal string for display
# ---------------------------------------------------------------------------
format_debate_proposal() {
  local hook_output="${1:-}"
  local topic="${2:-}"
  local severity="${3:-}"

  # Get round info from config
  _ensure_config
  local default_rounds max_additional
  default_rounds=$(config_get "debate.default_rounds" "3")
  max_additional=$(config_get "debate.max_additional_rounds" "2")

  # Clamp max_additional to hard cap
  if [[ "$max_additional" -gt 2 ]]; then
    max_additional=2
  fi

  local hook_label
  hook_label=$(get_hook_type_label "$hook_output")

  # Extract first line of hook warning for display
  local hook_first_line
  hook_first_line=$(echo "$hook_output" | grep -v '^\[codex-collab\]' | head -1 | sed 's/^[[:space:]]*//' || echo "$hook_output" | head -1)
  if [[ -z "$hook_first_line" ]]; then
    hook_first_line=$(echo "$hook_output" | head -1)
  fi

  cat <<PROPOSAL
[codex-collab] ⚠ Safety hook triggered (severity: ${severity})

Hook warning: ${hook_label} — ${hook_first_line}

💬 Debate proposal:
   Topic: "${topic}"
   Rounds: ${default_rounds} (max +${max_additional} more)

Do you want to run a cross-model debate before proceeding?
[Y] Start debate  [N] Proceed without debate  [C] Cancel
PROPOSAL
}

# ---------------------------------------------------------------------------
# Build a structured JSON record for auto-trigger debate proposals
#
# Used for session history recording regardless of user decision.
#
# Args:
#   $1 — severity level
#   $2 — derived topic
#   $3 — hook type label
#   $4 — user decision (accepted|declined|cancelled)
#   $5 — original hook output (optional, for audit)
#
# Output: JSON string for session history
# ---------------------------------------------------------------------------
build_proposal_record() {
  local severity="${1:-}"
  local topic="${2:-}"
  local hook_label="${3:-}"
  local decision="${4:-}"
  local hook_output="${5:-}"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")

  # Escape strings for JSON
  local escaped_topic escaped_label escaped_hook
  escaped_topic=$(echo "$topic" | sed 's/"/\\"/g' | tr '\n' ' ')
  escaped_label=$(echo "$hook_label" | sed 's/"/\\"/g')
  escaped_hook=$(echo "$hook_output" | head -3 | sed 's/"/\\"/g' | tr '\n' ' ')

  cat <<JSON
{
  "type": "safety-hook-debate-proposal",
  "timestamp": "${timestamp}",
  "severity": "${severity}",
  "hook_type": "${escaped_label}",
  "derived_topic": "${escaped_topic}",
  "decision": "${decision}",
  "trigger_source": "safety_hook",
  "hook_output_preview": "${escaped_hook}"
}
JSON
}

# ---------------------------------------------------------------------------
# Full pipeline: detect severity → derive topic → check if proposal needed
#
# Convenience function that runs the full detection + topic derivation pipeline.
#
# Args:
#   $1 — hook output text
#   $2 — original command string
#   $3 — user prompt summary (optional)
#
# Output: JSON with severity, should_propose, topic, hook_type
# Returns: 0 if debate should be proposed, 1 otherwise
# ---------------------------------------------------------------------------
analyze_hook_for_debate() {
  local hook_output="${1:-}"
  local original_command="${2:-}"
  local prompt_summary="${3:-}"

  local severity topic hook_label should_propose

  severity=$(detect_hook_severity "$hook_output")
  topic=$(derive_debate_topic "$hook_output" "$original_command" "$prompt_summary")
  hook_label=$(get_hook_type_label "$hook_output")

  if should_propose_debate "$hook_output"; then
    should_propose="true"
  else
    should_propose="false"
  fi

  # Escape for JSON
  local escaped_topic escaped_label
  escaped_topic=$(echo "$topic" | sed 's/"/\\"/g' | tr '\n' ' ')
  escaped_label=$(echo "$hook_label" | sed 's/"/\\"/g')

  cat <<JSON
{
  "severity": "${severity}",
  "should_propose": ${should_propose},
  "topic": "${escaped_topic}",
  "hook_type": "${escaped_label}"
}
JSON

  if [[ "$should_propose" == "true" ]]; then
    return 0
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# CLI mode — run directly for analysis output
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  HOOK_OUTPUT=""
  COMMAND=""
  PROMPT=""
  MODE="analyze"  # analyze | topic | severity | proposal

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hook-output) HOOK_OUTPUT="$2"; shift 2 ;;
      --command)     COMMAND="$2"; shift 2 ;;
      --prompt)      PROMPT="$2"; shift 2 ;;
      --mode)        MODE="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: safety-hook-topic.sh --hook-output <text> [--command <cmd>] [--prompt <prompt>] [--mode <mode>]"
        echo ""
        echo "Derives debate topics from safety hook detection content."
        echo ""
        echo "Options:"
        echo "  --hook-output <text>  Hook stderr output (required)"
        echo "  --command <cmd>       Original codex CLI command"
        echo "  --prompt <prompt>     User prompt summary"
        echo "  --mode <mode>         Output mode: analyze (default) | topic | severity | proposal"
        echo "  --help, -h            Show this help"
        echo ""
        echo "Modes:"
        echo "  analyze   Full JSON analysis (severity, topic, should_propose)"
        echo "  topic     Print only the derived topic string"
        echo "  severity  Print only the severity level"
        echo "  proposal  Print formatted debate proposal for user display"
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$HOOK_OUTPUT" ]]; then
    echo "Error: --hook-output is required" >&2
    exit 1
  fi

  source "${SCRIPT_DIR}/load-config.sh"

  case "$MODE" in
    analyze)
      analyze_hook_for_debate "$HOOK_OUTPUT" "$COMMAND" "$PROMPT"
      ;;
    topic)
      derive_debate_topic "$HOOK_OUTPUT" "$COMMAND" "$PROMPT"
      ;;
    severity)
      detect_hook_severity "$HOOK_OUTPUT"
      ;;
    proposal)
      severity=$(detect_hook_severity "$HOOK_OUTPUT")
      topic=$(derive_debate_topic "$HOOK_OUTPUT" "$COMMAND" "$PROMPT")
      format_debate_proposal "$HOOK_OUTPUT" "$topic" "$severity"
      ;;
    *)
      echo "Unknown mode: $MODE" >&2
      exit 1
      ;;
  esac
fi
