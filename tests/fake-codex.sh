#!/usr/bin/env bash
# fake-codex.sh — Fake Codex CLI mock for behavioral QA testing
#
# Simulates the codex CLI binary by returning pre-defined JSONL fixtures
# based on the FAKE_CODEX_SCENARIO environment variable. Supports all
# invocation patterns used by codex-delegator: exec, exec resume, review.
#
# Usage:
#   export FAKE_CODEX_SCENARIO=debate-consensus   # choose scenario
#   export PATH="$(dirname /path/to/fake-codex.sh):$PATH"  # shadow real codex
#   codex exec -o /tmp/out.md -C /project -s read-only --json "prompt"
#
# Supported scenarios (FAKE_CODEX_SCENARIO):
#   session-start        — New session creation with session_id in JSONL
#   session-resume       — Resume existing session (no JSONL, output only)
#   debate-round         — Single debate round with structured position JSON
#   debate-consensus     — Debate round where Codex agrees (consensus reached)
#   debate-multi-round   — Multi-round debate (3 rounds of JSONL events)
#   evaluate             — Code evaluation with structured findings
#   ask-readonly         — Simple read-only question response
#   ask-write            — Write-mode response with file modifications
#   error-auth           — Simulates authentication failure
#   error-timeout        — Simulates timeout (sleeps then exits)
#   error-empty          — Simulates empty response
#   error-crash          — Simulates non-zero exit with stderr
#
# Environment variables:
#   FAKE_CODEX_SCENARIO     — (required) Scenario name from above list
#   FAKE_CODEX_SESSION_ID   — Override session ID (default: fake-session-001)
#   FAKE_CODEX_DELAY        — Artificial delay in seconds (default: 0)
#   FAKE_CODEX_FIXTURES_DIR — Override fixtures directory
#
# Exit codes mirror real codex:
#   0 — success
#   1 — general error
#   2 — auth error

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────

SCENARIO="${FAKE_CODEX_SCENARIO:-}"
SESSION_ID="${FAKE_CODEX_SESSION_ID:-fake-session-001}"
DELAY="${FAKE_CODEX_DELAY:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="${FAKE_CODEX_FIXTURES_DIR:-$SCRIPT_DIR/fixtures}"

# ── Argument Parsing ──────────────────────────────────────────────────────

OUTPUT_FILE=""
JSON_MODE=0
IS_RESUME=0
WORKING_DIR=""
SANDBOX_MODE=""
PROMPT=""
HAS_OUTPUT_SCHEMA=0

# Parse arguments to mimic real codex CLI interface
while [[ $# -gt 0 ]]; do
  case "$1" in
    exec)
      shift
      ;;
    resume)
      IS_RESUME=1
      shift
      # Next arg is session ID (consume it)
      if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
        shift
      fi
      ;;
    review)
      shift
      ;;
    fork)
      shift
      # Consume session ID
      if [[ $# -gt 0 && ! "$1" =~ ^- ]]; then
        shift
      fi
      ;;
    -o)
      shift
      OUTPUT_FILE="${1:-}"
      shift
      ;;
    -C)
      shift
      WORKING_DIR="${1:-}"
      shift
      ;;
    -s)
      shift
      SANDBOX_MODE="${1:-}"
      shift
      ;;
    --json)
      JSON_MODE=1
      shift
      ;;
    --full-auto)
      shift
      ;;
    --ephemeral)
      shift
      ;;
    -m)
      shift
      shift  # consume model name
      ;;
    --output-schema)
      HAS_OUTPUT_SCHEMA=1
      shift
      shift  # consume schema value
      ;;
    --output-schema=*)
      HAS_OUTPUT_SCHEMA=1
      shift
      ;;
    -a)
      shift
      shift  # consume approval mode
      ;;
    --uncommitted|--base)
      shift
      if [[ "$1" != -* ]] 2>/dev/null; then
        shift
      fi
      ;;
    --dangerously-bypass-approvals-and-sandbox)
      echo "[fake-codex] ERROR: --dangerously-bypass-approvals-and-sandbox is blocked" >&2
      exit 2
      ;;
    -*)
      # Unknown flag, skip
      shift
      ;;
    *)
      # Positional argument = prompt
      PROMPT="$1"
      shift
      ;;
  esac
done

# ── Validation ─────────────────────────────────────────────────────────────

if [[ -z "$SCENARIO" ]]; then
  echo "[fake-codex] ERROR: FAKE_CODEX_SCENARIO environment variable is not set." >&2
  echo "[fake-codex] Available scenarios: session-start, session-resume, debate-round," >&2
  echo "  debate-consensus, debate-multi-round, evaluate, ask-readonly, ask-write," >&2
  echo "  error-auth, error-timeout, error-empty, error-crash" >&2
  exit 1
fi

# ── Delay ──────────────────────────────────────────────────────────────────

if [[ "$DELAY" != "0" ]]; then
  sleep "$DELAY"
fi

# ── Helper: write output and optionally emit JSONL ────────────────────────

write_output() {
  local content="$1"
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$content" > "$OUTPUT_FILE"
  fi
}

emit_jsonl() {
  local fixture_file="$1"
  if [[ $JSON_MODE -eq 1 ]]; then
    if [[ -f "$FIXTURES_DIR/$fixture_file" ]]; then
      # Substitute session ID placeholder
      sed "s/{{SESSION_ID}}/$SESSION_ID/g" "$FIXTURES_DIR/$fixture_file"
    else
      echo "[fake-codex] WARNING: Fixture file not found: $FIXTURES_DIR/$fixture_file" >&2
    fi
  fi
}

# ── Scenario Dispatch ─────────────────────────────────────────────────────

case "$SCENARIO" in

  session-start)
    emit_jsonl "session-start.jsonl"
    write_output "Session started successfully. Codex is ready to assist with your project."
    exit 0
    ;;

  session-resume)
    # Resume doesn't emit JSONL (per codex-delegator spec: no --json on resume)
    write_output "Session resumed. Continuing from previous context."
    exit 0
    ;;

  debate-round)
    emit_jsonl "debate-round.jsonl"
    # Write structured debate position to output
    if [[ $HAS_OUTPUT_SCHEMA -eq 1 ]] || [[ -n "$OUTPUT_FILE" ]]; then
      write_output '{
  "position": "Classes provide better encapsulation and state management for complex modules with multiple internal dependencies.",
  "confidence": 0.75,
  "key_arguments": [
    "Encapsulation hides internal state mutations from consumers",
    "Inheritance enables code reuse for similar module variants",
    "IDE tooling provides better autocomplete for class methods"
  ],
  "agrees_with_opponent": false,
  "counterpoints": [
    "Functions can achieve encapsulation through closures",
    "Composition is often preferred over inheritance in modern patterns"
  ]
}'
    fi
    exit 0
    ;;

  debate-consensus)
    emit_jsonl "debate-consensus.jsonl"
    write_output '{
  "position": "A hybrid approach using functional core with class wrappers for stateful concerns provides the best balance.",
  "confidence": 0.90,
  "key_arguments": [
    "Pure functions for business logic ensure testability",
    "Class wrappers for I/O and state management provide clean interfaces",
    "This pattern aligns with hexagonal architecture principles"
  ],
  "agrees_with_opponent": true,
  "counterpoints": []
}'
    exit 0
    ;;

  debate-multi-round)
    emit_jsonl "debate-multi-round.jsonl"
    write_output '{
  "position": "After three rounds of discussion, the functional approach with selective class usage is optimal for this codebase.",
  "confidence": 0.85,
  "key_arguments": [
    "Current codebase is 80% functional — consistency matters",
    "Only 2 modules genuinely benefit from class encapsulation",
    "Team familiarity with functional patterns reduces onboarding cost"
  ],
  "agrees_with_opponent": true,
  "counterpoints": []
}'
    exit 0
    ;;

  evaluate)
    emit_jsonl "evaluate.jsonl"
    write_output '{
  "issues": [
    {
      "severity": "high",
      "file": "src/auth.ts",
      "line": 42,
      "description": "JWT secret is hardcoded — should use environment variable"
    },
    {
      "severity": "medium",
      "file": "src/api/routes.ts",
      "line": 105,
      "description": "Missing input validation on user-supplied query parameters"
    },
    {
      "severity": "low",
      "file": "src/utils/format.ts",
      "line": 18,
      "description": "Unused import: lodash.merge"
    }
  ],
  "confidence": 0.82,
  "summary": "Found 3 issues: 1 high severity (hardcoded secret), 1 medium (missing validation), 1 low (unused import). Recommend immediate fix for the JWT secret."
}'
    exit 0
    ;;

  ask-readonly)
    emit_jsonl "ask-readonly.jsonl"
    write_output "Based on the codebase analysis, the authentication module uses JWT with RS256 signing. The token lifecycle is: (1) issued on login via /api/auth/login, (2) validated per-request by middleware in src/middleware/auth.ts, (3) refreshed via /api/auth/refresh with a 7-day sliding window. The refresh token is stored in an httpOnly cookie."
    exit 0
    ;;

  ask-write)
    emit_jsonl "ask-write.jsonl"
    write_output "Applied the requested changes:
1. Added input validation middleware to src/api/routes.ts (lines 100-115)
2. Created src/validators/query-params.ts with Zod schemas
3. Updated 3 route handlers to use the new validation

Files modified: src/api/routes.ts, src/validators/query-params.ts (new)"
    exit 0
    ;;

  error-auth)
    echo "[codex] Error: Authentication required. Please run 'codex login' to authenticate." >&2
    exit 2
    ;;

  error-timeout)
    # Simulate timeout — sleep longer than typical bash timeout
    # In testing, use a short delay; real timeout is caught by bash tool
    sleep "${FAKE_CODEX_DELAY:-10}"
    exit 1
    ;;

  error-empty)
    # Simulate empty output — create empty file or no output
    if [[ -n "$OUTPUT_FILE" ]]; then
      : > "$OUTPUT_FILE"
    fi
    exit 0
    ;;

  error-crash)
    echo "[codex] Fatal: Unexpected internal error — model response malformed" >&2
    echo "[codex] Stack trace:" >&2
    echo "  at CodexEngine.execute (engine.js:142)" >&2
    echo "  at Session.run (session.js:88)" >&2
    exit 1
    ;;

  *)
    echo "[fake-codex] ERROR: Unknown scenario '$SCENARIO'" >&2
    echo "[fake-codex] Available: session-start, session-resume, debate-round," >&2
    echo "  debate-consensus, debate-multi-round, evaluate, ask-readonly, ask-write," >&2
    echo "  error-auth, error-timeout, error-empty, error-crash" >&2
    exit 1
    ;;
esac
