#!/usr/bin/env bash
# debate-result-approval.sh — User approval flow for debate results
#
# Presents debate consensus/result to the user with diff, rationale, and
# an accept/reject prompt. This script is called by workflow-orchestrator
# after a debate completes when the result proposes code changes.
#
# Usage:
#   source scripts/debate-result-approval.sh
#
#   # Present approval prompt and capture decision
#   present_approval_prompt "$debate_result_json" "$session_id"
#
#   # Or run standalone for testing
#   ./scripts/debate-result-approval.sh --result-file <path> --session <id>
#
# Environment:
#   Requires: scripts/load-config.sh to be sourced first (for config_get)
#
# Exit codes:
#   0 — user accepted
#   1 — user rejected
#   2 — invalid input / error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source load-config if not already loaded
if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
  if [[ -f "${SCRIPT_DIR}/load-config.sh" ]]; then
    source "${SCRIPT_DIR}/load-config.sh"
    load_config 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
APPROVAL_BORDER="═══════════════════════════════════════════════════════════════"
APPROVAL_DIVIDER="───────────────────────────────────────────────────────────────"

# ---------------------------------------------------------------------------
# Format debate result as a reviewable diff + rationale
# ---------------------------------------------------------------------------
format_debate_summary() {
  local result_json="$1"

  if ! command -v python3 &>/dev/null; then
    echo "[codex-collab] ERROR: python3 is required for approval formatting" >&2
    return 1
  fi

  python3 - "$result_json" <<'PYEOF'
import sys
import json

def format_summary(result_json_str):
    """Format debate result into a human-readable approval prompt."""
    try:
        result = json.loads(result_json_str)
    except json.JSONDecodeError:
        print("[codex-collab] ERROR: Invalid debate result JSON", file=sys.stderr)
        sys.exit(2)

    topic = result.get("topic", "Unknown topic")
    rounds = result.get("rounds", [])
    consensus = result.get("consensus_reached", False)
    final_position = result.get("final_position", "No position recorded")
    proposed_changes = result.get("proposed_changes", None)
    rationale = result.get("rationale", [])
    affected_files = result.get("affected_files", [])
    confidence = result.get("final_confidence", 0.0)

    lines = []
    lines.append("")
    lines.append("╔" + "═" * 63 + "╗")
    lines.append("║  📋 Debate Result — User Approval Required" + " " * 19 + "║")
    lines.append("╚" + "═" * 63 + "╝")
    lines.append("")

    # Topic & Summary
    lines.append(f"📌 Topic: {topic}")
    lines.append(f"🔄 Rounds: {len(rounds)}")
    status = "✅ Consensus Reached" if consensus else "⚠️  No Consensus (majority position)"
    lines.append(f"📊 Status: {status}")
    lines.append(f"🎯 Confidence: {confidence:.0%}")
    lines.append("")

    # Rationale
    lines.append("─" * 63)
    lines.append("📝 Rationale")
    lines.append("─" * 63)
    if rationale:
        for i, r in enumerate(rationale, 1):
            lines.append(f"  {i}. {r}")
    else:
        lines.append(f"  {final_position}")
    lines.append("")

    # Proposed Changes (diff-style)
    if proposed_changes:
        lines.append("─" * 63)
        lines.append("📂 Proposed Changes")
        lines.append("─" * 63)

        if affected_files:
            lines.append("")
            lines.append("  Affected files:")
            for f in affected_files:
                lines.append(f"    • {f}")
            lines.append("")

        if isinstance(proposed_changes, list):
            for change in proposed_changes:
                file_path = change.get("file", "unknown")
                change_type = change.get("type", "modify")
                description = change.get("description", "")
                diff = change.get("diff", "")

                type_icon = {"create": "🆕", "modify": "✏️ ", "delete": "🗑️ "}.get(change_type, "📄")
                lines.append(f"  {type_icon} {file_path} ({change_type})")
                if description:
                    lines.append(f"     {description}")

                if diff:
                    lines.append("")
                    for diff_line in diff.splitlines():
                        if diff_line.startswith("+"):
                            lines.append(f"     \033[32m{diff_line}\033[0m")
                        elif diff_line.startswith("-"):
                            lines.append(f"     \033[31m{diff_line}\033[0m")
                        elif diff_line.startswith("@@"):
                            lines.append(f"     \033[36m{diff_line}\033[0m")
                        else:
                            lines.append(f"     {diff_line}")
                    lines.append("")
        elif isinstance(proposed_changes, str):
            lines.append(f"  {proposed_changes}")
        lines.append("")

    # Key arguments from both sides
    if rounds:
        lines.append("─" * 63)
        lines.append("💬 Key Arguments Summary")
        lines.append("─" * 63)
        last_round = rounds[-1] if rounds else {}
        codex_args = last_round.get("codex", {}).get("key_arguments", [])
        claude_args = last_round.get("claude", {}).get("key_arguments", [])

        if codex_args:
            lines.append("  Codex (GPT-5.4):")
            for arg in codex_args[:3]:
                lines.append(f"    • {arg}")
        if claude_args:
            lines.append("  Claude:")
            for arg in claude_args[:3]:
                lines.append(f"    • {arg}")
        lines.append("")

    # Approval prompt
    lines.append("═" * 63)
    lines.append("")
    lines.append("  ⚡ Action Required: Review the above and respond:")
    lines.append("")
    lines.append("    ✅ ACCEPT  — Apply the proposed changes")
    lines.append("    ❌ REJECT  — Discard changes, keep current state")
    lines.append("    📝 MODIFY  — Accept with modifications (provide instructions)")
    lines.append("")
    lines.append("═" * 63)

    return "\n".join(lines)

# Main
result_json_str = sys.argv[1]
print(format_summary(result_json_str))
PYEOF
}

# ---------------------------------------------------------------------------
# Parse user approval decision
# ---------------------------------------------------------------------------
parse_approval_decision() {
  local user_response="$1"

  # Normalize to lowercase
  local normalized
  normalized=$(echo "$user_response" | tr '[:upper:]' '[:lower:]' | xargs)

  case "$normalized" in
    accept|yes|y|approve|ok|확인|승인|적용)
      echo "accepted"
      return 0
      ;;
    reject|no|n|deny|cancel|거부|취소|거절)
      echo "rejected"
      return 1
      ;;
    modify|edit|change|수정|변경)
      echo "modify"
      return 0
      ;;
    *)
      # Check for partial matches
      if echo "$normalized" | grep -qiE '(accept|approve|yes|확인|승인)'; then
        echo "accepted"
        return 0
      elif echo "$normalized" | grep -qiE '(reject|deny|no|cancel|거부|취소)'; then
        echo "rejected"
        return 1
      elif echo "$normalized" | grep -qiE '(modify|edit|change|수정|변경)'; then
        echo "modify"
        return 0
      fi
      echo "unknown"
      return 2
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Create approval record for session history
# ---------------------------------------------------------------------------
create_approval_record() {
  local session_id="$1"
  local decision="$2"
  local topic="$3"
  local modifications="${4:-}"

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  python3 - "$session_id" "$decision" "$topic" "$modifications" "$timestamp" <<'PYEOF'
import sys
import json

session_id = sys.argv[1]
decision = sys.argv[2]
topic = sys.argv[3]
modifications = sys.argv[4] if len(sys.argv) > 4 else ""
timestamp = sys.argv[5]

record = {
    "type": "debate_approval",
    "session_id": session_id,
    "timestamp": timestamp,
    "decision": decision,
    "topic": topic,
    "applied": decision == "accepted" or decision == "modify",
}

if modifications:
    record["modifications"] = modifications

print(json.dumps(record, ensure_ascii=False))
PYEOF
}

# ---------------------------------------------------------------------------
# Main approval presentation flow
# ---------------------------------------------------------------------------
present_approval_prompt() {
  local result_json="$1"
  local session_id="${2:-unknown}"

  # Check if approval is required (safety.require_approval is always true)
  local require_approval
  require_approval=$(config_get "safety.require_approval" "true" 2>/dev/null || echo "true")

  if [[ "$require_approval" != "true" ]]; then
    # Safety invariant: this should never happen (enforced by load-config.sh)
    echo "[codex-collab] WARNING: require_approval was false — forcing to true (safety invariant)" >&2
    require_approval="true"
  fi

  # Check if debate.auto_apply_result is set (still requires approval)
  local auto_apply
  auto_apply=$(config_get "debate.auto_apply_result" "false" 2>/dev/null || echo "false")

  # Format and display the debate result
  local formatted
  formatted=$(format_debate_summary "$result_json" 2>/dev/null)
  if [[ $? -ne 0 ]]; then
    echo "[codex-collab] ERROR: Failed to format debate result for approval" >&2
    return 2
  fi

  echo "$formatted"

  if [[ "$auto_apply" == "true" ]]; then
    echo ""
    echo "[codex-collab] ℹ️  debate.auto_apply_result is enabled, but user approval is still required (safety.require_approval: true)"
    echo ""
  fi

  # Return formatted output for the orchestrator to present to the user
  # The orchestrator will collect the user's response and call parse_approval_decision
  return 0
}

# ---------------------------------------------------------------------------
# Generate approval status line for status summary
# ---------------------------------------------------------------------------
approval_status_line() {
  local decision="$1"

  case "$decision" in
    accepted)
      echo "✅ Debate result: ACCEPTED — changes will be applied"
      ;;
    rejected)
      echo "❌ Debate result: REJECTED — no changes applied"
      ;;
    modify)
      echo "📝 Debate result: ACCEPTED WITH MODIFICATIONS — applying with user edits"
      ;;
    *)
      echo "⏳ Debate result: PENDING — awaiting user decision"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Validate proposed changes before applying
# ---------------------------------------------------------------------------
validate_proposed_changes() {
  local result_json="$1"

  python3 - "$result_json" <<'PYEOF'
import sys
import json

try:
    result = json.loads(sys.argv[1])
except json.JSONDecodeError:
    print(json.dumps({"valid": False, "error": "Invalid JSON"}))
    sys.exit(0)

proposed = result.get("proposed_changes")
issues = []

if proposed is None:
    print(json.dumps({"valid": True, "has_changes": False, "message": "No code changes proposed — informational result only"}))
    sys.exit(0)

if isinstance(proposed, list):
    for i, change in enumerate(proposed):
        if not isinstance(change, dict):
            issues.append(f"Change {i}: not a valid change object")
            continue
        if "file" not in change:
            issues.append(f"Change {i}: missing 'file' field")
        change_type = change.get("type", "modify")
        if change_type not in ("create", "modify", "delete"):
            issues.append(f"Change {i}: invalid type '{change_type}'")

if issues:
    print(json.dumps({"valid": False, "has_changes": True, "issues": issues}))
else:
    change_count = len(proposed) if isinstance(proposed, list) else 1
    print(json.dumps({"valid": True, "has_changes": True, "change_count": change_count}))
PYEOF
}

# ---------------------------------------------------------------------------
# CLI mode — run directly for testing
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  RESULT_FILE=""
  SESSION_ID="test-session"
  USER_RESPONSE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result-file) RESULT_FILE="$2"; shift 2 ;;
      --session)     SESSION_ID="$2"; shift 2 ;;
      --response)    USER_RESPONSE="$2"; shift 2 ;;
      --help|-h)
        echo "Usage: debate-result-approval.sh [OPTIONS]"
        echo ""
        echo "Present debate results for user approval."
        echo ""
        echo "Options:"
        echo "  --result-file <path>  Path to debate result JSON file"
        echo "  --session <id>        Session ID (default: test-session)"
        echo "  --response <text>     Simulate user response (for testing)"
        echo "  --help, -h            Show this help"
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
    echo "[codex-collab] ERROR: Result file not found: $RESULT_FILE" >&2
    exit 1
  fi

  RESULT_JSON=$(cat "$RESULT_FILE")

  # Validate changes first
  echo "[codex-collab] Validating proposed changes..."
  VALIDATION=$(validate_proposed_changes "$RESULT_JSON")
  echo "$VALIDATION" | python3 -c "
import sys, json
v = json.load(sys.stdin)
if not v.get('has_changes', False):
    print('[codex-collab] ' + v.get('message', 'No changes to apply'))
elif not v.get('valid', False):
    print('[codex-collab] WARNING: Validation issues found:')
    for issue in v.get('issues', []):
        print(f'  ⚠️  {issue}')
else:
    count = v.get('change_count', 0)
    print(f'[codex-collab] ✓ {count} proposed change(s) validated')
" 2>/dev/null

  # Present approval prompt
  present_approval_prompt "$RESULT_JSON" "$SESSION_ID"

  # If user response provided (testing mode), process it
  if [[ -n "$USER_RESPONSE" ]]; then
    echo ""
    echo "[codex-collab] User response: $USER_RESPONSE"
    DECISION=$(parse_approval_decision "$USER_RESPONSE" || true)
    EXIT_CODE=0
    case "$DECISION" in
      accepted) EXIT_CODE=0 ;;
      rejected) EXIT_CODE=1 ;;
      modify)   EXIT_CODE=0 ;;
      *)        EXIT_CODE=2 ;;
    esac
    echo "[codex-collab] Decision: $DECISION"
    echo "$(approval_status_line "$DECISION")"

    # Create approval record
    if [[ "$DECISION" != "unknown" ]]; then
      TOPIC=$(echo "$RESULT_JSON" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('topic',''))" 2>/dev/null || echo "")
      RECORD=$(create_approval_record "$SESSION_ID" "$DECISION" "$TOPIC")
      echo "[codex-collab] Approval record: $RECORD"
    fi

    exit $EXIT_CODE
  fi
fi
