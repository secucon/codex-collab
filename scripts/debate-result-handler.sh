#!/usr/bin/env bash
# debate-result-handler.sh — 4-choice handler for debate results (v2.1.0)
#
# After a debate completes (with or without consensus), the user is presented
# with 4 choices for handling the result. This script implements the handler
# logic for each choice:
#
#   1. APPLY_CLAUDE   — Apply Claude's proposal/position
#   2. APPLY_CODEX    — Apply Codex's proposal/position
#   3. CONTINUE       — Trigger an additional debate round
#   4. DISCARD        — Discard both proposals (no changes applied)
#
# Usage:
#   source scripts/debate-result-handler.sh
#
#   # Present 4-choice prompt and get user selection
#   present_result_choices "$debate_result_json" "$session_id"
#
#   # Handle a specific choice
#   handle_choice "apply_claude" "$debate_result_json" "$session_id" "$working_dir"
#   handle_choice "apply_codex"  "$debate_result_json" "$session_id" "$working_dir"
#   handle_choice "continue"     "$debate_result_json" "$session_id" "$working_dir"
#   handle_choice "discard"      "$debate_result_json" "$session_id" "$working_dir"
#
#   # Or run directly for testing:
#   ./scripts/debate-result-handler.sh --result-file <path> --choice <choice> \
#       [--session <id>] [--workdir <dir>]
#
# Dependencies:
#   - scripts/load-config.sh        (config_get)
#   - scripts/apply-changes.sh      (execute_approved_changes, rollback)
#   - scripts/debate-round-cap.sh   (is_within_cap, get_effective_max_rounds)
#   - python3                       (JSON parsing)
#
# Exit codes:
#   0 — handler completed successfully
#   1 — fatal error (missing deps, invalid input)
#   2 — user cancelled / operation aborted
#   3 — additional round not possible (cap reached)
#   4 — no applicable changes found for chosen side

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Source dependencies
# ---------------------------------------------------------------------------
if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
  if [[ -f "${SCRIPT_DIR}/load-config.sh" ]]; then
    source "${SCRIPT_DIR}/load-config.sh"
    load_config 2>/dev/null || true
  fi
fi

if [[ -f "${SCRIPT_DIR}/debate-round-cap.sh" ]]; then
  source "${SCRIPT_DIR}/debate-round-cap.sh"
fi

if [[ -f "${SCRIPT_DIR}/apply-changes.sh" ]]; then
  source "${SCRIPT_DIR}/apply-changes.sh"
fi

if [[ -f "${SCRIPT_DIR}/status-summary.sh" ]]; then
  source "${SCRIPT_DIR}/status-summary.sh"
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
HANDLER_LOG_DIR="${TMPDIR:-/tmp}/codex-collab-handler"

# Valid choices
readonly CHOICE_APPLY_CLAUDE="apply_claude"
readonly CHOICE_APPLY_CODEX="apply_codex"
readonly CHOICE_CONTINUE="continue"
readonly CHOICE_DISCARD="discard"

# ===========================================================================
# CHOICE PRESENTATION
# ===========================================================================

# ---------------------------------------------------------------------------
# present_result_choices — Show the 4-choice prompt to the user
# ---------------------------------------------------------------------------
# Displays a formatted prompt with the 4 options after a debate result.
# The orchestrator agent reads this output and collects the user's response.
#
# Args:
#   $1 — debate result JSON
#   $2 — session ID (optional)
#   $3 — current round number (optional, for "continue" eligibility display)
#
# Output:
#   Formatted choice prompt to stdout
#   HANDLER_CHOICES_AVAILABLE=<comma-separated list of valid choices>
# ---------------------------------------------------------------------------
present_result_choices() {
  local result_json="$1"
  local session_id="${2:-unknown}"
  local current_round="${3:-0}"

  # Extract key fields for context
  local topic consensus_reached confidence
  topic=$(_handler_json_val "$result_json" "topic" "Unknown topic")
  consensus_reached=$(_handler_json_val "$result_json" "consensus_reached" "false")
  confidence=$(_handler_json_val "$result_json" "confidence" "N/A")

  # Check if additional rounds are possible
  local can_continue="true"
  local effective_max
  effective_max=$(get_effective_max_rounds 2>/dev/null || echo "5")

  if [[ "$current_round" -ge "$effective_max" ]]; then
    can_continue="false"
  fi

  # Check if each side has proposals
  local has_claude_proposal has_codex_proposal
  has_claude_proposal=$(_has_side_proposal "$result_json" "claude")
  has_codex_proposal=$(_has_side_proposal "$result_json" "codex")

  # Build available choices list
  local available_choices=""
  if [[ "$has_claude_proposal" == "true" ]]; then
    available_choices="${available_choices}${CHOICE_APPLY_CLAUDE},"
  fi
  if [[ "$has_codex_proposal" == "true" ]]; then
    available_choices="${available_choices}${CHOICE_APPLY_CODEX},"
  fi
  if [[ "$can_continue" == "true" ]]; then
    available_choices="${available_choices}${CHOICE_CONTINUE},"
  fi
  available_choices="${available_choices}${CHOICE_DISCARD}"

  # Display the prompt
  # When max rounds are exhausted (can_continue == false), present exactly 3 choices
  # by excluding the "Continue debate" option entirely. Discard is renumbered to [3].
  echo ""
  echo "┌─────────────────────────────────────────────────────────────┐"

  if [[ "$can_continue" == "true" ]]; then
    echo "│  ⚡ Debate Result — Choose How to Proceed                   │"
  else
    echo "│  ⚡ Debate Result — Max Rounds Exhausted                    │"
  fi

  echo "├─────────────────────────────────────────────────────────────┤"
  echo "│                                                             │"

  # Choice 1: Apply Claude's proposal
  if [[ "$has_claude_proposal" == "true" ]]; then
    echo "│  [1] Apply Claude's proposal                               │"
    echo "│      Use Claude's recommended approach and code changes     │"
  else
    echo "│  [1] Apply Claude's proposal (no actionable changes)       │"
  fi
  echo "│                                                             │"

  # Choice 2: Apply Codex's proposal
  if [[ "$has_codex_proposal" == "true" ]]; then
    echo "│  [2] Apply Codex's proposal                                │"
    echo "│      Use Codex (GPT-5.4)'s recommended approach            │"
  else
    echo "│  [2] Apply Codex's proposal (no actionable changes)        │"
  fi
  echo "│                                                             │"

  if [[ "$can_continue" == "true" ]]; then
    # 4-choice mode: include "Continue debate" as [3], Discard as [4]
    local remaining=$(( effective_max - current_round ))
    echo "│  [3] Continue debate (+1 round)                            │"
    echo "│      Request an additional debate round (${remaining} more possible)    │"
    echo "│                                                             │"
    echo "│  [4] Discard both                                           │"
    echo "│      Reject both proposals, no changes applied              │"
  else
    # 3-choice mode: "Continue debate" excluded, Discard renumbered to [3]
    echo "│  [3] Discard both                                           │"
    echo "│      Reject both proposals, no changes applied              │"
  fi

  echo "│                                                             │"
  echo "└─────────────────────────────────────────────────────────────┘"
  echo ""
  echo "[codex-collab] HANDLER_CHOICES_AVAILABLE=${available_choices}"
  echo "[codex-collab] HANDLER_CHOICES_COUNT=$(echo "$available_choices" | tr ',' '\n' | wc -l | xargs)"
  echo "[codex-collab] HANDLER_CURRENT_ROUND=${current_round}"
  echo "[codex-collab] HANDLER_EFFECTIVE_MAX=${effective_max}"
  echo "[codex-collab] HANDLER_MAX_ROUNDS_EXHAUSTED=$( [[ "$can_continue" == "true" ]] && echo "false" || echo "true" )"
}

# ===========================================================================
# CHOICE PARSING
# ===========================================================================

# ---------------------------------------------------------------------------
# parse_user_choice — Normalize user input to a choice constant
# ---------------------------------------------------------------------------
# Args:
#   $1 — raw user input (number, keyword, or abbreviation)
#   $2 — max_rounds_exhausted: "true" or "false" (default: "false")
#         When "true", the menu is in 3-choice mode:
#           [1] Claude, [2] Codex, [3] Discard
#         When "false", the menu is in 4-choice mode:
#           [1] Claude, [2] Codex, [3] Continue, [4] Discard
#
# Returns:
#   One of: apply_claude, apply_codex, continue, discard, unknown
# ---------------------------------------------------------------------------
parse_user_choice() {
  local input="$1"
  local max_rounds_exhausted="${2:-false}"
  local normalized
  normalized=$(echo "$input" | tr '[:upper:]' '[:lower:]' | xargs)

  if [[ "$max_rounds_exhausted" == "true" ]]; then
    # --- 3-choice mode: [1] Claude, [2] Codex, [3] Discard ---
    # "Continue" option is completely excluded; number 3 maps to discard.
    case "$normalized" in
      1|claude|apply_claude|"apply claude"|"claude's"|"claude proposal")
        echo "$CHOICE_APPLY_CLAUDE"
        ;;
      2|codex|apply_codex|"apply codex"|"codex's"|"codex proposal"|gpt|"gpt-5.4")
        echo "$CHOICE_APPLY_CODEX"
        ;;
      3|discard|reject|cancel|none|skip|"discard both"|no)
        echo "$CHOICE_DISCARD"
        ;;
      continue|more|"additional round"|"another round"|"one more"|extend)
        # User typed a keyword for continue, but rounds are exhausted
        echo "$CHOICE_DISCARD"
        echo "[codex-collab] NOTE: Additional rounds unavailable (max rounds exhausted). Interpreting as discard." >&2
        ;;
      *)
        # Fuzzy matching (3-choice mode)
        if echo "$normalized" | grep -qiE '(claude|1st|first)'; then
          echo "$CHOICE_APPLY_CLAUDE"
        elif echo "$normalized" | grep -qiE '(codex|gpt|2nd|second)'; then
          echo "$CHOICE_APPLY_CODEX"
        elif echo "$normalized" | grep -qiE '(discard|reject|cancel|none|skip|neither)'; then
          echo "$CHOICE_DISCARD"
        else
          echo "unknown"
        fi
        ;;
    esac
  else
    # --- 4-choice mode: [1] Claude, [2] Codex, [3] Continue, [4] Discard ---
    case "$normalized" in
      1|claude|apply_claude|"apply claude"|"claude's"|"claude proposal")
        echo "$CHOICE_APPLY_CLAUDE"
        ;;
      2|codex|apply_codex|"apply codex"|"codex's"|"codex proposal"|gpt|"gpt-5.4")
        echo "$CHOICE_APPLY_CODEX"
        ;;
      3|continue|more|"additional round"|"another round"|"one more"|extend)
        echo "$CHOICE_CONTINUE"
        ;;
      4|discard|reject|cancel|none|skip|"discard both"|no)
        echo "$CHOICE_DISCARD"
        ;;
      *)
        # Fuzzy matching
        if echo "$normalized" | grep -qiE '(claude|1st|first)'; then
          echo "$CHOICE_APPLY_CLAUDE"
        elif echo "$normalized" | grep -qiE '(codex|gpt|2nd|second)'; then
          echo "$CHOICE_APPLY_CODEX"
        elif echo "$normalized" | grep -qiE '(continue|more|round|extend|additional)'; then
          echo "$CHOICE_CONTINUE"
        elif echo "$normalized" | grep -qiE '(discard|reject|cancel|none|skip|neither)'; then
          echo "$CHOICE_DISCARD"
        else
          echo "unknown"
        fi
        ;;
    esac
  fi
}

# ===========================================================================
# CHOICE HANDLERS
# ===========================================================================

# ---------------------------------------------------------------------------
# handle_choice — Main dispatcher: routes to the correct handler
# ---------------------------------------------------------------------------
# Args:
#   $1 — choice (apply_claude | apply_codex | continue | discard)
#   $2 — debate result JSON
#   $3 — session ID
#   $4 — working directory (default: pwd)
#   $5 — current round number (for continue choice)
#
# Returns: exit code from the specific handler
# ---------------------------------------------------------------------------
handle_choice() {
  local choice="$1"
  local result_json="$2"
  local session_id="${3:-unknown}"
  local working_dir="${4:-$(pwd)}"
  local current_round="${5:-0}"

  local handler_exit_code=0
  local choice_status="unknown"

  case "$choice" in
    "$CHOICE_APPLY_CLAUDE")
      _handle_apply_side "claude" "$result_json" "$session_id" "$working_dir"
      handler_exit_code=$?
      case $handler_exit_code in
        0) choice_status="applied" ;;
        4) choice_status="informational" ;;
        *) choice_status="error" ;;
      esac
      ;;
    "$CHOICE_APPLY_CODEX")
      _handle_apply_side "codex" "$result_json" "$session_id" "$working_dir"
      handler_exit_code=$?
      case $handler_exit_code in
        0) choice_status="applied" ;;
        4) choice_status="informational" ;;
        *) choice_status="error" ;;
      esac
      ;;
    "$CHOICE_CONTINUE")
      _handle_continue "$result_json" "$session_id" "$current_round"
      handler_exit_code=$?
      case $handler_exit_code in
        0) choice_status="authorized" ;;
        3) choice_status="blocked_cap" ;;
        *) choice_status="error" ;;
      esac
      ;;
    "$CHOICE_DISCARD")
      _handle_discard "$result_json" "$session_id"
      handler_exit_code=$?
      choice_status="discarded"
      ;;
    *)
      echo "[codex-collab] ERROR: Unknown choice '${choice}'" >&2
      echo "[codex-collab] Valid choices: apply_claude, apply_codex, continue, discard" >&2
      return 1
      ;;
  esac

  # --- Forced summary on max-round exhaustion ---
  # When the debate has exhausted its maximum rounds, ALWAYS generate a
  # summary report regardless of which choice the user selected. This ensures
  # an audit trail exists for every max-round exhaustion event.
  local effective_max
  effective_max=$(get_effective_max_rounds 2>/dev/null || echo "5")

  if declare -f is_max_round_exhausted &>/dev/null && \
     is_max_round_exhausted "$current_round" "$effective_max"; then
    echo ""
    generate_max_round_exhaustion_summary \
      "$result_json" "$choice" "$choice_status" \
      "$current_round" "$effective_max" "$session_id" "$working_dir"
  fi

  return $handler_exit_code
}

# ---------------------------------------------------------------------------
# _handle_apply_side — Apply a specific side's proposal (Claude or Codex)
# ---------------------------------------------------------------------------
# Extracts the chosen side's position and code changes from the debate result,
# then applies them to the codebase via apply-changes.sh.
#
# Args:
#   $1 — side ("claude" or "codex")
#   $2 — debate result JSON
#   $3 — session ID
#   $4 — working directory
#
# Returns: 0 on success, 1 on error, 4 if no changes found
# ---------------------------------------------------------------------------
_handle_apply_side() {
  local side="$1"
  local result_json="$2"
  local session_id="$3"
  local working_dir="$4"

  local side_display
  if [[ "$side" == "claude" ]]; then
    side_display="Claude"
  else
    side_display="Codex (GPT-5.4)"
  fi

  echo "[codex-collab] Preparing to apply ${side_display}'s proposal..."

  # Extract the chosen side's proposal into a temp file
  local handler_id="handler-$(date +%s)"
  local handler_dir="${HANDLER_LOG_DIR}/${handler_id}"
  mkdir -p "$handler_dir"

  local proposal_file="${handler_dir}/${side}-proposal.md"

  # Extract side-specific content from debate result
  python3 - "$result_json" "$side" "$proposal_file" <<'PYEOF'
import sys
import json
import os

result_json_str = sys.argv[1]
side = sys.argv[2]
output_path = sys.argv[3]

try:
    data = json.loads(result_json_str)
except json.JSONDecodeError:
    print("[codex-collab] ERROR: Invalid debate result JSON", file=sys.stderr)
    sys.exit(1)

content_parts = []

# --- Extract side-specific position and arguments ---

# From structured fields (e.g., codex_final_arguments, claude_final_arguments)
side_args_key = f"{side}_final_arguments"
side_args = data.get(side_args_key, data.get(f"{side}_arguments", []))

side_position_key = f"{side}_position"
side_position = data.get(side_position_key, "")

# From rounds data — find the last round where this side participated
rounds = data.get("rounds", data.get("round_summaries", []))
if isinstance(rounds, list):
    for r in reversed(rounds):
        if isinstance(r, dict):
            round_side = r.get("side", r.get("role", "")).lower()
            if round_side == side or not round_side:
                if not side_position:
                    side_position = r.get("position", "")
                if not side_args:
                    side_args = r.get("key_arguments", [])
                break

# Fallback: if no side-specific data, use the general final_position
if not side_position:
    side_position = data.get("final_position", data.get("consensus_position", ""))

# --- Extract side-specific code changes ---

# Check for side-specific changes (e.g., codex_changes, claude_changes)
side_changes_key = f"{side}_changes"
side_changes = data.get(side_changes_key, data.get(f"{side}_code_changes", None))

# Check for per-side diff
side_diff_key = f"{side}_diff"
side_diff = data.get(side_diff_key, None)

# Fallback: use the consensus diff/code_changes
general_diff = data.get("diff", "")
general_changes = data.get("code_changes", data.get("proposed_changes", []))

# --- Build the proposal content file ---

content_parts.append(f"# {side.capitalize()}'s Proposal\n")
content_parts.append(f"## Position\n\n{side_position}\n")

if side_args:
    content_parts.append("## Key Arguments\n")
    if isinstance(side_args, list):
        for arg in side_args:
            content_parts.append(f"- {arg}")
    elif isinstance(side_args, str):
        content_parts.append(side_args)
    content_parts.append("")

# Write code changes in a format that apply-changes.sh can parse
if side_diff:
    content_parts.append("## Code Changes\n")
    content_parts.append(side_diff)
elif side_changes:
    content_parts.append("## Code Changes\n")
    if isinstance(side_changes, list):
        for change in side_changes:
            if isinstance(change, dict):
                file_path = change.get("file", change.get("path", "unknown"))
                diff = change.get("diff", change.get("content", ""))
                desc = change.get("description", "")
                content_parts.append(f"### {file_path}")
                if desc:
                    content_parts.append(f"{desc}\n")
                if diff:
                    if diff.strip().startswith("---"):
                        content_parts.append(diff)
                    else:
                        content_parts.append(f"```typescript:{file_path}")
                        content_parts.append(diff)
                        content_parts.append("```")
                content_parts.append("")
    elif isinstance(side_changes, str):
        content_parts.append(side_changes)
elif general_diff:
    content_parts.append("## Code Changes (from consensus)\n")
    content_parts.append(general_diff)
elif general_changes:
    content_parts.append("## Code Changes (from consensus)\n")
    if isinstance(general_changes, list):
        for change in general_changes:
            if isinstance(change, dict):
                file_path = change.get("file", "unknown")
                diff = change.get("diff", change.get("content", ""))
                if diff:
                    if diff.strip().startswith("---"):
                        content_parts.append(diff)
                    else:
                        content_parts.append(f"```:{file_path}")
                        content_parts.append(diff)
                        content_parts.append("```")
    elif isinstance(general_changes, str):
        content_parts.append(general_changes)

with open(output_path, 'w', encoding='utf-8') as f:
    f.write("\n".join(content_parts))

# Report whether we found code changes
has_changes = bool(side_diff or side_changes or general_diff or general_changes)
print(json.dumps({"has_changes": has_changes, "side": side, "proposal_file": output_path}))
PYEOF

  local extract_result=$?
  if [[ $extract_result -ne 0 ]]; then
    echo "[codex-collab] ERROR: Failed to extract ${side_display}'s proposal" >&2
    return 1
  fi

  # Parse the extraction result
  local has_changes
  has_changes=$(python3 -c "
import sys, json
# Read last line of stdin as JSON
lines = sys.stdin.read().strip().split('\n')
last_line = lines[-1] if lines else '{}'
try:
    data = json.loads(last_line)
    print('true' if data.get('has_changes', False) else 'false')
except:
    print('false')
" <<< "$(cat /dev/stdin)" 2>/dev/null < <(echo "$(python3 -c "
import json
print(json.dumps({'has_changes': True}))
" 2>/dev/null)") || echo "false")

  # Check if proposal file has actionable content
  if [[ ! -f "$proposal_file" ]] || [[ ! -s "$proposal_file" ]]; then
    echo "[codex-collab] ${side_display}'s proposal contains no actionable code changes"
    echo "[codex-collab] Position has been recorded in session history"
    _create_handler_record "$session_id" "apply_${side}" "no_changes" "" \
      "$result_json"
    return 4
  fi

  echo "[codex-collab] ${side_display}'s proposal extracted to: ${proposal_file}"

  # Use apply-changes.sh to extract and preview changes
  echo "[codex-collab] Analyzing ${side_display}'s proposal for applicable code changes..."

  local change_count
  local change_dir="${handler_dir}/changes"
  change_count=$(extract_code_changes "$proposal_file" "$change_dir" 2>/dev/null || echo "0")

  if [[ "$change_count" == "0" || -z "$change_count" ]]; then
    echo "[codex-collab] ${side_display}'s proposal is informational only — no file modifications to apply"
    echo "[codex-collab] The position and reasoning have been recorded in session history"
    _create_handler_record "$session_id" "apply_${side}" "informational" "" \
      "$result_json"
    return 4
  fi

  echo "[codex-collab] Found ${change_count} code change(s) from ${side_display}"

  # Preview changes
  preview_changes "$change_dir"

  # v2.1.0: Selection equals approval for non-consensus code changes.
  # The user's choice of [1] or [2] IS the approval — no secondary confirmation needed.
  # This eliminates the redundant "Are you sure?" step after the user has already
  # made an explicit selection from the 4-choice prompt.
  echo ""
  echo "[codex-collab] ━━━ Applying Selected Proposal ━━━"
  echo "[codex-collab] ${side_display}'s ${change_count} code change(s) selected — applying now..."
  echo "[codex-collab] HANDLER_APPROVAL_REQUIRED=false"
  echo "[codex-collab] HANDLER_SIDE=${side}"
  echo "[codex-collab] HANDLER_CHANGE_DIR=${change_dir}"
  echo "[codex-collab] HANDLER_CHANGE_COUNT=${change_count}"
  echo "[codex-collab] HANDLER_WORKING_DIR=${working_dir}"

  # Directly apply since selection = approval (no secondary confirmation)
  if execute_side_apply "$change_dir" "$working_dir" "$side" "$session_id" "$result_json"; then
    echo "[codex-collab] HANDLER_RESULT=applied"
    return 0
  else
    echo "[codex-collab] HANDLER_RESULT=partial_failure"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# execute_side_apply — Apply side's changes after selection
# ---------------------------------------------------------------------------
# Called automatically by _handle_apply_side after the user selects a side.
# In v2.1.0, the user's selection from the 4-choice prompt IS the approval —
# no secondary confirmation is required. Can also be called directly by the
# orchestrator for programmatic apply scenarios.
#
# Args:
#   $1 — change directory (from _handle_apply_side output)
#   $2 — working directory
#   $3 — side ("claude" or "codex")
#   $4 — session ID
#   $5 — debate result JSON (for record creation)
#
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
execute_side_apply() {
  local change_dir="$1"
  local working_dir="$2"
  local side="${3:-unknown}"
  local session_id="${4:-unknown}"
  local result_json="${5:-'{}'}"

  local side_display
  if [[ "$side" == "claude" ]]; then
    side_display="Claude"
  else
    side_display="Codex (GPT-5.4)"
  fi

  echo "[codex-collab] Applying ${side_display}'s approved changes..."

  # Delegate to apply-changes.sh's execute_approved_changes
  if execute_approved_changes "$change_dir" "$working_dir"; then
    echo "[codex-collab] ✓ ${side_display}'s changes applied successfully"
    echo "[codex-collab] HANDLER_RESULT=applied"
    echo "[codex-collab] HANDLER_SIDE=${side}"

    _create_handler_record "$session_id" "apply_${side}" "applied" "" \
      "$result_json"
    return 0
  else
    echo "[codex-collab] ✗ Some of ${side_display}'s changes failed to apply"
    echo "[codex-collab] HANDLER_RESULT=partial_failure"
    echo "[codex-collab] HANDLER_SIDE=${side}"

    _create_handler_record "$session_id" "apply_${side}" "partial_failure" "" \
      "$result_json"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# _handle_continue — Trigger an additional debate round
# ---------------------------------------------------------------------------
# Validates that the round cap hasn't been reached, then signals the
# orchestrator to run one more debate round.
#
# Args:
#   $1 — debate result JSON (current state)
#   $2 — session ID
#   $3 — current round number
#
# Returns:
#   0 — additional round authorized (orchestrator should execute it)
#   3 — round cap reached, cannot continue
# ---------------------------------------------------------------------------
_handle_continue() {
  local result_json="$1"
  local session_id="${2:-unknown}"
  local current_round="${3:-0}"

  echo "[codex-collab] Checking if additional debate round is possible..."

  # Get effective max from config (uses debate-round-cap.sh)
  local effective_max
  effective_max=$(get_effective_max_rounds 2>/dev/null || echo "5")

  local next_round=$(( current_round + 1 ))

  # Check round cap
  if ! is_within_cap "$next_round" 2>/dev/null; then
    echo "[codex-collab] ✗ Cannot continue — round cap reached"
    echo "[codex-collab] Current round: ${current_round}, effective max: ${effective_max}"
    echo "[codex-collab] The maximum additional rounds (hard cap: 2) have been exhausted"
    echo ""
    echo "[codex-collab] Please choose from the 3 remaining options:"
    echo "  [1] Apply Claude's proposal"
    echo "  [2] Apply Codex's proposal"
    echo "  [3] Discard both"
    echo ""
    echo "[codex-collab] HANDLER_CONTINUE_BLOCKED=true"
    echo "[codex-collab] HANDLER_REASON=round_cap_reached"
    echo "[codex-collab] HANDLER_EFFECTIVE_MAX=${effective_max}"
    echo "[codex-collab] HANDLER_CURRENT_ROUND=${current_round}"

    _create_handler_record "$session_id" "continue" "blocked_cap" \
      "Round cap reached: ${current_round}/${effective_max}" "$result_json"
    return 3
  fi

  # Additional round is authorized
  local default_rounds
  default_rounds=$(get_default_rounds 2>/dev/null || echo "3")
  local additional_used=$(( current_round - default_rounds ))
  if [[ "$additional_used" -lt 0 ]]; then
    additional_used=0
  fi
  local max_additional
  max_additional=$(get_max_additional_rounds 2>/dev/null || echo "2")
  local additional_remaining=$(( max_additional - additional_used ))
  if [[ "$additional_remaining" -lt 0 ]]; then
    additional_remaining=0
  fi

  echo "[codex-collab] ✓ Additional debate round authorized"
  echo "[codex-collab] Next round: ${next_round} of ${effective_max}"
  echo "[codex-collab] Additional rounds used: ${additional_used} of ${max_additional} (${additional_remaining} remaining)"
  echo ""

  # Extract the topic and last positions for the orchestrator to use
  local topic
  topic=$(_handler_json_val "$result_json" "topic" "")

  echo "[codex-collab] HANDLER_CONTINUE_AUTHORIZED=true"
  echo "[codex-collab] HANDLER_NEXT_ROUND=${next_round}"
  echo "[codex-collab] HANDLER_EFFECTIVE_MAX=${effective_max}"
  echo "[codex-collab] HANDLER_ADDITIONAL_REMAINING=${additional_remaining}"
  echo "[codex-collab] HANDLER_TOPIC=${topic}"
  echo "[codex-collab] HANDLER_SESSION_ID=${session_id}"

  _create_handler_record "$session_id" "continue" "authorized" \
    "Round ${next_round} of ${effective_max}" "$result_json"
  return 0
}

# ---------------------------------------------------------------------------
# _handle_discard — Discard both proposals
# ---------------------------------------------------------------------------
# No changes are applied. Both positions are recorded in session history
# for future reference.
#
# Args:
#   $1 — debate result JSON
#   $2 — session ID
#
# Returns: 0 always (discarding is never an error)
# ---------------------------------------------------------------------------
_handle_discard() {
  local result_json="$1"
  local session_id="${2:-unknown}"

  local topic
  topic=$(_handler_json_val "$result_json" "topic" "Unknown topic")

  echo "[codex-collab] Discarding both proposals"
  echo "[codex-collab] No changes will be applied to the codebase"
  echo ""
  echo "[codex-collab] Both positions have been recorded in session history for reference:"
  echo "[codex-collab]   Topic: ${topic}"
  echo "[codex-collab]   Session: ${session_id}"
  echo ""
  echo "[codex-collab] You can review the debate later with: /codex-session list"
  echo "[codex-collab] HANDLER_RESULT=discarded"

  _create_handler_record "$session_id" "discard" "discarded" "" "$result_json"
  return 0
}

# ===========================================================================
# HELPER FUNCTIONS
# ===========================================================================

# ---------------------------------------------------------------------------
# _handler_json_val — Extract a value from JSON (reusable helper)
# ---------------------------------------------------------------------------
_handler_json_val() {
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

# ---------------------------------------------------------------------------
# _has_side_proposal — Check if a specific side has actionable proposals
# ---------------------------------------------------------------------------
_has_side_proposal() {
  local result_json="$1"
  local side="$2"

  python3 -c "
import json, sys

try:
    data = json.loads(sys.argv[1])
    side = sys.argv[2]

    # Check for side-specific changes
    side_changes = data.get(f'{side}_changes', data.get(f'{side}_code_changes', None))
    side_diff = data.get(f'{side}_diff', None)
    side_position = data.get(f'{side}_position', '')

    # Check for side-specific data in rounds
    rounds = data.get('rounds', data.get('round_summaries', []))
    has_round_data = False
    if isinstance(rounds, list):
        for r in rounds:
            if isinstance(r, dict):
                round_side = r.get('side', r.get('role', '')).lower()
                if round_side == side or not round_side:
                    if r.get('position') or r.get('key_arguments'):
                        has_round_data = True
                        break

    # Check for general changes (either side can use them)
    general_diff = data.get('diff', '')
    general_changes = data.get('code_changes', data.get('proposed_changes', []))

    has_proposal = bool(
        side_changes or
        side_diff or
        side_position or
        has_round_data or
        general_diff or
        general_changes or
        data.get('final_position', '')
    )

    print('true' if has_proposal else 'false')
except Exception:
    print('false')
" "$result_json" "$side" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _create_handler_record — Create a session history record for the choice
# ---------------------------------------------------------------------------
_create_handler_record() {
  local session_id="$1"
  local choice="$2"
  local status="$3"
  local details="${4:-}"
  local result_json="${5:-'{}'}"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local topic
  topic=$(_handler_json_val "$result_json" "topic" "")

  python3 -c "
import json, sys

record = {
    'type': 'debate_result_handler',
    'session_id': sys.argv[1],
    'timestamp': sys.argv[5],
    'choice': sys.argv[2],
    'status': sys.argv[3],
    'topic': sys.argv[6],
}

details = sys.argv[4]
if details:
    record['details'] = details

# Map choice to applied flag for compatibility with approval-result schema
record['applied'] = sys.argv[2] in ('apply_claude', 'apply_codex') and sys.argv[3] in ('applied', 'informational')
record['decision'] = {
    'apply_claude': 'accepted',
    'apply_codex': 'accepted',
    'continue': 'continue',
    'discard': 'rejected',
}.get(sys.argv[2], 'unknown')

print(json.dumps(record, ensure_ascii=False))
" "$session_id" "$choice" "$status" "$details" "$timestamp" "$topic" 2>/dev/null
}

# ---------------------------------------------------------------------------
# get_choice_status_line — Get a one-line status for the status summary
# ---------------------------------------------------------------------------
# Args:
#   $1 — choice that was made
#   $2 — status of that choice (applied, discarded, etc.)
#   $3 — side (claude/codex) — optional
#
# Returns: formatted status line string
# ---------------------------------------------------------------------------
get_choice_status_line() {
  local choice="$1"
  local status="${2:-}"
  local side="${3:-}"

  case "$choice" in
    "$CHOICE_APPLY_CLAUDE")
      if [[ "$status" == "applied" ]]; then
        echo "✅ Applied Claude's proposal — changes written to codebase"
      elif [[ "$status" == "partial_failure" ]]; then
        echo "⚠️  Partially applied Claude's proposal — some changes failed"
      else
        echo "📝 Claude's proposal selected (informational — no code changes)"
      fi
      ;;
    "$CHOICE_APPLY_CODEX")
      if [[ "$status" == "applied" ]]; then
        echo "✅ Applied Codex (GPT-5.4)'s proposal — changes written to codebase"
      elif [[ "$status" == "partial_failure" ]]; then
        echo "⚠️  Partially applied Codex's proposal — some changes failed"
      else
        echo "📝 Codex's proposal selected (informational — no code changes)"
      fi
      ;;
    "$CHOICE_CONTINUE")
      echo "🔄 Additional debate round requested"
      ;;
    "$CHOICE_DISCARD")
      echo "❌ Both proposals discarded — no changes applied"
      ;;
    *)
      echo "⏳ Debate result: pending user decision"
      ;;
  esac
}

# ===========================================================================
# CLI MODE
# ===========================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  RESULT_FILE=""
  CHOICE=""
  SESSION_ID="test-session"
  WORKING_DIR="$(pwd)"
  CURRENT_ROUND="0"
  MODE="prompt"  # prompt | handle

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result-file) RESULT_FILE="$2"; shift 2 ;;
      --choice)      CHOICE="$2"; MODE="handle"; shift 2 ;;
      --session)     SESSION_ID="$2"; shift 2 ;;
      --workdir)     WORKING_DIR="$2"; shift 2 ;;
      --round)       CURRENT_ROUND="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: debate-result-handler.sh --result-file <path> [OPTIONS]"
        echo ""
        echo "Handle debate results with 4-choice flow."
        echo ""
        echo "Options:"
        echo "  --result-file <path>  Path to debate result JSON file (required)"
        echo "  --choice <choice>     Handle a specific choice:"
        echo "                          apply_claude  — Apply Claude's proposal"
        echo "                          apply_codex   — Apply Codex's proposal"
        echo "                          continue      — Request additional round"
        echo "                          discard       — Discard both proposals"
        echo "  --session <id>        Session ID (default: test-session)"
        echo "  --workdir <dir>       Working directory (default: cwd)"
        echo "  --round <N>           Current round number (for continue check)"
        echo "  --help, -h            Show this help"
        echo ""
        echo "If --choice is omitted, displays the 4-choice prompt only."
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$RESULT_FILE" ]]; then
    echo "[codex-collab] ERROR: --result-file is required" >&2
    exit 1
  fi

  if [[ ! -f "$RESULT_FILE" ]]; then
    echo "[codex-collab] ERROR: Result file not found: ${RESULT_FILE}" >&2
    exit 1
  fi

  RESULT_JSON=$(cat "$RESULT_FILE")

  if [[ "$MODE" == "prompt" ]]; then
    # Just show the 4-choice prompt
    present_result_choices "$RESULT_JSON" "$SESSION_ID" "$CURRENT_ROUND"
  else
    # Handle the specified choice
    handle_choice "$CHOICE" "$RESULT_JSON" "$SESSION_ID" "$WORKING_DIR" "$CURRENT_ROUND"
  fi
fi
