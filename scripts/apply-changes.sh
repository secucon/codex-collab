#!/usr/bin/env bash
# apply-changes.sh — codex-collab debate result code change applicator
#
# Applies approved diffs/code changes from debate consensus to the codebase.
# Requires explicit user acceptance — NEVER auto-applies without approval.
#
# Usage:
#   # Source for shell functions:
#   source scripts/apply-changes.sh
#   apply_debate_result "<result_file>" "<working_dir>"
#
#   # Or run directly:
#   ./scripts/apply-changes.sh --result <result_file> --workdir <dir> [--dry-run]
#
# Dependencies:
#   - scripts/load-config.sh (for config_get)
#   - git (for backup/rollback support)
#   - python3 (for JSON/diff parsing)
#
# Exit codes:
#   0 — changes applied successfully
#   1 — fatal error (missing dependencies, parse failure)
#   2 — user rejected changes (not an error)
#   3 — dry-run completed (no changes applied)
#   4 — no applicable changes found in result

set -euo pipefail

# ---------------------------------------------------------------------------
# Source config loader if not already loaded
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
  if [[ -f "${SCRIPT_DIR}/load-config.sh" ]]; then
    source "${SCRIPT_DIR}/load-config.sh"
    load_config 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
APPLY_LOG_DIR="${TMPDIR:-/tmp}/codex-collab-apply"
BACKUP_BRANCH_PREFIX="codex-collab-backup"

# ---------------------------------------------------------------------------
# extract_code_changes — Parse debate result for actionable code changes
# ---------------------------------------------------------------------------
# Extracts code blocks, diffs, and file modifications from debate consensus
# output. Supports:
#   - Unified diff format (--- a/file, +++ b/file)
#   - Fenced code blocks with file path annotations (```lang:path/to/file)
#   - Structured JSON with "changes" array
#
# Args:
#   $1 — path to debate result file (text or JSON)
#   $2 — output directory for extracted changes
#
# Returns: number of extracted change sets (0 if none found)
# ---------------------------------------------------------------------------
extract_code_changes() {
  local result_file="$1"
  local output_dir="$2"

  mkdir -p "$output_dir"

  python3 - "$result_file" "$output_dir" <<'PYEOF'
import sys
import os
import json
import re

result_file = sys.argv[1]
output_dir = sys.argv[2]

with open(result_file, 'r', encoding='utf-8') as f:
    content = f.read()

changes = []

# Strategy 1: Parse unified diff blocks
diff_pattern = re.compile(
    r'^---\s+a/(.+?)\n\+\+\+\s+b/(.+?)\n(@@.+?)(?=\n---\s+a/|\Z)',
    re.MULTILINE | re.DOTALL
)
for match in diff_pattern.finditer(content):
    original_file = match.group(1)
    target_file = match.group(2)
    diff_content = f"--- a/{original_file}\n+++ b/{target_file}\n{match.group(3)}"
    changes.append({
        "type": "unified_diff",
        "file": target_file,
        "content": diff_content
    })

# Strategy 2: Parse fenced code blocks with file annotations
# Matches: ```lang:path/to/file or ```lang path/to/file
code_block_pattern = re.compile(
    r'```(?:\w+)?[:\s]+([^\s`]+?)\n(.*?)```',
    re.DOTALL
)
for match in code_block_pattern.finditer(content):
    file_path = match.group(1)
    code_content = match.group(2).rstrip('\n')
    # Skip if this looks like a diff (already captured above)
    if code_content.strip().startswith('--- a/'):
        continue
    # Only include if file_path looks like a real path
    if '/' in file_path or '.' in file_path:
        changes.append({
            "type": "file_content",
            "file": file_path,
            "content": code_content
        })

# Strategy 3: Parse structured JSON with changes array
try:
    data = json.loads(content)
    if isinstance(data, dict):
        json_changes = data.get("changes", data.get("code_changes", []))
        if isinstance(json_changes, list):
            for change in json_changes:
                if isinstance(change, dict) and "file" in change:
                    changes.append({
                        "type": change.get("type", "file_content"),
                        "file": change["file"],
                        "content": change.get("content", change.get("diff", ""))
                    })
except (json.JSONDecodeError, ValueError):
    pass

# Write extracted changes as individual files + manifest
manifest = []
for i, change in enumerate(changes):
    change_file = os.path.join(output_dir, f"change-{i:03d}.patch" if change["type"] == "unified_diff" else f"change-{i:03d}.content")
    with open(change_file, 'w', encoding='utf-8') as f:
        f.write(change["content"])
    manifest.append({
        "index": i,
        "type": change["type"],
        "file": change["file"],
        "patch_path": change_file
    })

# Write manifest
manifest_path = os.path.join(output_dir, "manifest.json")
with open(manifest_path, 'w', encoding='utf-8') as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)

print(len(changes))
PYEOF
}

# ---------------------------------------------------------------------------
# preview_changes — Show user what will be applied (dry-run display)
# ---------------------------------------------------------------------------
preview_changes() {
  local output_dir="$1"
  local manifest_file="${output_dir}/manifest.json"

  if [[ ! -f "$manifest_file" ]]; then
    echo "[codex-collab] No changes manifest found"
    return 1
  fi

  local change_count
  change_count=$(python3 -c "import json; print(len(json.load(open('${manifest_file}'))))" 2>/dev/null || echo "0")

  if [[ "$change_count" == "0" ]]; then
    echo "[codex-collab] No applicable code changes found in debate result"
    return 4
  fi

  echo ""
  echo "[codex-collab] ━━━ Proposed Changes Preview ━━━"
  echo "[codex-collab] ${change_count} file(s) will be modified:"
  echo ""

  python3 - "$manifest_file" <<'PYEOF'
import json
import sys
import os

manifest = json.load(open(sys.argv[1]))

for entry in manifest:
    change_type = "PATCH" if entry["type"] == "unified_diff" else "WRITE"
    file_path = entry["file"]
    patch_path = entry["patch_path"]

    exists = "exists" if os.path.isfile(file_path) else "NEW"
    print(f"  [{change_type}] {file_path} ({exists})")

    # Show abbreviated content
    with open(patch_path, 'r') as f:
        lines = f.readlines()
    preview_lines = lines[:15]
    print("  ┌─────────────────────────────────────")
    for line in preview_lines:
        print(f"  │ {line.rstrip()}")
    if len(lines) > 15:
        print(f"  │ ... ({len(lines) - 15} more lines)")
    print("  └─────────────────────────────────────")
    print()
PYEOF
}

# ---------------------------------------------------------------------------
# create_backup — Create git backup before applying changes
# ---------------------------------------------------------------------------
create_backup() {
  local working_dir="$1"
  local backup_id="$2"

  cd "$working_dir"

  # Check if we're in a git repo
  if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "[codex-collab] ⚠ Not a git repository — skipping backup (changes cannot be auto-rolled back)"
    return 0
  fi

  # Check for uncommitted changes
  if ! git diff --quiet HEAD 2>/dev/null; then
    echo "[codex-collab] ⚠ Working tree has uncommitted changes — creating stash backup"
    git stash push -m "codex-collab-backup-${backup_id}" --quiet 2>/dev/null || true
    echo "[codex-collab] ✓ Stash created: codex-collab-backup-${backup_id}"
    echo "stash"
    return 0
  fi

  # Store current HEAD for rollback
  local current_head
  current_head=$(git rev-parse HEAD 2>/dev/null)
  echo "[codex-collab] ✓ Backup point: ${current_head:0:8}"
  echo "head:${current_head}"
  return 0
}

# ---------------------------------------------------------------------------
# apply_unified_diff — Apply a unified diff patch
# ---------------------------------------------------------------------------
apply_unified_diff() {
  local patch_file="$1"
  local working_dir="$2"

  cd "$working_dir"

  # Try git apply first (cleanest)
  if git apply --check "$patch_file" 2>/dev/null; then
    git apply "$patch_file" 2>/dev/null
    return $?
  fi

  # Fallback: patch command with fuzz factor
  if command -v patch &>/dev/null; then
    patch -p1 --fuzz=2 < "$patch_file" 2>/dev/null
    return $?
  fi

  echo "[codex-collab] ERROR: Cannot apply diff — neither git apply nor patch succeeded" >&2
  return 1
}

# ---------------------------------------------------------------------------
# apply_file_content — Write file content directly
# ---------------------------------------------------------------------------
apply_file_content() {
  local content_file="$1"
  local target_file="$2"
  local working_dir="$3"

  local full_target="${working_dir}/${target_file}"
  local target_dir
  target_dir=$(dirname "$full_target")

  # Create parent directories if needed
  mkdir -p "$target_dir"

  # Copy content to target
  cp "$content_file" "$full_target"
  return $?
}

# ---------------------------------------------------------------------------
# apply_all_changes — Apply all extracted changes from manifest
# ---------------------------------------------------------------------------
apply_all_changes() {
  local output_dir="$1"
  local working_dir="$2"
  local manifest_file="${output_dir}/manifest.json"

  if [[ ! -f "$manifest_file" ]]; then
    echo "[codex-collab] ERROR: No manifest file found" >&2
    return 1
  fi

  local applied=0
  local failed=0
  local total

  total=$(python3 -c "import json; print(len(json.load(open('${manifest_file}'))))" 2>/dev/null || echo "0")

  if [[ "$total" == "0" ]]; then
    echo "[codex-collab] No changes to apply"
    return 4
  fi

  # Process each change entry
  while IFS= read -r entry; do
    local change_type file patch_path
    change_type=$(echo "$entry" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['type'])")
    file=$(echo "$entry" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['file'])")
    patch_path=$(echo "$entry" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['patch_path'])")

    echo -n "[codex-collab] Applying: ${file} ... "

    if [[ "$change_type" == "unified_diff" ]]; then
      if apply_unified_diff "$patch_path" "$working_dir"; then
        echo "✓"
        ((applied++))
      else
        echo "✗ FAILED"
        ((failed++))
      fi
    else
      if apply_file_content "$patch_path" "$file" "$working_dir"; then
        echo "✓"
        ((applied++))
      else
        echo "✗ FAILED"
        ((failed++))
      fi
    fi
  done < <(python3 -c "
import json, sys
manifest = json.load(open('${manifest_file}'))
for entry in manifest:
    print(json.dumps(entry))
")

  echo ""
  echo "[codex-collab] ━━━ Apply Summary ━━━"
  echo "[codex-collab] Applied: ${applied}/${total} | Failed: ${failed}"

  if [[ "$failed" -gt 0 ]]; then
    echo "[codex-collab] ⚠ Some changes failed to apply. Review manually."
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# rollback_changes — Rollback to backup point
# ---------------------------------------------------------------------------
rollback_changes() {
  local working_dir="$1"
  local backup_ref="$2"

  cd "$working_dir"

  if [[ "$backup_ref" == "stash" ]]; then
    echo "[codex-collab] Rolling back via stash pop..."
    git checkout -- . 2>/dev/null
    git stash pop --quiet 2>/dev/null || true
    echo "[codex-collab] ✓ Rolled back to pre-apply state"
  elif [[ "$backup_ref" == head:* ]]; then
    local commit_hash="${backup_ref#head:}"
    echo "[codex-collab] Rolling back to ${commit_hash:0:8}..."
    git checkout -- . 2>/dev/null
    echo "[codex-collab] ✓ Rolled back to pre-apply state"
  else
    echo "[codex-collab] ⚠ No backup reference — manual rollback may be needed"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# apply_debate_result — Main entry point for debate result application
# ---------------------------------------------------------------------------
# This is the primary function called by workflow-orchestrator after user
# accepts debate consensus changes.
#
# Flow:
#   1. Check config (debate.auto_apply_result)
#   2. Extract code changes from result
#   3. Preview changes to user
#   4. REQUIRE user approval (safety gate — never bypassed)
#   5. Create git backup
#   6. Apply changes
#   7. Report results
#
# Args:
#   $1 — path to debate result file
#   $2 — working directory (default: pwd)
#   $3 — "dry-run" to skip actual application (optional)
#
# Returns: exit code (see file header)
# ---------------------------------------------------------------------------
apply_debate_result() {
  local result_file="$1"
  local working_dir="${2:-$(pwd)}"
  local mode="${3:-apply}"

  # Validate inputs
  if [[ ! -f "$result_file" ]]; then
    echo "[codex-collab] ERROR: Result file not found: ${result_file}" >&2
    return 1
  fi

  if [[ ! -d "$working_dir" ]]; then
    echo "[codex-collab] ERROR: Working directory not found: ${working_dir}" >&2
    return 1
  fi

  # Check config — auto_apply_result controls whether apply is even offered
  local auto_apply
  auto_apply=$(config_get "debate.auto_apply_result" "false" 2>/dev/null || echo "false")

  # Create temp directory for extracted changes
  local apply_id
  apply_id="apply-$(date +%s)"
  local change_dir="${APPLY_LOG_DIR}/${apply_id}"
  mkdir -p "$change_dir"

  echo "[codex-collab] Analyzing debate result for applicable code changes..."

  # Step 1: Extract code changes
  local change_count
  change_count=$(extract_code_changes "$result_file" "$change_dir")

  if [[ "$change_count" == "0" || -z "$change_count" ]]; then
    echo "[codex-collab] No actionable code changes found in debate result"
    echo "[codex-collab] The debate consensus is informational only — no files to modify"
    return 4
  fi

  echo "[codex-collab] Found ${change_count} code change(s) in debate result"

  # Step 2: Preview changes
  preview_changes "$change_dir"

  # Step 3: Dry-run mode — stop here
  if [[ "$mode" == "dry-run" ]]; then
    echo "[codex-collab] DRY RUN complete — no changes applied"
    return 3
  fi

  # Step 4: User approval gate (MANDATORY — never bypassed)
  # This echoes the approval prompt; the calling agent (workflow-orchestrator)
  # is responsible for presenting this to the user and collecting the response.
  # The script itself does NOT read stdin — approval flow is agent-mediated.
  echo ""
  echo "[codex-collab] ━━━ User Approval Required ━━━"
  echo "[codex-collab] The above changes will be applied to: ${working_dir}"
  echo "[codex-collab] APPROVAL_REQUIRED=true"
  echo "[codex-collab] CHANGE_COUNT=${change_count}"
  echo "[codex-collab] CHANGE_DIR=${change_dir}"
  echo "[codex-collab] WORKING_DIR=${working_dir}"

  # Return here — the orchestrator agent handles the approval flow
  # and calls execute_approved_changes if the user accepts
  return 0
}

# ---------------------------------------------------------------------------
# execute_approved_changes — Apply changes after user approval
# ---------------------------------------------------------------------------
# Called by workflow-orchestrator ONLY after user explicitly approves.
#
# Args:
#   $1 — change directory (from apply_debate_result output)
#   $2 — working directory
#
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------
execute_approved_changes() {
  local change_dir="$1"
  local working_dir="$2"

  if [[ ! -d "$change_dir" ]]; then
    echo "[codex-collab] ERROR: Change directory not found: ${change_dir}" >&2
    return 1
  fi

  # Step 1: Create backup
  echo "[codex-collab] Creating backup before applying changes..."
  local backup_ref
  backup_ref=$(create_backup "$working_dir" "$(date +%s)")

  # Step 2: Apply all changes
  echo "[codex-collab] Applying approved changes..."
  if apply_all_changes "$change_dir" "$working_dir"; then
    echo "[codex-collab] ✓ All changes applied successfully"
    echo "[codex-collab] APPLY_STATUS=success"

    # Log the application
    local log_file="${change_dir}/apply-log.json"
    python3 -c "
import json
from datetime import datetime
log = {
    'timestamp': datetime.now().isoformat(),
    'working_dir': '${working_dir}',
    'status': 'success',
    'backup_ref': '${backup_ref}'
}
with open('${log_file}', 'w') as f:
    json.dump(log, f, indent=2)
" 2>/dev/null || true

    return 0
  else
    echo "[codex-collab] ✗ Some changes failed to apply"
    echo "[codex-collab] APPLY_STATUS=partial_failure"

    # Offer rollback
    echo "[codex-collab] ROLLBACK_AVAILABLE=true"
    echo "[codex-collab] BACKUP_REF=${backup_ref}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# execute_rollback — Rollback changes after failed apply
# ---------------------------------------------------------------------------
execute_rollback() {
  local working_dir="$1"
  local backup_ref="$2"

  rollback_changes "$working_dir" "$backup_ref"
  return $?
}

# ---------------------------------------------------------------------------
# CLI mode — run directly
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  RESULT_FILE=""
  WORKING_DIR="$(pwd)"
  MODE="apply"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result)   RESULT_FILE="$2"; shift 2 ;;
      --workdir)  WORKING_DIR="$2"; shift 2 ;;
      --dry-run)  MODE="dry-run"; shift ;;
      --execute)
        # Direct execution mode (post-approval)
        CHANGE_DIR="$2"
        shift 2
        execute_approved_changes "$CHANGE_DIR" "$WORKING_DIR"
        exit $?
        ;;
      --rollback)
        BACKUP_REF="$2"
        shift 2
        execute_rollback "$WORKING_DIR" "$BACKUP_REF"
        exit $?
        ;;
      --help|-h)
        echo "Usage: apply-changes.sh --result <file> [--workdir <dir>] [--dry-run]"
        echo "       apply-changes.sh --execute <change_dir> [--workdir <dir>]"
        echo "       apply-changes.sh --rollback <backup_ref> [--workdir <dir>]"
        echo ""
        echo "Applies approved code changes from debate results."
        echo ""
        echo "Options:"
        echo "  --result <file>     Debate result file to parse for changes"
        echo "  --workdir <dir>     Working directory (default: cwd)"
        echo "  --dry-run           Preview changes without applying"
        echo "  --execute <dir>     Apply pre-extracted changes (post-approval)"
        echo "  --rollback <ref>    Rollback to backup point"
        echo "  --help, -h          Show this help"
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$RESULT_FILE" ]]; then
    echo "ERROR: --result is required" >&2
    exit 1
  fi

  apply_debate_result "$RESULT_FILE" "$WORKING_DIR" "$MODE"
fi
