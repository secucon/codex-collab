#!/usr/bin/env bash
# display-non-consensus-choices.sh — 4-choice UI for non-consensus debate results (v2.1.0)
#
# When a debate ends without consensus (consensus_reached == false), this script
# presents the user with four actionable choices:
#
#   1. Adopt Claude's proposal
#   2. Adopt Codex's proposal
#   3. Request an additional debate round
#   4. Discard both proposals
#
# The "additional round" option respects the round cap (debate-round-cap.sh).
# Selection = approval: the user's choice of [1] or [2] IS the approval (no secondary confirmation).
# The 4-choice prompt provides sufficient context for informed decision-making.
#
# Usage:
#   # Source for shell functions:
#   source scripts/display-non-consensus-choices.sh
#   display_non_consensus_choices "$debate_result_json" "$current_round" "$session_id"
#
#   # Or run directly:
#   ./scripts/display-non-consensus-choices.sh --result '<json>' [--round <N>] [--session <id>]
#                                              [--no-color] [--response <choice>]
#
# Requires: python3, scripts/debate-round-cap.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source config loader if not already loaded
if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
  if [[ -f "${SCRIPT_DIR}/load-config.sh" ]]; then
    # shellcheck source=load-config.sh
    source "${SCRIPT_DIR}/load-config.sh"
    load_config 2>/dev/null || true
  fi
fi

# Source round cap calculator (guard against double-sourcing readonly vars)
if [[ -z "${DEBATE_ADDITIONAL_ROUNDS_HARD_CAP:-}" ]] && [[ -f "${SCRIPT_DIR}/debate-round-cap.sh" ]]; then
  # shellcheck source=debate-round-cap.sh
  source "${SCRIPT_DIR}/debate-round-cap.sh"
fi

# ---------------------------------------------------------------------------
# Color codes (disabled if --no-color or NO_COLOR env is set)
# ---------------------------------------------------------------------------
_NC_USE_COLOR="${CODEX_NC_COLOR:-true}"

_nc_reset=""
_nc_bold=""
_nc_dim=""
_nc_green=""
_nc_red=""
_nc_yellow=""
_nc_cyan=""
_nc_magenta=""
_nc_blue=""
_nc_white=""

_nc_init_colors() {
  if [[ "$_NC_USE_COLOR" == "true" ]] && [[ -z "${NO_COLOR:-}" ]] && [[ -t 1 ]]; then
    _nc_reset="\033[0m"
    _nc_bold="\033[1m"
    _nc_dim="\033[2m"
    _nc_green="\033[32m"
    _nc_red="\033[31m"
    _nc_yellow="\033[33m"
    _nc_cyan="\033[36m"
    _nc_magenta="\033[35m"
    _nc_blue="\033[34m"
    _nc_white="\033[37m"
  fi
}

# ---------------------------------------------------------------------------
# JSON value extraction (same pattern as display-consensus-result.sh)
# ---------------------------------------------------------------------------
_nc_json_val() {
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
# NON-CONSENSUS 4-CHOICE UI
# ===========================================================================

# ---------------------------------------------------------------------------
# Internal: Extract and format a side's position summary
# ---------------------------------------------------------------------------
_format_side_summary() {
  local result_json="$1"
  local side="$2"  # "claude" or "codex"

  python3 -c "
import json, sys

try:
    data = json.loads(sys.argv[1])
    side = sys.argv[2]

    # Try to extract from side-specific fields
    position = ''
    confidence = 0.0
    arguments = []

    # Check for explicit side fields
    side_key = side + '_final_position'
    position = data.get(side_key, '')
    if not position:
        side_key = side + '_position'
        position = data.get(side_key, '')

    conf_key = side + '_confidence'
    confidence = data.get(conf_key, 0.0)

    args_key = side + '_final_arguments'
    arguments = data.get(args_key, [])
    if not arguments:
        args_key = side + '_arguments'
        arguments = data.get(args_key, [])

    # Fallback: extract from rounds array
    if not position:
        rounds = data.get('rounds', data.get('round_summaries', []))
        if isinstance(rounds, list):
            for r in reversed(rounds):
                if isinstance(r, dict):
                    r_side = r.get('side', r.get('role', '')).lower()
                    if r_side == side:
                        position = r.get('position', '')
                        confidence = r.get('confidence', confidence)
                        arguments = r.get('key_arguments', arguments)
                        break

    # Fallback: use final_position for the primary side
    if not position and side == 'codex':
        position = data.get('final_position', data.get('consensus_position', ''))
    if not position and side == 'claude':
        position = data.get('claude_position', data.get('position', ''))

    # Output
    if position:
        print(position[:200])
    else:
        print('(no position recorded)')

    # Print confidence
    if confidence:
        print(f'CONFIDENCE:{confidence}')
    else:
        print('CONFIDENCE:N/A')

    # Print arguments (max 3)
    if isinstance(arguments, list):
        for arg in arguments[:3]:
            print(f'ARG:{arg}')
    elif isinstance(arguments, str) and arguments:
        print(f'ARG:{arguments}')

except Exception:
    print('(unable to extract position)')
    print('CONFIDENCE:N/A')
" "$result_json" "$side" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Internal: Format the non-consensus header
# ---------------------------------------------------------------------------
_format_nc_header() {
  local topic="$1"
  local rounds="$2"

  echo ""
  echo "╔═════════════════════════════════════════════════════════════════╗"
  echo "║  ⚖️  Debate Ended — No Consensus Reached                      ║"
  echo "╠═════════════════════════════════════════════════════════════════╣"
  echo "║  📌 Topic:  ${topic:0:50}"
  echo "║  🔄 Rounds: ${rounds}"
  echo "╚═════════════════════════════════════════════════════════════════╝"
  echo ""
}

# ---------------------------------------------------------------------------
# Internal: Format side comparison (Claude vs Codex proposals)
# ---------------------------------------------------------------------------
_format_side_comparison() {
  local result_json="$1"

  echo "───────────────────────────────────────────────────────────────────"
  echo "  📋 Competing Proposals"
  echo "───────────────────────────────────────────────────────────────────"
  echo ""

  # ---- Claude's position ----
  echo "  ┌─── 🟣 Claude's Proposal ───────────────────────────────────┐"
  local claude_output
  claude_output=$(_format_side_summary "$result_json" "claude")

  local claude_position claude_confidence
  claude_position=""
  claude_confidence=""
  local -a claude_args=()

  while IFS= read -r line; do
    if [[ "$line" == CONFIDENCE:* ]]; then
      claude_confidence="${line#CONFIDENCE:}"
    elif [[ "$line" == ARG:* ]]; then
      claude_args+=("${line#ARG:}")
    elif [[ -z "$claude_position" ]]; then
      claude_position="$line"
    fi
  done <<< "$claude_output"

  echo "  │"
  echo "  │  Position: ${claude_position}"
  echo "  │  Confidence: ${claude_confidence}"
  if [[ ${#claude_args[@]} -gt 0 ]]; then
    echo "  │  Key arguments:"
    for arg in "${claude_args[@]}"; do
      echo "  │    • ${arg}"
    done
  fi
  echo "  │"
  echo "  └─────────────────────────────────────────────────────────────┘"
  echo ""

  # ---- Codex's position ----
  echo "  ┌─── 🟢 Codex's Proposal (GPT-5.4) ─────────────────────────┐"
  local codex_output
  codex_output=$(_format_side_summary "$result_json" "codex")

  local codex_position codex_confidence
  codex_position=""
  codex_confidence=""
  local -a codex_args=()

  while IFS= read -r line; do
    if [[ "$line" == CONFIDENCE:* ]]; then
      codex_confidence="${line#CONFIDENCE:}"
    elif [[ "$line" == ARG:* ]]; then
      codex_args+=("${line#ARG:}")
    elif [[ -z "$codex_position" ]]; then
      codex_position="$line"
    fi
  done <<< "$codex_output"

  echo "  │"
  echo "  │  Position: ${codex_position}"
  echo "  │  Confidence: ${codex_confidence}"
  if [[ ${#codex_args[@]} -gt 0 ]]; then
    echo "  │  Key arguments:"
    for arg in "${codex_args[@]}"; do
      echo "  │    • ${arg}"
    done
  fi
  echo "  │"
  echo "  └─────────────────────────────────────────────────────────────┘"
  echo ""
}

# ---------------------------------------------------------------------------
# Internal: Format the choice action menu
# ---------------------------------------------------------------------------
# When additional rounds are available, shows 4 choices (including "another round").
# When max rounds are exhausted, shows exactly 3 choices (excluding "another round")
# with renumbered options: [1] Claude, [2] Codex, [3] Discard.
# ---------------------------------------------------------------------------
_format_choice_menu() {
  local current_round="$1"
  local can_add_round="$2"
  local remaining_rounds="$3"

  echo "═══════════════════════════════════════════════════════════════════"
  echo ""

  if [[ "$can_add_round" == "true" ]]; then
    # --- 4-choice menu (additional rounds available) ---
    echo "  ⚡ Choose how to proceed:"
    echo ""
    echo "    [1] 🟣 CLAUDE   — Adopt Claude's proposal"
    echo "    [2] 🟢 CODEX    — Adopt Codex's (GPT-5.4) proposal"
    echo "    [3] 🔄 ANOTHER  — Request additional debate round (${remaining_rounds} remaining)"
    echo "    [4] ❌ DISCARD  — Discard both proposals"
    echo ""
    echo "  Reply with: 1, 2, 3, or 4 (or: claude, codex, another, discard)"
  else
    # --- 3-choice menu (max rounds exhausted — "another round" excluded) ---
    echo "  ⚡ Max debate rounds exhausted — choose how to proceed:"
    echo ""
    echo "    [1] 🟣 CLAUDE   — Adopt Claude's proposal"
    echo "    [2] 🟢 CODEX    — Adopt Codex's (GPT-5.4) proposal"
    echo "    [3] ❌ DISCARD  — Discard both proposals"
    echo ""
    echo "  Reply with: 1, 2, or 3 (or: claude, codex, discard)"
  fi

  echo ""
  echo "═══════════════════════════════════════════════════════════════════"
}

# ---------------------------------------------------------------------------
# Internal: Check if additional rounds are available
# ---------------------------------------------------------------------------
_check_additional_round_available() {
  local current_round="${1:-0}"

  if ! declare -f get_effective_max_rounds &>/dev/null; then
    # Fallback if round cap script not sourced
    echo "true:2"
    return 0
  fi

  local effective_max
  effective_max=$(get_effective_max_rounds 2>/dev/null || echo "5")
  local remaining=$(( effective_max - current_round ))

  if [[ "$remaining" -gt 0 ]]; then
    echo "true:${remaining}"
  else
    echo "false:0"
  fi
}

# ===========================================================================
# PUBLIC API
# ===========================================================================

# ---------------------------------------------------------------------------
# Public: display_non_consensus_choices
# Main entry point — formats and outputs the 4-choice non-consensus UI
#
# Args:
#   result_json    — Full debate result JSON (required)
#   current_round  — Current round number (default: extracted from result)
#   session_id     — Session ID for record keeping (optional)
#
# Returns: Outputs formatted UI to stdout
# ---------------------------------------------------------------------------
display_non_consensus_choices() {
  local result_json="${1:-'{}'}"
  local current_round="${2:-0}"
  local session_id="${3:-}"

  if ! command -v python3 &>/dev/null; then
    echo "[codex-collab] Cannot display non-consensus choices (python3 required)" >&2
    return 1
  fi

  _nc_init_colors

  # Extract core fields
  local topic rounds
  topic="$(_nc_json_val "$result_json" "topic" "Unknown topic")"
  rounds="$(_nc_json_val "$result_json" "rounds" "N/A")"

  # Use extracted rounds if current_round not provided
  if [[ "$current_round" == "0" && "$rounds" != "N/A" ]]; then
    current_round="$rounds"
  fi

  # Check consensus (safety: this should only be called for non-consensus)
  local consensus_reached
  consensus_reached="$(_nc_json_val "$result_json" "consensus_reached" "false")"
  if [[ "$consensus_reached" == "true" ]]; then
    echo "[codex-collab] WARNING: display_non_consensus_choices called but consensus was reached" >&2
    echo "[codex-collab] Redirecting to consensus display..." >&2
    return 1
  fi

  # --- Non-consensus header ---
  _format_nc_header "$topic" "$rounds"

  # --- Side-by-side comparison ---
  _format_side_comparison "$result_json"

  # --- Check round cap for "another round" option ---
  local round_check can_add_round remaining_rounds
  round_check=$(_check_additional_round_available "$current_round")
  can_add_round="${round_check%%:*}"
  remaining_rounds="${round_check##*:}"

  # --- 4-choice action menu ---
  _format_choice_menu "$current_round" "$can_add_round" "$remaining_rounds"

  return 0
}

# ---------------------------------------------------------------------------
# Public: parse_non_consensus_choice
# Parses the user's response to the choice menu
#
# When can_add_round is "true": 4-choice mode
#   [1] Claude, [2] Codex, [3] Another round, [4] Discard
# When can_add_round is "false": 3-choice mode (max rounds exhausted)
#   [1] Claude, [2] Codex, [3] Discard
#   The "additional round" option is completely excluded.
#
# Args:
#   user_response — User's text input (e.g., "1", "claude", "codex", etc.)
#   can_add_round — "true" or "false" — whether additional rounds are available
#
# Returns (stdout): One of: "adopt_claude", "adopt_codex", "additional_round", "discard"
# Exit codes: 0 = valid choice, 1 = invalid/unavailable choice, 2 = unrecognized
# ---------------------------------------------------------------------------
parse_non_consensus_choice() {
  local user_response="$1"
  local can_add_round="${2:-true}"

  # Normalize to lowercase and trim
  local normalized
  normalized=$(echo "$user_response" | tr '[:upper:]' '[:lower:]' | xargs)

  local choice=""

  if [[ "$can_add_round" == "true" ]]; then
    # --- 4-choice mode: [1] Claude, [2] Codex, [3] Another, [4] Discard ---
    case "$normalized" in
      1|claude|"claude's"|"adopt claude"|"claude proposal"|클로드)
        choice="adopt_claude"
        ;;
      2|codex|"codex's"|"adopt codex"|"codex proposal"|코덱스)
        choice="adopt_codex"
        ;;
      3|another|"another round"|"additional"|"additional round"|"more"|추가)
        choice="additional_round"
        ;;
      4|discard|"discard both"|"reject"|"reject both"|"neither"|"none"|폐기|취소)
        choice="discard"
        ;;
      *)
        # Partial match fallback
        if echo "$normalized" | grep -qiE '(^1$|claude)'; then
          choice="adopt_claude"
        elif echo "$normalized" | grep -qiE '(^2$|codex)'; then
          choice="adopt_codex"
        elif echo "$normalized" | grep -qiE '(^3$|another|additional|more|round)'; then
          choice="additional_round"
        elif echo "$normalized" | grep -qiE '(^4$|discard|reject|neither|none)'; then
          choice="discard"
        else
          echo "unknown"
          return 2
        fi
        ;;
    esac
  else
    # --- 3-choice mode (max rounds exhausted): [1] Claude, [2] Codex, [3] Discard ---
    # The "additional round" option is completely excluded from the menu.
    # Number [3] now maps to "discard" instead of "another round".
    case "$normalized" in
      1|claude|"claude's"|"adopt claude"|"claude proposal"|클로드)
        choice="adopt_claude"
        ;;
      2|codex|"codex's"|"adopt codex"|"codex proposal"|코덱스)
        choice="adopt_codex"
        ;;
      3|discard|"discard both"|"reject"|"reject both"|"neither"|"none"|폐기|취소)
        choice="discard"
        ;;
      another|"another round"|"additional"|"additional round"|"more"|추가)
        # User typed a keyword for additional round, but it's not available
        echo "round_cap_exceeded"
        return 1
        ;;
      *)
        # Partial match fallback (3-choice mode)
        if echo "$normalized" | grep -qiE '(^1$|claude)'; then
          choice="adopt_claude"
        elif echo "$normalized" | grep -qiE '(^2$|codex)'; then
          choice="adopt_codex"
        elif echo "$normalized" | grep -qiE '(^3$|discard|reject|neither|none)'; then
          choice="discard"
        elif echo "$normalized" | grep -qiE '(another|additional|more round)'; then
          echo "round_cap_exceeded"
          return 1
        else
          echo "unknown"
          return 2
        fi
        ;;
    esac
  fi

  echo "$choice"
  return 0
}

# ---------------------------------------------------------------------------
# Public: create_non_consensus_record
# Creates a session history record for the non-consensus choice
#
# Args:
#   session_id  — Session ID
#   choice      — One of: adopt_claude, adopt_codex, additional_round, discard
#   topic       — Debate topic
#   round       — Current round number
#
# Returns: JSON record string
# ---------------------------------------------------------------------------
create_non_consensus_record() {
  local session_id="$1"
  local choice="$2"
  local topic="${3:-}"
  local round="${4:-0}"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  python3 -c "
import json, sys

session_id = sys.argv[1]
choice = sys.argv[2]
topic = sys.argv[3]
round_num = int(sys.argv[4]) if sys.argv[4].isdigit() else 0
timestamp = sys.argv[5]

# Map choice to approval-compatible decision
decision_map = {
    'adopt_claude': 'accepted',
    'adopt_codex': 'accepted',
    'additional_round': 'additional_round',
    'discard': 'rejected',
}

record = {
    'type': 'debate_approval',
    'session_id': session_id,
    'timestamp': timestamp,
    'decision': decision_map.get(choice, 'rejected'),
    'non_consensus_choice': choice,
    'topic': topic,
    'round': round_num,
    'applied': choice in ('adopt_claude', 'adopt_codex'),
    'adopted_side': 'claude' if choice == 'adopt_claude' else ('codex' if choice == 'adopt_codex' else None),
}

# Remove None values
record = {k: v for k, v in record.items() if v is not None}

print(json.dumps(record, ensure_ascii=False))
" "$session_id" "$choice" "$topic" "$round" "$timestamp" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Public: get_adopted_proposal
# Extracts the chosen side's proposal data from the debate result
#
# Args:
#   result_json — Full debate result JSON
#   side        — "claude" or "codex"
#
# Returns: JSON object with position, arguments, diff (if any)
# ---------------------------------------------------------------------------
get_adopted_proposal() {
  local result_json="$1"
  local side="$2"

  python3 -c "
import json, sys

try:
    data = json.loads(sys.argv[1])
    side = sys.argv[2]

    proposal = {
        'adopted_from': side,
        'position': '',
        'confidence': 0.0,
        'key_arguments': [],
        'diff': None,
        'code_changes': None,
    }

    # Extract position
    for key in [f'{side}_final_position', f'{side}_position']:
        val = data.get(key, '')
        if val:
            proposal['position'] = val
            break

    # Extract confidence
    for key in [f'{side}_confidence', f'{side}_final_confidence']:
        val = data.get(key, 0.0)
        if val:
            proposal['confidence'] = val
            break

    # Extract arguments
    for key in [f'{side}_final_arguments', f'{side}_arguments']:
        val = data.get(key, [])
        if val:
            proposal['key_arguments'] = val if isinstance(val, list) else [val]
            break

    # Extract side-specific diff/changes
    side_diff = data.get(f'{side}_diff', data.get(f'{side}_code_changes'))
    if side_diff:
        if isinstance(side_diff, str):
            proposal['diff'] = side_diff
        elif isinstance(side_diff, list):
            proposal['code_changes'] = side_diff

    # Fallback: if no position found, try round data
    if not proposal['position']:
        rounds = data.get('rounds', data.get('round_summaries', []))
        if isinstance(rounds, list):
            for r in reversed(rounds):
                if isinstance(r, dict):
                    r_side = r.get('side', r.get('role', '')).lower()
                    if r_side == side:
                        proposal['position'] = r.get('position', '')
                        proposal['confidence'] = r.get('confidence', proposal['confidence'])
                        proposal['key_arguments'] = r.get('key_arguments', proposal['key_arguments'])
                        break

    # Clean None values
    proposal = {k: v for k, v in proposal.items() if v is not None}

    print(json.dumps(proposal, ensure_ascii=False))
except Exception as e:
    print(json.dumps({'error': str(e), 'adopted_from': side}))
" "$result_json" "$side" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Public: choice_status_line
# Returns a human-readable status line for the user's non-consensus choice
#
# Args: choice — One of: adopt_claude, adopt_codex, additional_round, discard
# ---------------------------------------------------------------------------
choice_status_line() {
  local choice="$1"

  case "$choice" in
    adopt_claude)
      echo "🟣 Non-consensus resolved: Adopted Claude's proposal"
      ;;
    adopt_codex)
      echo "🟢 Non-consensus resolved: Adopted Codex's (GPT-5.4) proposal"
      ;;
    additional_round)
      echo "🔄 Non-consensus: Requesting additional debate round"
      ;;
    discard)
      echo "❌ Non-consensus: Both proposals discarded"
      ;;
    round_cap_exceeded)
      echo "⛔ Cannot add round: debate round cap reached"
      ;;
    *)
      echo "⏳ Non-consensus: Awaiting user decision"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# CLI mode — run directly
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  CLI_RESULT=""
  CLI_ROUND="0"
  CLI_SESSION="cli-test"
  CLI_NO_COLOR="false"
  CLI_RESPONSE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result)    CLI_RESULT="$2"; shift 2 ;;
      --round)     CLI_ROUND="$2"; shift 2 ;;
      --session)   CLI_SESSION="$2"; shift 2 ;;
      --response)  CLI_RESPONSE="$2"; shift 2 ;;
      --no-color)  CLI_NO_COLOR="true"; _NC_USE_COLOR="false"; shift ;;
      --help|-h)
        echo "Usage: display-non-consensus-choices.sh --result '<json>' [options]"
        echo ""
        echo "Displays the 4-choice UI for non-consensus debate results."
        echo ""
        echo "Options:"
        echo "  --result <json>    Debate result JSON (required)"
        echo "  --round <N>        Current round number (default: from result)"
        echo "  --session <id>     Session ID (default: cli-test)"
        echo "  --response <text>  Simulate user response (1-4 or name)"
        echo "  --no-color         Disable ANSI color output"
        echo ""
        echo "Choices:"
        echo "  [1] CLAUDE   — Adopt Claude's proposal"
        echo "  [2] CODEX    — Adopt Codex's (GPT-5.4) proposal"
        echo "  [3] ANOTHER  — Request additional debate round"
        echo "  [4] DISCARD  — Discard both proposals"
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$CLI_RESULT" ]]; then
    echo "Error: --result is required" >&2
    echo "Usage: display-non-consensus-choices.sh --result '<json>'" >&2
    exit 1
  fi

  # Display the 4-choice UI
  display_non_consensus_choices "$CLI_RESULT" "$CLI_ROUND" "$CLI_SESSION"

  # If user response provided (testing mode), process it
  if [[ -n "$CLI_RESPONSE" ]]; then
    echo ""

    # Determine round cap availability
    round_check=$(_check_additional_round_available "$CLI_ROUND")
    can_add="${round_check%%:*}"

    echo "[codex-collab] User response: $CLI_RESPONSE"
    CHOICE=$(parse_non_consensus_choice "$CLI_RESPONSE" "$can_add" || true)
    echo "[codex-collab] Choice: $CHOICE"
    echo "$(choice_status_line "$CHOICE")"

    # Create record
    if [[ "$CHOICE" != "unknown" && "$CHOICE" != "round_cap_exceeded" ]]; then
      TOPIC=$(_nc_json_val "$CLI_RESULT" "topic" "")
      RECORD=$(create_non_consensus_record "$CLI_SESSION" "$CHOICE" "$TOPIC" "$CLI_ROUND")
      echo "[codex-collab] Record: $RECORD"
    fi

    # If a side was adopted, extract proposal
    if [[ "$CHOICE" == "adopt_claude" || "$CHOICE" == "adopt_codex" ]]; then
      SIDE="${CHOICE#adopt_}"
      PROPOSAL=$(get_adopted_proposal "$CLI_RESULT" "$SIDE")
      echo "[codex-collab] Adopted proposal: $PROPOSAL"
    fi

    case "$CHOICE" in
      adopt_claude|adopt_codex) exit 0 ;;
      additional_round)         exit 0 ;;
      discard)                  exit 1 ;;
      round_cap_exceeded)       exit 1 ;;
      *)                        exit 2 ;;
    esac
  fi
fi
