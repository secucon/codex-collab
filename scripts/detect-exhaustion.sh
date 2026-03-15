#!/usr/bin/env bash
# detect-exhaustion.sh — Max-round exhaustion detection for debate/session (v2.1.0)
#
# Identifies when a debate or session has reached its configured maximum rounds
# and triggers the exhaustion flow. This transitions the debate from the round
# loop into the result presentation phase.
#
# Exhaustion occurs when:
#   current_round >= effective_max_rounds (default_rounds + max_additional_rounds)
#
# The exhaustion flow:
#   1. Detect that the round limit has been reached
#   2. Determine whether consensus was achieved (or not) during the rounds
#   3. Output structured exhaustion state for the orchestrator
#   4. Signal whether to present 4-choice handler (non-consensus) or approval (consensus)
#
# Usage:
#   # Source for shell functions:
#   source scripts/detect-exhaustion.sh
#
#   # Check exhaustion state (returns JSON):
#   state_json=$(check_exhaustion "$current_round" "$consensus_reached")
#
#   # Quick boolean check:
#   if is_exhausted "$current_round"; then
#     echo "Rounds exhausted"
#   fi
#
#   # Full pipeline detection with debate context:
#   result_json=$(detect_round_exhaustion "$current_round" "$consensus_reached" \
#                   "$topic" "$session_id" "$rounds_json")
#
#   # Or run directly:
#   ./scripts/detect-exhaustion.sh --round <N> [--consensus true|false] \
#       [--topic <topic>] [--session <id>]
#
# Dependencies:
#   - scripts/debate-round-cap.sh  (get_effective_max_rounds, get_default_rounds, etc.)
#   - scripts/load-config.sh       (config_get)
#   - python3                      (JSON output)
#
# Exit codes:
#   0 — exhaustion detected (rounds are at or past max)
#   1 — not exhausted (rounds remain)
#   2 — error (invalid input, missing deps)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Source dependencies (skip if already loaded to avoid readonly conflicts)
# ---------------------------------------------------------------------------
if ! declare -F get_effective_max_rounds &>/dev/null; then
  if [[ -f "${SCRIPT_DIR}/debate-round-cap.sh" ]]; then
    source "${SCRIPT_DIR}/debate-round-cap.sh"
  fi
fi

# ---------------------------------------------------------------------------
# is_exhausted — Quick boolean check: has the round limit been reached?
# ---------------------------------------------------------------------------
# Args:
#   $1 — current round number (1-based)
#
# Returns:
#   0 (true)  — rounds exhausted, no more rounds possible
#   1 (false) — rounds remain
#   2         — error
# ---------------------------------------------------------------------------
is_exhausted() {
  local current_round="${1:?Usage: is_exhausted <current_round>}"

  # Validate input
  if ! [[ "$current_round" =~ ^[0-9]+$ ]]; then
    echo "[codex-collab] ERROR: current_round must be a positive integer, got: ${current_round}" >&2
    return 2
  fi

  local effective_max
  effective_max=$(get_effective_max_rounds 2>/dev/null || echo "5")

  if [[ "$current_round" -ge "$effective_max" ]]; then
    return 0  # exhausted
  else
    return 1  # not exhausted
  fi
}

# ---------------------------------------------------------------------------
# get_exhaustion_reason — Human-readable reason for exhaustion
# ---------------------------------------------------------------------------
# Args:
#   $1 — current round number
#
# Returns:
#   Reason string to stdout
# ---------------------------------------------------------------------------
get_exhaustion_reason() {
  local current_round="${1:-0}"

  local effective_max default_rounds max_additional
  effective_max=$(get_effective_max_rounds 2>/dev/null || echo "5")
  default_rounds=$(get_default_rounds 2>/dev/null || echo "3")
  max_additional=$(get_max_additional_rounds 2>/dev/null || echo "2")

  local additional_used=$(( current_round - default_rounds ))
  if [[ "$additional_used" -lt 0 ]]; then
    additional_used=0
  fi

  if [[ "$current_round" -ge "$effective_max" ]]; then
    if [[ "$additional_used" -ge "$max_additional" ]]; then
      echo "Maximum rounds reached (${current_round}/${effective_max}): ${default_rounds} default + ${additional_used} additional rounds used (hard cap: ${DEBATE_ADDITIONAL_ROUNDS_HARD_CAP:-2})"
    else
      echo "Maximum rounds reached (${current_round}/${effective_max})"
    fi
  else
    local remaining=$(( effective_max - current_round ))
    echo "Not exhausted: ${remaining} round(s) remaining (${current_round}/${effective_max})"
  fi
}

# ---------------------------------------------------------------------------
# check_exhaustion — Check exhaustion state and return structured JSON
# ---------------------------------------------------------------------------
# Args:
#   $1 — current round number (1-based)
#   $2 — consensus reached? ("true" or "false")
#
# Returns:
#   JSON object to stdout with exhaustion state
# ---------------------------------------------------------------------------
check_exhaustion() {
  local current_round="${1:?Usage: check_exhaustion <current_round> <consensus_reached>}"
  local consensus_reached="${2:-false}"

  # Validate inputs
  if ! [[ "$current_round" =~ ^[0-9]+$ ]]; then
    echo '{"error":"current_round must be a positive integer","exhausted":false}' >&2
    return 2
  fi

  local effective_max default_rounds max_additional
  effective_max=$(get_effective_max_rounds 2>/dev/null || echo "5")
  default_rounds=$(get_default_rounds 2>/dev/null || echo "3")
  max_additional=$(get_max_additional_rounds 2>/dev/null || echo "2")

  local exhausted="false"
  local remaining=0
  local additional_used=0
  local additional_remaining=0

  if [[ "$current_round" -ge "$effective_max" ]]; then
    exhausted="true"
    remaining=0
  else
    remaining=$(( effective_max - current_round ))
  fi

  additional_used=$(( current_round - default_rounds ))
  if [[ "$additional_used" -lt 0 ]]; then
    additional_used=0
  fi
  additional_remaining=$(( max_additional - additional_used ))
  if [[ "$additional_remaining" -lt 0 ]]; then
    additional_remaining=0
  fi

  # Determine the next action based on exhaustion + consensus state
  local next_action="continue_round"
  local next_action_detail=""

  if [[ "$exhausted" == "true" ]]; then
    if [[ "$consensus_reached" == "true" ]]; then
      next_action="present_consensus"
      next_action_detail="Consensus reached at max rounds — display consensus result with approval prompt"
    else
      next_action="present_non_consensus_choices"
      next_action_detail="Max rounds exhausted without consensus — present 4-choice handler (continue option disabled)"
    fi
  elif [[ "$consensus_reached" == "true" ]]; then
    next_action="present_consensus"
    next_action_detail="Consensus reached before max rounds — display consensus result with approval prompt"
  fi

  python3 -c "
import json, sys

state = {
    'exhausted': sys.argv[1] == 'true',
    'current_round': int(sys.argv[2]),
    'effective_max_rounds': int(sys.argv[3]),
    'default_rounds': int(sys.argv[4]),
    'max_additional_rounds': int(sys.argv[5]),
    'additional_rounds_hard_cap': 2,
    'rounds_remaining': int(sys.argv[6]),
    'additional_rounds_used': int(sys.argv[7]),
    'additional_rounds_remaining': int(sys.argv[8]),
    'consensus_reached': sys.argv[9] == 'true',
    'next_action': sys.argv[10],
    'next_action_detail': sys.argv[11],
    'reason': sys.argv[12],
}

print(json.dumps(state, ensure_ascii=False))
" "$exhausted" "$current_round" "$effective_max" "$default_rounds" \
  "$max_additional" "$remaining" "$additional_used" "$additional_remaining" \
  "$consensus_reached" "$next_action" "$next_action_detail" \
  "$(get_exhaustion_reason "$current_round")"
}

# ---------------------------------------------------------------------------
# detect_round_exhaustion — Full pipeline detection with debate context
# ---------------------------------------------------------------------------
# Called at the end of each round in the debate loop. Checks whether the
# debate should exit the round loop and transition to result presentation.
#
# Args:
#   $1 — current round number (1-based, AFTER this round completed)
#   $2 — consensus reached? ("true" or "false")
#   $3 — debate topic (optional, for logging)
#   $4 — session ID (optional, for logging)
#   $5 — rounds JSON (optional, stringified array of round summaries)
#
# Returns:
#   JSON object to stdout with full exhaustion context
#   Exit code: 0 if exhausted, 1 if not, 2 on error
# ---------------------------------------------------------------------------
detect_round_exhaustion() {
  local current_round="${1:?Usage: detect_round_exhaustion <round> <consensus> [topic] [session] [rounds_json]}"
  local consensus_reached="${2:-false}"
  local topic="${3:-}"
  local session_id="${4:-unknown}"
  local rounds_json="${5:-[]}"

  # Get base exhaustion state
  local base_state
  base_state=$(check_exhaustion "$current_round" "$consensus_reached")

  local exhausted
  exhausted=$(python3 -c "import json,sys; print('true' if json.loads(sys.argv[1]).get('exhausted') else 'false')" "$base_state" 2>/dev/null || echo "false")

  local next_action
  next_action=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('next_action','continue_round'))" "$base_state" 2>/dev/null || echo "continue_round")

  # Enhance with debate context
  python3 -c "
import json, sys

base = json.loads(sys.argv[1])
topic = sys.argv[2]
session_id = sys.argv[3]
rounds_json_str = sys.argv[4]

# Add debate context
base['topic'] = topic
base['session_id'] = session_id

# Parse rounds summary for convergence trend
try:
    rounds = json.loads(rounds_json_str) if rounds_json_str else []
except:
    rounds = []

base['total_rounds_completed'] = len(rounds) if rounds else base['current_round']

# Analyze convergence trend from rounds if available
if len(rounds) >= 2:
    confidences = []
    for r in rounds:
        if isinstance(r, dict):
            # Check for agrees_with_opponent in codex or claude turn
            for side in ['codex', 'claude']:
                side_data = r.get(side, r)
                if isinstance(side_data, dict):
                    conf = side_data.get('confidence')
                    if conf is not None:
                        confidences.append(float(conf))

    if len(confidences) >= 2:
        # Check trend: are confidences converging (decreasing spread)?
        first_half = confidences[:len(confidences)//2]
        second_half = confidences[len(confidences)//2:]
        avg_first = sum(first_half) / len(first_half)
        avg_second = sum(second_half) / len(second_half)

        if avg_second < avg_first - 0.05:
            base['confidence_trend'] = 'decreasing'
        elif avg_second > avg_first + 0.05:
            base['confidence_trend'] = 'increasing'
        else:
            base['confidence_trend'] = 'stable'
    else:
        base['confidence_trend'] = 'insufficient_data'
else:
    base['confidence_trend'] = 'insufficient_data'

# Generate user-facing message based on state
if base['exhausted'] and not base['consensus_reached']:
    base['user_message'] = (
        f\"최대 라운드 도달 ({base['current_round']}/{base['effective_max_rounds']}): \"
        f\"합의에 도달하지 못했습니다. 결과를 검토하고 선택해주세요.\"
    )
    base['user_message_en'] = (
        f\"Max rounds reached ({base['current_round']}/{base['effective_max_rounds']}): \"
        f\"No consensus reached. Please review the results and choose how to proceed.\"
    )
elif base['exhausted'] and base['consensus_reached']:
    base['user_message'] = (
        f\"최대 라운드에서 합의 도달 ({base['current_round']}/{base['effective_max_rounds']}): \"
        f\"양측이 합의에 도달했습니다.\"
    )
    base['user_message_en'] = (
        f\"Consensus reached at max rounds ({base['current_round']}/{base['effective_max_rounds']}): \"
        f\"Both sides have reached agreement.\"
    )
elif base['consensus_reached']:
    base['user_message'] = (
        f\"조기 합의 도달 (라운드 {base['current_round']}/{base['effective_max_rounds']}): \"
        f\"양측이 합의에 도달했습니다.\"
    )
    base['user_message_en'] = (
        f\"Early consensus reached (round {base['current_round']}/{base['effective_max_rounds']}): \"
        f\"Both sides have reached agreement.\"
    )
else:
    remaining = base['rounds_remaining']
    base['user_message'] = f\"토론 진행 중 — {remaining}라운드 남음\"
    base['user_message_en'] = f\"Debate in progress — {remaining} round(s) remaining\"

print(json.dumps(base, ensure_ascii=False))
" "$base_state" "$topic" "$session_id" "$rounds_json"

  # Return exit code based on whether debate should exit the round loop
  if [[ "$exhausted" == "true" ]] || [[ "$consensus_reached" == "true" ]]; then
    return 0  # Exit round loop
  else
    return 1  # Continue round loop
  fi
}

# ---------------------------------------------------------------------------
# format_exhaustion_notice — Display a formatted exhaustion notice to user
# ---------------------------------------------------------------------------
# Called when the debate exits the round loop due to max rounds being reached
# without consensus. Provides context before the 4-choice handler is shown.
#
# Args:
#   $1 — exhaustion state JSON (from check_exhaustion or detect_round_exhaustion)
#
# Output:
#   Formatted notice to stdout
# ---------------------------------------------------------------------------
format_exhaustion_notice() {
  local state_json="${1:?Usage: format_exhaustion_notice <state_json>}"

  python3 -c "
import json, sys

try:
    state = json.loads(sys.argv[1])
except json.JSONDecodeError:
    print('[codex-collab] ERROR: Invalid exhaustion state JSON', file=sys.stderr)
    sys.exit(1)

exhausted = state.get('exhausted', False)
consensus = state.get('consensus_reached', False)
current = state.get('current_round', 0)
effective_max = state.get('effective_max_rounds', 5)
default_rounds = state.get('default_rounds', 3)
additional_used = state.get('additional_rounds_used', 0)
max_additional = state.get('max_additional_rounds', 2)
topic = state.get('topic', '')
confidence_trend = state.get('confidence_trend', 'unknown')

if exhausted and not consensus:
    print()
    print('┌─────────────────────────────────────────────────────────────┐')
    print('│  ⏱️  Maximum Debate Rounds Exhausted                        │')
    print('├─────────────────────────────────────────────────────────────┤')
    print(f'│  Rounds completed: {current} of {effective_max} maximum               │')
    print(f'│  Default rounds:   {default_rounds}                                       │')
    print(f'│  Additional used:  {additional_used} of {max_additional} (hard cap: 2)                 │')
    if topic:
        # Truncate topic for display
        display_topic = topic[:45] + '...' if len(topic) > 45 else topic
        print(f'│  Topic: {display_topic:<50} │')
    if confidence_trend != 'insufficient_data':
        trend_icon = {'increasing': '📈', 'decreasing': '📉', 'stable': '➡️'}.get(confidence_trend, '❓')
        print(f'│  Confidence trend: {trend_icon} {confidence_trend:<38} │')
    print('│                                                             │')
    print('│  No consensus was reached within the allowed rounds.        │')
    print('│  Please review both proposals and choose how to proceed.    │')
    print('└─────────────────────────────────────────────────────────────┘')
    print()
    print(f'[codex-collab] EXHAUSTION_DETECTED=true')
    print(f'[codex-collab] EXHAUSTION_ROUND={current}')
    print(f'[codex-collab] EXHAUSTION_MAX={effective_max}')
    print(f'[codex-collab] EXHAUSTION_CONSENSUS=false')
    print(f'[codex-collab] EXHAUSTION_NEXT_ACTION=present_non_consensus_choices')

elif exhausted and consensus:
    print()
    print(f'[codex-collab] ✓ Consensus reached at round {current} (maximum round)')
    print(f'[codex-collab] EXHAUSTION_DETECTED=true')
    print(f'[codex-collab] EXHAUSTION_ROUND={current}')
    print(f'[codex-collab] EXHAUSTION_MAX={effective_max}')
    print(f'[codex-collab] EXHAUSTION_CONSENSUS=true')
    print(f'[codex-collab] EXHAUSTION_NEXT_ACTION=present_consensus')

elif consensus:
    print()
    print(f'[codex-collab] ✓ Early consensus reached at round {current} of {effective_max}')
    print(f'[codex-collab] EXHAUSTION_DETECTED=false')
    print(f'[codex-collab] EXHAUSTION_ROUND={current}')
    print(f'[codex-collab] EXHAUSTION_MAX={effective_max}')
    print(f'[codex-collab] EXHAUSTION_CONSENSUS=true')
    print(f'[codex-collab] EXHAUSTION_NEXT_ACTION=present_consensus')

else:
    remaining = effective_max - current
    print(f'[codex-collab] Debate continuing — round {current} of {effective_max} ({remaining} remaining)')
    print(f'[codex-collab] EXHAUSTION_DETECTED=false')
    print(f'[codex-collab] EXHAUSTION_CONSENSUS=false')
    print(f'[codex-collab] EXHAUSTION_NEXT_ACTION=continue_round')
" "$state_json"
}

# ===========================================================================
# CLI MODE
# ===========================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ROUND=""
  CONSENSUS="false"
  TOPIC=""
  SESSION_ID="unknown"
  OUTPUT_MODE="json"  # json | notice | check

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --round)      ROUND="$2"; shift 2 ;;
      --consensus)  CONSENSUS="$2"; shift 2 ;;
      --topic)      TOPIC="$2"; shift 2 ;;
      --session)    SESSION_ID="$2"; shift 2 ;;
      --notice)     OUTPUT_MODE="notice"; shift ;;
      --check)      OUTPUT_MODE="check"; shift ;;
      --help|-h)
        echo "Usage: detect-exhaustion.sh --round <N> [OPTIONS]"
        echo ""
        echo "Detect max-round exhaustion in a debate/session."
        echo ""
        echo "Options:"
        echo "  --round <N>           Current round number (required)"
        echo "  --consensus <bool>    Whether consensus was reached (default: false)"
        echo "  --topic <topic>       Debate topic (optional, for context)"
        echo "  --session <id>        Session ID (optional, for logging)"
        echo "  --notice              Display formatted exhaustion notice"
        echo "  --check               Quick boolean check (exit 0=exhausted, 1=not)"
        echo "  --help, -h            Show this help"
        echo ""
        echo "Exit codes:"
        echo "  0 — rounds exhausted (or consensus reached)"
        echo "  1 — rounds remain, debate should continue"
        echo "  2 — error (invalid input)"
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
  done

  if [[ -z "$ROUND" ]]; then
    echo "[codex-collab] ERROR: --round is required" >&2
    exit 2
  fi

  # Ensure config is loaded for CLI mode
  if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
    if [[ -f "${SCRIPT_DIR}/load-config.sh" ]]; then
      source "${SCRIPT_DIR}/load-config.sh"
      load_config 2>/dev/null || true
    fi
  fi

  case "$OUTPUT_MODE" in
    check)
      if is_exhausted "$ROUND"; then
        echo "Exhausted: round ${ROUND} >= effective max $(get_effective_max_rounds 2>/dev/null || echo '5')"
        exit 0
      else
        echo "Not exhausted: round ${ROUND} < effective max $(get_effective_max_rounds 2>/dev/null || echo '5')"
        exit 1
      fi
      ;;
    notice)
      state=$(detect_round_exhaustion "$ROUND" "$CONSENSUS" "$TOPIC" "$SESSION_ID" "[]")
      format_exhaustion_notice "$state"
      ;;
    json)
      detect_round_exhaustion "$ROUND" "$CONSENSUS" "$TOPIC" "$SESSION_ID" "[]"
      ;;
  esac
fi
