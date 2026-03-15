#!/usr/bin/env bash
# compose-report.sh — Final report composition for codex-collab debates (v2.1.0)
#
# Combines all debate elements into a complete, structured report:
#   1. Topic                — debate topic string
#   2. Trigger cause        — manual, safety_hook, or rule_engine
#   3. Models               — participating models (Claude + Codex GPT-5.4)
#   4. Round summaries      — per-round positions, confidence, consensus checks
#   5. Final result         — consensus/non-consensus outcome with position
#   6. Chosen action        — user's 4-choice decision and apply status
#
# Usage:
#   # Source for shell functions:
#   source scripts/compose-report.sh
#   report=$(compose_final_report "$debate_result_json" "$chosen_action" "$trigger_cause")
#   echo "$report"
#
#   # Or run directly:
#   ./scripts/compose-report.sh --result '<json>' [--action <action>] [--trigger <cause>]
#                               [--format text|markdown|json] [--session <id>]
#
# Integration:
#   Called by workflow-orchestrator after debate completion + user choice.
#   The composed report is:
#     1. Displayed to the user (console output)
#     2. Auto-saved to .codex-collab/reports/ (via status-summary.sh save_report)
#     3. Recorded in session history
#
# Dependencies:
#   - scripts/status-summary.sh   (save_report, _auto_save_report)
#   - scripts/load-config.sh      (config_get)
#   - python3                     (JSON parsing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config loader if not already loaded
if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
  if [[ -f "${SCRIPT_DIR}/load-config.sh" ]]; then
    # shellcheck source=load-config.sh
    source "${SCRIPT_DIR}/load-config.sh"
    load_config 2>/dev/null || true
  fi
fi

# Source status-summary for save_report
if [[ -f "${SCRIPT_DIR}/status-summary.sh" ]]; then
  # shellcheck source=status-summary.sh
  source "${SCRIPT_DIR}/status-summary.sh"
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
readonly TRIGGER_MANUAL="manual"
readonly TRIGGER_SAFETY_HOOK="safety_hook"
readonly TRIGGER_RULE_ENGINE="rule_engine"

readonly ACTION_APPLY_CLAUDE="apply_claude"
readonly ACTION_APPLY_CODEX="apply_codex"
readonly ACTION_CONTINUE="continue"
readonly ACTION_DISCARD="discard"
readonly ACTION_CONSENSUS_ACCEPT="consensus_accept"
readonly ACTION_CONSENSUS_REJECT="consensus_reject"
readonly ACTION_PENDING="pending"

# ---------------------------------------------------------------------------
# JSON value extraction (reuse pattern)
# ---------------------------------------------------------------------------
_report_json_val() {
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
# REPORT SECTION BUILDERS
# ===========================================================================

# ---------------------------------------------------------------------------
# Section 1: Topic header
# ---------------------------------------------------------------------------
_build_topic_section() {
  local topic="$1"
  local timestamp="$2"

  echo "## Debate Report (토론 리포트)"
  echo ""
  echo "### Topic (주제)"
  echo ""
  echo "> ${topic}"
  echo ""
  echo "**Timestamp:** ${timestamp}"
  echo ""
}

# ---------------------------------------------------------------------------
# Section 2: Trigger cause
# ---------------------------------------------------------------------------
_build_trigger_section() {
  local trigger_cause="$1"
  local hook_severity="${2:-}"
  local hook_type="${3:-}"

  echo "### Trigger (트리거)"
  echo ""

  case "$trigger_cause" in
    "$TRIGGER_MANUAL")
      echo "- **Source:** Manual (사용자 직접 실행)"
      echo "- **Command:** \`/codex-debate\`"
      ;;
    "$TRIGGER_SAFETY_HOOK")
      echo "- **Source:** Safety Hook Auto-Trigger (안전 훅 자동 트리거)"
      if [[ -n "$hook_severity" ]]; then
        echo "- **Severity:** ${hook_severity}"
      fi
      if [[ -n "$hook_type" ]]; then
        echo "- **Hook Type:** ${hook_type}"
      fi
      echo "- **Note:** User approval was required before debate started"
      ;;
    "$TRIGGER_RULE_ENGINE")
      echo "- **Source:** Rule Engine (규칙 엔진 자동 트리거)"
      echo "- **Note:** Triggered by rule cascade evaluation"
      ;;
    *)
      echo "- **Source:** ${trigger_cause}"
      ;;
  esac

  echo ""
}

# ---------------------------------------------------------------------------
# Section 3: Models (participants)
# ---------------------------------------------------------------------------
_build_models_section() {
  local result_json="$1"

  echo "### Participants (참여 모델)"
  echo ""
  echo "| Model | Role |"
  echo "|-------|------|"
  echo "| Claude (Anthropic) | Counter-position, independent analysis |"
  echo "| Codex GPT-5.4 (OpenAI) | Initial position, structured debate |"

  # Check if session has additional context
  local session_id
  session_id="$(_report_json_val "$result_json" "session_id" "")"
  if [[ -n "$session_id" ]]; then
    echo ""
    echo "**Session:** \`${session_id}\`"
  fi

  echo ""
}

# ---------------------------------------------------------------------------
# Section 4: Round summaries
# ---------------------------------------------------------------------------
_build_rounds_section() {
  local result_json="$1"

  echo "### Round Summaries (라운드 요약)"
  echo ""

  python3 -c "
import json, sys

try:
    data = json.loads(sys.argv[1])

    # Resolve round data: 'rounds' may be int or list; 'round_summaries' is always list
    raw_rounds = data.get('rounds', None)
    round_summaries = data.get('round_summaries', [])

    if isinstance(raw_rounds, list) and len(raw_rounds) > 0:
        rounds = raw_rounds
        total_rounds = len(rounds)
    elif isinstance(round_summaries, list) and len(round_summaries) > 0:
        rounds = round_summaries
        total_rounds = int(raw_rounds) if isinstance(raw_rounds, (int, float)) else len(rounds)
    elif isinstance(raw_rounds, (int, float)):
        rounds = []
        total_rounds = int(raw_rounds)
    else:
        rounds = []
        total_rounds = 0

    print(f'**Total Rounds:** {total_rounds}')
    print()

    if not rounds or not isinstance(rounds, list) or len(rounds) == 0:
        # Try to show final positions even without per-round data
        codex_pos = data.get('codex_position', data.get('final_position', ''))
        claude_pos = data.get('claude_position', '')
        if codex_pos or claude_pos:
            print('| Round | Codex Position | Claude Position | Consensus |')
            print('|:-----:|:---------------|:----------------|:---------:|')
            consensus = data.get('consensus_reached', False)
            codex_short = (codex_pos[:60] + '...') if len(str(codex_pos)) > 60 else str(codex_pos)
            claude_short = (claude_pos[:60] + '...') if len(str(claude_pos)) > 60 else str(claude_pos)
            consensus_mark = 'Yes' if consensus else 'No'
            print(f'| Final | {codex_short} | {claude_short} | {consensus_mark} |')
        else:
            print('_(Detailed per-round data not available)_')
        sys.exit(0)

    # Build the round summary table
    print('| Round | Codex Position | Claude Position | Consensus |')
    print('|:-----:|:---------------|:----------------|:---------:|')

    for i, r in enumerate(rounds):
        if isinstance(r, dict):
            round_num = r.get('round', i + 1)
            side = r.get('side', r.get('role', '')).lower()
            position = r.get('position', r.get('summary', ''))
            confidence = r.get('confidence', '')
            agreed = r.get('agrees_with_opponent', False)

            # Truncate position for table display
            pos_short = (position[:50] + '...') if len(position) > 50 else position
            conf_str = f' ({confidence})' if confidence else ''
            consensus_mark = 'Yes' if agreed else 'No'

            # Determine which column this goes in
            codex_col = ''
            claude_col = ''
            if side == 'codex':
                codex_col = f'{pos_short}{conf_str}'
            elif side == 'claude':
                claude_col = f'{pos_short}{conf_str}'
            else:
                # No side specified — might be a paired round
                codex_pos = r.get('codex_position', r.get('codex', {}).get('position', '') if isinstance(r.get('codex'), dict) else '')
                claude_pos = r.get('claude_position', r.get('claude', {}).get('position', '') if isinstance(r.get('claude'), dict) else '')
                codex_conf = r.get('codex_confidence', r.get('codex', {}).get('confidence', '') if isinstance(r.get('codex'), dict) else '')
                claude_conf = r.get('claude_confidence', r.get('claude', {}).get('confidence', '') if isinstance(r.get('claude'), dict) else '')

                if codex_pos:
                    codex_col = (codex_pos[:50] + '...') if len(codex_pos) > 50 else codex_pos
                    if codex_conf:
                        codex_col += f' ({codex_conf})'
                elif not codex_pos:
                    codex_col = pos_short + conf_str

                if claude_pos:
                    claude_col = (claude_pos[:50] + '...') if len(claude_pos) > 50 else claude_pos
                    if claude_conf:
                        claude_col += f' ({claude_conf})'

            print(f'| {round_num} | {codex_col} | {claude_col} | {consensus_mark} |')
        elif isinstance(r, str):
            print(f'| {i+1} | {r[:50]} | — | — |')

    # Show effective max rounds info
    effective_max = data.get('effective_max_rounds', data.get('max_rounds', ''))
    default_rounds = data.get('default_rounds', '')
    max_additional = data.get('max_additional_rounds', '')
    if effective_max:
        print()
        meta_parts = [f'max_rounds: {effective_max}']
        if default_rounds:
            meta_parts.append(f'default: {default_rounds}')
        if max_additional:
            meta_parts.append(f'additional: {max_additional}')
        print(f'_Round config: {\" | \".join(meta_parts)}_')

except Exception as e:
    print(f'_(Error building round table: {e})_')
" "$result_json" 2>/dev/null

  echo ""
}

# ---------------------------------------------------------------------------
# Section 5: Final result
# ---------------------------------------------------------------------------
_build_result_section() {
  local result_json="$1"

  echo "### Final Result (최종 결과)"
  echo ""

  python3 -c "
import json, sys

try:
    data = json.loads(sys.argv[1])

    consensus = data.get('consensus_reached', False)
    confidence = data.get('confidence', data.get('final_confidence', 'N/A'))

    if consensus:
        print('**Status:** Consensus Reached (합의 도달)')
        print(f'**Confidence:** {confidence}')
    else:
        print('**Status:** No Consensus (합의 미도달)')
        divergence = data.get('divergence_score', '')
        trend = data.get('convergence_trend', '')
        if divergence:
            print(f'**Divergence Score:** {divergence}')
        if trend:
            print(f'**Convergence Trend:** {trend}')

    print()

    # Final position
    final_pos = data.get('final_position', data.get('consensus_position', ''))
    if final_pos:
        if consensus:
            print('**Agreed Position:**')
        else:
            print('**Final Positions:**')
        print(f'> {final_pos}')
        print()

    # Key arguments from both sides
    codex_args = data.get('codex_final_arguments', data.get('codex_arguments', []))
    claude_args = data.get('claude_final_arguments', data.get('claude_arguments', []))

    if codex_args:
        print('**Codex (GPT-5.4) Key Arguments:**')
        args = codex_args if isinstance(codex_args, list) else [codex_args]
        for arg in args:
            print(f'  - {arg}')
        print()

    if claude_args:
        print('**Claude Key Arguments:**')
        args = claude_args if isinstance(claude_args, list) else [claude_args]
        for arg in args:
            print(f'  - {arg}')
        print()

    # Code changes summary
    has_diff = bool(data.get('diff'))
    has_code_changes = bool(data.get('code_changes'))
    if has_diff or has_code_changes:
        print('**Code Changes:** Yes (proposed changes included in debate result)')
    else:
        print('**Code Changes:** None (architectural/design discussion only)')
    print()

    # Recommendation
    rec = data.get('recommendation', data.get('user_guidance', ''))
    if rec:
        print('**Recommendation:**')
        if isinstance(rec, list):
            for r in rec:
                print(f'  - {r}')
        else:
            print(f'  {rec}')
        print()

except Exception as e:
    print(f'_(Error extracting result: {e})_')
" "$result_json" 2>/dev/null

  echo ""
}

# ---------------------------------------------------------------------------
# Section 6: Chosen action
# ---------------------------------------------------------------------------
_build_action_section() {
  local chosen_action="$1"
  local action_status="${2:-}"
  local action_details="${3:-}"

  echo "### Chosen Action (선택된 조치)"
  echo ""

  case "$chosen_action" in
    "$ACTION_APPLY_CLAUDE")
      echo "- **Decision:** Applied Claude's Proposal"
      echo "- **Side:** Claude (Anthropic)"
      ;;
    "$ACTION_APPLY_CODEX")
      echo "- **Decision:** Applied Codex's Proposal"
      echo "- **Side:** Codex GPT-5.4 (OpenAI)"
      ;;
    "$ACTION_CONTINUE")
      echo "- **Decision:** Additional Debate Round Requested"
      echo "- **Note:** Debate will continue with one more round"
      ;;
    "$ACTION_DISCARD")
      echo "- **Decision:** Both Proposals Discarded"
      echo "- **Note:** No changes applied to codebase"
      ;;
    "$ACTION_CONSENSUS_ACCEPT")
      echo "- **Decision:** Consensus Result Accepted"
      echo "- **Note:** Agreed changes applied to codebase"
      ;;
    "$ACTION_CONSENSUS_REJECT")
      echo "- **Decision:** Consensus Result Rejected"
      echo "- **Note:** Consensus changes discarded"
      ;;
    "$ACTION_PENDING")
      echo "- **Decision:** Pending (awaiting user decision)"
      ;;
    *)
      echo "- **Decision:** ${chosen_action}"
      ;;
  esac

  if [[ -n "$action_status" ]]; then
    local status_icon
    case "$action_status" in
      applied|success)       status_icon="applied" ;;
      partial_failure)       status_icon="partially applied (some changes failed)" ;;
      informational)         status_icon="recorded (no code changes)" ;;
      blocked_cap)           status_icon="blocked (round cap reached)" ;;
      authorized)            status_icon="authorized (additional round)" ;;
      discarded)             status_icon="discarded" ;;
      *)                     status_icon="$action_status" ;;
    esac
    echo "- **Apply Status:** ${status_icon}"
  fi

  if [[ -n "$action_details" ]]; then
    echo "- **Details:** ${action_details}"
  fi

  echo ""
}

# ===========================================================================
# PUBLIC API
# ===========================================================================

# ---------------------------------------------------------------------------
# Public: compose_final_report
# Main entry point — builds the complete debate report
#
# Args:
#   result_json    — Full debate result JSON (required)
#   chosen_action  — User's action choice (apply_claude|apply_codex|continue|discard|
#                    consensus_accept|consensus_reject|pending)
#   trigger_cause  — What triggered the debate (manual|safety_hook|rule_engine)
#   action_status  — Status of the chosen action (applied|partial_failure|etc.)
#   action_details — Optional extra detail about the action
#
# Returns: Complete report as markdown text to stdout
# ---------------------------------------------------------------------------
compose_final_report() {
  local result_json="${1:-'{}'}"
  local chosen_action="${2:-$ACTION_PENDING}"
  local trigger_cause="${3:-$TRIGGER_MANUAL}"
  local action_status="${4:-}"
  local action_details="${5:-}"

  if ! command -v python3 &>/dev/null; then
    echo "[codex-collab] Cannot compose report (python3 required)" >&2
    return 1
  fi

  # Extract core fields from result JSON
  local topic rounds consensus_reached timestamp
  topic="$(_report_json_val "$result_json" "topic" "Unknown topic")"
  rounds="$(_report_json_val "$result_json" "rounds" "N/A")"
  consensus_reached="$(_report_json_val "$result_json" "consensus_reached" "false")"
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)"

  # Extract trigger-specific fields
  local hook_severity hook_type
  hook_severity="$(_report_json_val "$result_json" "hook_severity" "")"
  hook_type="$(_report_json_val "$result_json" "hook_type" "")"

  # Compose the report by calling each section builder directly to stdout
  # (Using subshell capture strips trailing newlines, so we output directly)
  {
    _build_topic_section "$topic" "$timestamp"
    _build_trigger_section "$trigger_cause" "$hook_severity" "$hook_type"
    _build_models_section "$result_json"
    _build_rounds_section "$result_json"
    _build_result_section "$result_json"
    _build_action_section "$chosen_action" "$action_status" "$action_details"
    echo "---"
    echo "_Report generated by codex-collab v2.1.0 at ${timestamp}_"
  }
}

# ---------------------------------------------------------------------------
# Public: compose_and_save_report
# Composes the final report AND auto-saves it to .codex-collab/reports/
#
# Args: same as compose_final_report + optional project_root
#   $6 — project_root (default: CODEX_PROJECT_ROOT or cwd)
#
# Returns: report text to stdout, saved file path to stderr
# ---------------------------------------------------------------------------
compose_and_save_report() {
  local result_json="${1:-'{}'}"
  local chosen_action="${2:-$ACTION_PENDING}"
  local trigger_cause="${3:-$TRIGGER_MANUAL}"
  local action_status="${4:-}"
  local action_details="${5:-}"
  local project_root="${6:-${CODEX_PROJECT_ROOT:-$(pwd)}}"

  # Compose the report
  local report
  report="$(compose_final_report "$result_json" "$chosen_action" "$trigger_cause" \
            "$action_status" "$action_details")"

  # Output to stdout
  echo "$report"

  # Auto-save if save_report function is available
  if declare -f save_report &>/dev/null; then
    local saved_path
    saved_path="$(save_report "codex-debate" "$report" "$project_root" "$result_json" 2>/dev/null)" || true
    if [[ -n "$saved_path" ]]; then
      echo "[codex-collab] Report saved: ${saved_path}" >&2
    fi
  fi
}

# ---------------------------------------------------------------------------
# Public: compose_report_json
# Composes the final report as a structured JSON object (for programmatic use)
#
# Args: same as compose_final_report
#
# Returns: JSON object to stdout
# ---------------------------------------------------------------------------
compose_report_json() {
  local result_json="${1:-'{}'}"
  local chosen_action="${2:-$ACTION_PENDING}"
  local trigger_cause="${3:-$TRIGGER_MANUAL}"
  local action_status="${4:-}"
  local action_details="${5:-}"

  python3 -c "
import json, sys
from datetime import datetime, timezone

try:
    result = json.loads(sys.argv[1])
    chosen_action = sys.argv[2]
    trigger_cause = sys.argv[3]
    action_status = sys.argv[4] if len(sys.argv) > 4 else ''
    action_details = sys.argv[5] if len(sys.argv) > 5 else ''

    report = {
        'version': '2.1.0',
        'type': 'debate_report',
        'timestamp': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'topic': result.get('topic', 'Unknown topic'),
        'trigger': {
            'cause': trigger_cause,
        },
        'models': [
            {'name': 'Claude', 'provider': 'Anthropic', 'role': 'counter-position'},
            {'name': 'Codex GPT-5.4', 'provider': 'OpenAI', 'role': 'initial-position'},
        ],
        'rounds': {
            'total': result.get('rounds', 0) if isinstance(result.get('rounds'), (int, float)) else len(result.get('rounds', result.get('round_summaries', []))),
            'summaries': result.get('round_summaries', result.get('rounds', [])) if isinstance(result.get('rounds', result.get('round_summaries', [])), list) else [],
            'effective_max': result.get('effective_max_rounds', result.get('max_rounds', None)),
            'default_rounds': result.get('default_rounds', None),
            'max_additional': result.get('max_additional_rounds', None),
        },
        'result': {
            'consensus_reached': result.get('consensus_reached', False),
            'confidence': result.get('confidence', result.get('final_confidence', None)),
            'final_position': result.get('final_position', result.get('consensus_position', '')),
            'divergence_score': result.get('divergence_score', None),
            'convergence_trend': result.get('convergence_trend', None),
            'has_code_changes': bool(result.get('diff') or result.get('code_changes')),
            'codex_arguments': result.get('codex_final_arguments', result.get('codex_arguments', [])),
            'claude_arguments': result.get('claude_final_arguments', result.get('claude_arguments', [])),
        },
        'action': {
            'chosen': chosen_action,
        },
    }

    # Add trigger-specific fields
    if trigger_cause == 'safety_hook':
        report['trigger']['hook_severity'] = result.get('hook_severity', '')
        report['trigger']['hook_type'] = result.get('hook_type', '')

    # Add action details
    if action_status:
        report['action']['status'] = action_status
    if action_details:
        report['action']['details'] = action_details

    # Clean None values recursively
    def clean_none(obj):
        if isinstance(obj, dict):
            return {k: clean_none(v) for k, v in obj.items() if v is not None}
        elif isinstance(obj, list):
            return [clean_none(v) for v in obj]
        return obj

    report = clean_none(report)
    print(json.dumps(report, ensure_ascii=False, indent=2))

except Exception as e:
    print(json.dumps({'error': str(e)}))
" "$result_json" "$chosen_action" "$trigger_cause" "$action_status" "$action_details" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Public: compose_compact_report
# One-line summary for status displays
#
# Args:
#   result_json    — Full debate result JSON
#   chosen_action  — User's action choice
#   trigger_cause  — What triggered the debate
#
# Returns: single line summary string
# ---------------------------------------------------------------------------
compose_compact_report() {
  local result_json="${1:-'{}'}"
  local chosen_action="${2:-$ACTION_PENDING}"
  local trigger_cause="${3:-$TRIGGER_MANUAL}"

  local topic consensus_reached rounds
  topic="$(_report_json_val "$result_json" "topic" "Unknown")"
  consensus_reached="$(_report_json_val "$result_json" "consensus_reached" "false")"
  rounds="$(_report_json_val "$result_json" "rounds" "?")"

  # Truncate topic
  if [[ ${#topic} -gt 40 ]]; then
    topic="${topic:0:40}..."
  fi

  local consensus_label
  if [[ "$consensus_reached" == "true" ]]; then
    consensus_label="consensus"
  else
    consensus_label="no-consensus"
  fi

  local action_label
  case "$chosen_action" in
    "$ACTION_APPLY_CLAUDE")       action_label="applied:claude" ;;
    "$ACTION_APPLY_CODEX")        action_label="applied:codex" ;;
    "$ACTION_CONTINUE")           action_label="continuing" ;;
    "$ACTION_DISCARD")            action_label="discarded" ;;
    "$ACTION_CONSENSUS_ACCEPT")   action_label="accepted" ;;
    "$ACTION_CONSENSUS_REJECT")   action_label="rejected" ;;
    "$ACTION_PENDING")            action_label="pending" ;;
    *)                            action_label="$chosen_action" ;;
  esac

  local trigger_label
  case "$trigger_cause" in
    "$TRIGGER_SAFETY_HOOK")  trigger_label="hook" ;;
    "$TRIGGER_RULE_ENGINE")  trigger_label="rule" ;;
    *)                       trigger_label="manual" ;;
  esac

  echo "[codex-collab] Debate: \"${topic}\" | ${rounds} round(s) | ${consensus_label} | action=${action_label} | trigger=${trigger_label}"
}

# ===========================================================================
# CLI MODE
# ===========================================================================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  CLI_RESULT=""
  CLI_RESULT_FILE=""
  CLI_ACTION="$ACTION_PENDING"
  CLI_TRIGGER="$TRIGGER_MANUAL"
  CLI_ACTION_STATUS=""
  CLI_ACTION_DETAILS=""
  CLI_SESSION=""
  CLI_FORMAT="text"  # text | json | compact

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result)         CLI_RESULT="$2"; shift 2 ;;
      --result-file)    CLI_RESULT_FILE="$2"; shift 2 ;;
      --action)         CLI_ACTION="$2"; shift 2 ;;
      --trigger)        CLI_TRIGGER="$2"; shift 2 ;;
      --action-status)  CLI_ACTION_STATUS="$2"; shift 2 ;;
      --action-details) CLI_ACTION_DETAILS="$2"; shift 2 ;;
      --session)        CLI_SESSION="$2"; shift 2 ;;
      --format)         CLI_FORMAT="$2"; shift 2 ;;
      --save)
        # Save to reports dir after composing
        CLI_FORMAT="save"
        shift
        ;;
      --help|-h)
        echo "Usage: compose-report.sh --result '<json>' [OPTIONS]"
        echo ""
        echo "Compose a final debate report combining all debate elements."
        echo ""
        echo "Input (one required):"
        echo "  --result <json>        Debate result JSON string"
        echo "  --result-file <path>   Path to debate result JSON file"
        echo ""
        echo "Options:"
        echo "  --action <action>      Chosen action:"
        echo "                           apply_claude, apply_codex, continue,"
        echo "                           discard, consensus_accept, consensus_reject,"
        echo "                           pending (default)"
        echo "  --trigger <cause>      Trigger cause: manual (default), safety_hook, rule_engine"
        echo "  --action-status <s>    Action status (applied, partial_failure, etc.)"
        echo "  --action-details <d>   Additional action details"
        echo "  --session <id>         Session ID"
        echo "  --format <fmt>         Output format: text (default), json, compact"
        echo "  --save                 Also save report to .codex-collab/reports/"
        echo "  --help, -h             Show this help"
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  # Load result from file if specified
  if [[ -n "$CLI_RESULT_FILE" && -z "$CLI_RESULT" ]]; then
    if [[ ! -f "$CLI_RESULT_FILE" ]]; then
      echo "[codex-collab] ERROR: Result file not found: ${CLI_RESULT_FILE}" >&2
      exit 1
    fi
    CLI_RESULT="$(cat "$CLI_RESULT_FILE")"
  fi

  if [[ -z "$CLI_RESULT" ]]; then
    echo "[codex-collab] ERROR: --result or --result-file is required" >&2
    echo "Usage: compose-report.sh --result '<json>'" >&2
    exit 1
  fi

  case "$CLI_FORMAT" in
    json)
      compose_report_json "$CLI_RESULT" "$CLI_ACTION" "$CLI_TRIGGER" \
        "$CLI_ACTION_STATUS" "$CLI_ACTION_DETAILS"
      ;;
    compact)
      compose_compact_report "$CLI_RESULT" "$CLI_ACTION" "$CLI_TRIGGER"
      ;;
    save)
      compose_and_save_report "$CLI_RESULT" "$CLI_ACTION" "$CLI_TRIGGER" \
        "$CLI_ACTION_STATUS" "$CLI_ACTION_DETAILS"
      ;;
    text|*)
      compose_final_report "$CLI_RESULT" "$CLI_ACTION" "$CLI_TRIGGER" \
        "$CLI_ACTION_STATUS" "$CLI_ACTION_DETAILS"
      ;;
  esac
fi
