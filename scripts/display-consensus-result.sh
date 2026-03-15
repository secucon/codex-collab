#!/usr/bin/env bash
# display-consensus-result.sh — codex-collab consensus result display UI (v2.1.0)
#
# Displays the consensus result from a /codex-debate session, showing:
#   1. Consensus header (topic, rounds, confidence)
#   2. Diff section — proposed code changes from consensus
#   3. Rationale section — reasoning summary from both sides
#   4. Action prompt — user approval for applying changes
#
# Usage:
#   # Source for shell functions:
#   source scripts/display-consensus-result.sh
#   display_consensus_result "$debate_result_json"
#
#   # Or run directly:
#   ./scripts/display-consensus-result.sh --result '<json>' [--show-diff] [--show-rationale]
#                                          [--format compact|full] [--no-color]
#
# Requires: python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source config loader if not already loaded
if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
  if [[ -f "${SCRIPT_DIR}/load-config.sh" ]]; then
    # shellcheck source=load-config.sh
    source "${SCRIPT_DIR}/load-config.sh"
  fi
fi

# ---------------------------------------------------------------------------
# Color codes (disabled if --no-color or NO_COLOR env is set)
# ---------------------------------------------------------------------------
_CONSENSUS_USE_COLOR="${CODEX_CONSENSUS_COLOR:-true}"

_c_reset=""
_c_bold=""
_c_dim=""
_c_green=""
_c_red=""
_c_yellow=""
_c_cyan=""
_c_magenta=""
_c_blue=""

_init_colors() {
  if [[ "$_CONSENSUS_USE_COLOR" == "true" ]] && [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    _c_reset="\033[0m"
    _c_bold="\033[1m"
    _c_dim="\033[2m"
    _c_green="\033[32m"
    _c_red="\033[31m"
    _c_yellow="\033[33m"
    _c_cyan="\033[36m"
    _c_magenta="\033[35m"
    _c_blue="\033[34m"
  fi
}

# ---------------------------------------------------------------------------
# JSON value extraction (reuse pattern from status-summary.sh)
# ---------------------------------------------------------------------------
_consensus_json_val() {
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
        elif isinstance(current, list):
            try:
                current = current[int(k)]
            except (ValueError, IndexError):
                print(sys.argv[3] if len(sys.argv) > 3 else '')
                sys.exit(0)
        else:
            print(sys.argv[3] if len(sys.argv) > 3 else '')
            sys.exit(0)
    if current is None:
        print(sys.argv[3] if len(sys.argv) > 3 else '')
    elif isinstance(current, bool):
        print('true' if current else 'false')
    elif isinstance(current, (list, dict)):
        print(json.dumps(current, ensure_ascii=False))
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
# CONSENSUS RESULT DISPLAY
# ===========================================================================

# ---------------------------------------------------------------------------
# Internal: Format the consensus header block
# ---------------------------------------------------------------------------
_format_consensus_header() {
  local topic="$1"
  local rounds="$2"
  local consensus_reached="$3"
  local final_confidence="$4"

  local consensus_icon consensus_label
  if [[ "$consensus_reached" == "true" ]]; then
    consensus_icon="✅"
    consensus_label="Consensus Reached"
  else
    consensus_icon="⚖️"
    consensus_label="No Consensus — Both Positions Presented"
  fi

  echo ""
  echo "┌─────────────────────────────────────────────────────────────┐"
  echo "│  ${consensus_icon} ${consensus_label}"
  echo "├─────────────────────────────────────────────────────────────┤"
  echo "│  📌 Topic:      ${topic:0:50}"
  echo "│  🔄 Rounds:     ${rounds}"
  echo "│  📊 Confidence: ${final_confidence}"
  echo "└─────────────────────────────────────────────────────────────┘"
  echo ""
}

# ---------------------------------------------------------------------------
# Internal: Format the diff (code changes) section
# ---------------------------------------------------------------------------
_format_diff_section() {
  local result_json="$1"

  # Extract diff from consensus result
  # The diff can come from:
  #   - result.diff (direct diff string)
  #   - result.code_changes (array of file changes)
  #   - result.final_position (contains code suggestions in text)

  local has_diff="false"

  # Check for explicit diff field
  local diff_content
  diff_content="$(_consensus_json_val "$result_json" "diff" "")"
  if [[ -n "$diff_content" && "$diff_content" != "null" ]]; then
    has_diff="true"
    echo "### 📝 Proposed Changes (Diff)"
    echo ""
    echo '```diff'
    echo "$diff_content"
    echo '```'
    echo ""
    return 0
  fi

  # Check for code_changes array
  local code_changes
  code_changes="$(_consensus_json_val "$result_json" "code_changes" "")"
  if [[ -n "$code_changes" && "$code_changes" != "null" && "$code_changes" != "[]" ]]; then
    has_diff="true"
    echo "### 📝 Proposed Changes"
    echo ""

    # Parse code_changes array with python3
    python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    changes = data.get('code_changes', [])
    if isinstance(changes, list):
        for i, change in enumerate(changes, 1):
            if isinstance(change, dict):
                file_path = change.get('file', change.get('path', 'unknown'))
                action = change.get('action', change.get('type', 'modify'))
                description = change.get('description', change.get('summary', ''))
                diff = change.get('diff', change.get('content', ''))

                print(f'**{i}. {file_path}** ({action})')
                if description:
                    print(f'   {description}')
                if diff:
                    print()
                    print('\`\`\`diff')
                    print(diff)
                    print('\`\`\`')
                print()
            elif isinstance(change, str):
                print(f'- {change}')
    elif isinstance(changes, str):
        print('\`\`\`diff')
        print(changes)
        print('\`\`\`')
except Exception as e:
    print(f'(unable to parse code changes: {e})')
" "$result_json" 2>/dev/null
    echo ""
    return 0
  fi

  # Fallback: extract code suggestions from final_position
  local final_position
  final_position="$(_consensus_json_val "$result_json" "final_position" "")"
  if [[ -n "$final_position" && "$final_position" != "null" ]]; then
    # Check if position contains code-like content
    if echo "$final_position" | grep -qE '(function |class |import |const |let |var |def |=>|\{|\}|\.js|\.ts|\.py)'; then
      has_diff="true"
      echo "### 📝 Proposed Approach"
      echo ""
      echo '```'
      echo "$final_position"
      echo '```'
      echo ""
      return 0
    fi
  fi

  # No code changes found — show "no diff" message
  if [[ "$has_diff" == "false" ]]; then
    echo "### 📝 Proposed Changes"
    echo ""
    echo "_No code changes produced — this debate focused on architectural/design decisions._"
    echo "_See the rationale below for the agreed-upon approach._"
    echo ""
  fi
}

# ---------------------------------------------------------------------------
# Internal: Format the rationale (reasoning summary) section
# ---------------------------------------------------------------------------
_format_rationale_section() {
  local result_json="$1"

  echo "### 💡 Rationale (Reasoning Summary)"
  echo ""

  # Extract consensus rationale from structured result
  python3 -c "
import json, sys

try:
    data = json.loads(sys.argv[1])

    # --- Final consensus position ---
    final_position = data.get('final_position', data.get('consensus_position', ''))
    if final_position:
        print('**Agreed Position:**')
        print(f'> {final_position}')
        print()

    # --- Key arguments from both sides ---
    # Codex's final arguments
    codex_args = data.get('codex_final_arguments', data.get('codex_arguments', []))
    claude_args = data.get('claude_final_arguments', data.get('claude_arguments', []))

    if codex_args or claude_args:
        print('**Supporting Arguments:**')
        print()

    if codex_args:
        if isinstance(codex_args, list):
            print('_From Codex (GPT-5.4):_')
            for arg in codex_args:
                print(f'  - {arg}')
            print()
        elif isinstance(codex_args, str):
            print(f'_From Codex (GPT-5.4):_ {codex_args}')
            print()

    if claude_args:
        if isinstance(claude_args, list):
            print('_From Claude:_')
            for arg in claude_args:
                print(f'  - {arg}')
            print()
        elif isinstance(claude_args, str):
            print(f'_From Claude:_ {claude_args}')
            print()

    # --- Convergence path ---
    rounds = data.get('rounds', data.get('round_summaries', []))
    if isinstance(rounds, list) and len(rounds) > 0:
        print('**Convergence Path:**')
        for i, r in enumerate(rounds, 1):
            if isinstance(r, dict):
                pos = r.get('position', r.get('summary', ''))
                conf = r.get('confidence', '')
                side = r.get('side', r.get('role', 'Codex'))
                agreed = r.get('agrees_with_opponent', False)
                marker = ' ✓' if agreed else ''
                conf_str = f' (confidence: {conf})' if conf else ''
                print(f'  Round {i}: {side} — {pos}{conf_str}{marker}')
            elif isinstance(r, str):
                print(f'  Round {i}: {r}')
        print()

    # --- Key arguments from debate (fallback from per-round data) ---
    key_args = data.get('key_arguments', [])
    if isinstance(key_args, list) and key_args and not codex_args and not claude_args:
        print('**Key Arguments:**')
        for arg in key_args:
            print(f'  - {arg}')
        print()

    # --- Counterpoints that shaped consensus ---
    counterpoints = data.get('decisive_counterpoints', data.get('key_counterpoints', []))
    if isinstance(counterpoints, list) and counterpoints:
        print('**Decisive Counterpoints:**')
        for cp in counterpoints:
            print(f'  - {cp}')
        print()

    # --- Recommendation ---
    recommendation = data.get('recommendation', data.get('user_guidance', ''))
    if recommendation:
        print('**Recommendation for User:**')
        if isinstance(recommendation, list):
            for rec in recommendation:
                print(f'  - {rec}')
        else:
            print(f'  {recommendation}')
        print()

    # Fallback: if no structured fields found, show the raw final position
    if not final_position and not codex_args and not claude_args and not key_args:
        # Try to extract from position field of last round
        position = data.get('position', '')
        key_arguments = data.get('key_arguments', [])
        if position:
            print('**Final Position:**')
            print(f'> {position}')
            print()
        if isinstance(key_arguments, list) and key_arguments:
            print('**Key Arguments:**')
            for arg in key_arguments:
                print(f'  - {arg}')
            print()

except Exception as e:
    print(f'(unable to parse rationale: {e})')
" "$result_json" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Internal: Format approval prompt section
# ---------------------------------------------------------------------------
_format_approval_prompt() {
  local consensus_reached="$1"
  local has_code_changes="$2"
  local auto_apply="$3"

  echo "---"
  echo ""

  if [[ "$consensus_reached" == "true" && "$has_code_changes" == "true" ]]; then
    if [[ "$auto_apply" == "true" ]]; then
      echo "⚠️  **Auto-apply is enabled** (debate.auto_apply_result: true)"
      echo "The above changes require your approval before being applied."
      echo ""
      echo "**Do you want to apply these changes?**"
      echo "  → Reply **yes** to apply the consensus changes"
      echo "  → Reply **no** to discard (changes will be saved in session history)"
      echo "  → Reply **edit** to modify before applying"
    else
      echo "💬 **Review the consensus result above.**"
      echo "  → To apply changes, use: \`/codex-ask apply the debate consensus\`"
      echo "  → The full debate is saved in your session history"
    fi
  elif [[ "$consensus_reached" == "true" ]]; then
    echo "💬 **Consensus reached.** The agreed approach is documented above."
    echo "  → Use the rationale to guide your implementation"
    echo "  → The full debate is saved in your session history"
  else
    echo "⚖️  **No consensus was reached.** Use the 4-choice menu below to decide."
    echo "  → The non-consensus choice UI will be displayed with all options"
    echo "  → You can adopt either side's proposal, request another round, or discard both"
    echo "  → The full debate is saved in your session history"
  fi
  echo ""
}

# ===========================================================================
# PUBLIC API
# ===========================================================================

# ---------------------------------------------------------------------------
# Public: display_consensus_result
# Main entry point — formats and outputs the complete consensus result UI
#
# Args:
#   result_json   — Full debate result JSON (required)
#   format        — "compact" or "full" (default: full)
#   show_diff     — "true" or "false" (default: true)
#   show_rationale — "true" or "false" (default: true)
#
# The result_json should contain structured debate result with fields like:
#   - topic: debate topic string
#   - rounds: number of rounds completed
#   - consensus_reached: boolean
#   - final_position / consensus_position: agreed position text
#   - diff / code_changes: proposed code changes (if any)
#   - codex_final_arguments / claude_final_arguments: key arguments
#   - recommendation: user guidance
#   - confidence: final confidence score
# ---------------------------------------------------------------------------
display_consensus_result() {
  local result_json="${1:-'{}'}"
  local format="${2:-full}"
  local show_diff="${3:-true}"
  local show_rationale="${4:-true}"

  if ! command -v python3 &>/dev/null; then
    echo "[codex-collab] ⚠ Cannot display consensus result (python3 required)"
    return 1
  fi

  _init_colors

  # Extract core fields
  local topic rounds consensus_reached final_confidence auto_apply
  topic="$(_consensus_json_val "$result_json" "topic" "Unknown topic")"
  rounds="$(_consensus_json_val "$result_json" "rounds" "N/A")"
  consensus_reached="$(_consensus_json_val "$result_json" "consensus_reached" "false")"
  final_confidence="$(_consensus_json_val "$result_json" "confidence" "N/A")"

  # Check auto_apply config
  auto_apply="false"
  if declare -f config_get &>/dev/null; then
    auto_apply="$(config_get 'debate.auto_apply_result' 'false')"
  fi
  auto_apply="${CODEX_DEBATE_AUTO_APPLY:-$auto_apply}"

  # --- Header ---
  _format_consensus_header "$topic" "$rounds" "$consensus_reached" "$final_confidence"

  # --- Diff Section ---
  local has_code_changes="false"
  if [[ "$show_diff" == "true" ]]; then
    # Detect if there are code changes
    local diff_check code_changes_check
    diff_check="$(_consensus_json_val "$result_json" "diff" "")"
    code_changes_check="$(_consensus_json_val "$result_json" "code_changes" "")"
    if [[ -n "$diff_check" && "$diff_check" != "null" ]] || \
       [[ -n "$code_changes_check" && "$code_changes_check" != "null" && "$code_changes_check" != "[]" ]]; then
      has_code_changes="true"
    fi
    _format_diff_section "$result_json"
  fi

  # --- Rationale Section ---
  if [[ "$show_rationale" == "true" ]]; then
    _format_rationale_section "$result_json"
  fi

  # --- Compact mode: skip approval prompt ---
  if [[ "$format" == "compact" ]]; then
    return 0
  fi

  # --- Approval Prompt (full mode only) ---
  _format_approval_prompt "$consensus_reached" "$has_code_changes" "$auto_apply"

  return 0
}

# ---------------------------------------------------------------------------
# Public: format_consensus_for_history
# Creates a compact summary suitable for session history storage
#
# Args: result_json
# Returns: single-line JSON summary
# ---------------------------------------------------------------------------
format_consensus_for_history() {
  local result_json="${1:-'{}'}"

  python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    summary = {
        'topic': data.get('topic', '')[:100],
        'rounds': data.get('rounds', 0),
        'consensus_reached': data.get('consensus_reached', False),
        'confidence': data.get('confidence', 0),
        'final_position': (data.get('final_position', data.get('consensus_position', '')))[:200],
        'has_code_changes': bool(data.get('diff') or data.get('code_changes')),
    }
    print(json.dumps(summary, ensure_ascii=False))
except Exception:
    print('{}')
" "$result_json" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Public: extract_consensus_from_rounds
# Builds a consensus result JSON from raw debate round data
# Used when the debate produces per-round JSONL but no explicit consensus result
#
# Args:
#   rounds_json — JSON array of round objects (each with position, confidence, etc.)
#   topic       — debate topic string
# Returns: Full consensus result JSON
# ---------------------------------------------------------------------------
extract_consensus_from_rounds() {
  local rounds_json="${1:-'[]'}"
  local topic="${2:-}"

  python3 -c "
import json, sys

try:
    rounds = json.loads(sys.argv[1])
    topic = sys.argv[2] if len(sys.argv) > 2 else ''

    if not isinstance(rounds, list) or len(rounds) == 0:
        print(json.dumps({'topic': topic, 'rounds': 0, 'consensus_reached': False}))
        sys.exit(0)

    # Find last round and check consensus
    last_round = rounds[-1]
    consensus_reached = False
    for r in rounds:
        if isinstance(r, dict) and r.get('agrees_with_opponent', False):
            consensus_reached = True
            break

    # Build result
    result = {
        'topic': topic,
        'rounds': len(rounds),
        'consensus_reached': consensus_reached,
        'confidence': last_round.get('confidence', 0) if isinstance(last_round, dict) else 0,
        'final_position': last_round.get('position', '') if isinstance(last_round, dict) else '',
        'key_arguments': last_round.get('key_arguments', []) if isinstance(last_round, dict) else [],
        'round_summaries': [],
    }

    # Build round summaries
    for i, r in enumerate(rounds):
        if isinstance(r, dict):
            summary = {
                'round': i + 1,
                'position': r.get('position', ''),
                'confidence': r.get('confidence', 0),
                'agrees_with_opponent': r.get('agrees_with_opponent', False),
            }
            result['round_summaries'].append(summary)

    print(json.dumps(result, ensure_ascii=False))
except Exception as e:
    print(json.dumps({'topic': topic if 'topic' in dir() else '', 'rounds': 0, 'consensus_reached': False, 'error': str(e)}))
" "$rounds_json" "$topic" 2>/dev/null
}

# ---------------------------------------------------------------------------
# CLI mode — run directly
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  CLI_RESULT=""
  CLI_FORMAT="full"
  CLI_SHOW_DIFF="true"
  CLI_SHOW_RATIONALE="true"
  CLI_NO_COLOR="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result)         CLI_RESULT="$2"; shift 2 ;;
      --format)         CLI_FORMAT="$2"; shift 2 ;;
      --show-diff)      CLI_SHOW_DIFF="true"; shift ;;
      --no-diff)        CLI_SHOW_DIFF="false"; shift ;;
      --show-rationale) CLI_SHOW_RATIONALE="true"; shift ;;
      --no-rationale)   CLI_SHOW_RATIONALE="false"; shift ;;
      --no-color)       CLI_NO_COLOR="true"; _CONSENSUS_USE_COLOR="false"; shift ;;
      --help|-h)
        echo "Usage: display-consensus-result.sh --result '<json>' [options]"
        echo ""
        echo "Displays the consensus result from a codex-collab debate."
        echo ""
        echo "Options:"
        echo "  --result <json>    Debate result JSON (required)"
        echo "  --format <fmt>     'full' (default) or 'compact'"
        echo "  --show-diff        Show code changes section (default)"
        echo "  --no-diff          Hide code changes section"
        echo "  --show-rationale   Show reasoning summary (default)"
        echo "  --no-rationale     Hide reasoning summary"
        echo "  --no-color         Disable ANSI color output"
        echo ""
        echo "The result JSON should contain fields like:"
        echo "  topic, rounds, consensus_reached, confidence,"
        echo "  final_position, diff, code_changes,"
        echo "  codex_final_arguments, claude_final_arguments,"
        echo "  recommendation"
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$CLI_RESULT" ]]; then
    echo "Error: --result is required" >&2
    echo "Usage: display-consensus-result.sh --result '<json>'" >&2
    exit 1
  fi

  display_consensus_result "$CLI_RESULT" "$CLI_FORMAT" "$CLI_SHOW_DIFF" "$CLI_SHOW_RATIONALE"
fi
