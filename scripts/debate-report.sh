#!/usr/bin/env bash
# debate-report.sh — Per-round debate report generator for codex-collab (v2.1.0)
#
# Collects and assembles per-round summaries with confidence scores during
# debate execution. Produces both structured JSON and formatted text output
# following the Final Report Format defined in commands/codex-debate.md.
#
# Data Flow:
#   1. collect_round_summary() — called after each round to capture per-round data
#   2. assemble_debate_report() — called after debate loop to compile all rounds
#   3. format_debate_report()   — renders the report as formatted text
#   4. save via save_report()   — persists to .codex-collab/reports/ (from status-summary.sh)
#
# Per-Round Data Model (per schemas/debate.json):
#   {
#     "round": N,
#     "codex": { "position", "confidence", "key_arguments", "agrees_with_opponent", "counterpoints" },
#     "claude": { "position", "confidence", "key_arguments", "agrees_with_opponent", "counterpoints" }
#   }
#
# Usage:
#   # Source for shell functions:
#   source scripts/debate-report.sh
#
#   # During debate loop — collect each round:
#   init_report_collector
#   collect_round_summary 1 "$codex_response_json" "$claude_response_json"
#   collect_round_summary 2 "$codex_response_json" "$claude_response_json"
#   ...
#
#   # After debate loop — assemble and format:
#   report_json=$(assemble_debate_report "$topic" "$effective_max" "$default_rounds" "$max_additional")
#   formatted=$(format_debate_report "$report_json")
#   echo "$formatted"
#
#   # Or run directly:
#   ./scripts/debate-report.sh --rounds '<paired_rounds_json>' --topic '<topic>' \
#                               [--max-rounds 5] [--default-rounds 3] [--max-additional 2] \
#                               [--format text|json] [--save <project_root>]
#
# Requires: python3

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source config loader if not already loaded
if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
  if [[ -f "${SCRIPT_DIR}/load-config.sh" ]]; then
    # shellcheck source=load-config.sh
    source "${SCRIPT_DIR}/load-config.sh" 2>/dev/null || true
  fi
fi

# Source status-summary.sh for save_report() integration
if ! declare -f save_report &>/dev/null; then
  if [[ -f "${SCRIPT_DIR}/status-summary.sh" ]]; then
    # shellcheck source=status-summary.sh
    source "${SCRIPT_DIR}/status-summary.sh" 2>/dev/null || true
  fi
fi

# ===========================================================================
# ROUND COLLECTOR — accumulates per-round data during debate execution
# ===========================================================================

# Internal storage: temp file holding collected round JSON lines
_REPORT_COLLECTOR_FILE=""

# ---------------------------------------------------------------------------
# init_report_collector — Initialize a fresh round collector
#
# Must be called before collect_round_summary(). Creates a temp file
# to accumulate round data during the debate loop.
#
# Returns: 0 on success
# ---------------------------------------------------------------------------
init_report_collector() {
  _REPORT_COLLECTOR_FILE="$(mktemp "${TMPDIR:-/tmp}/codex-debate-rounds.XXXXXX")"
  # Write empty JSON array start marker
  echo "[]" > "$_REPORT_COLLECTOR_FILE"
  return 0
}

# ---------------------------------------------------------------------------
# collect_round_summary — Capture one round's data from both sides
#
# Called after each debate round completes. Extracts position, confidence,
# key_arguments, agrees_with_opponent, and counterpoints from both the
# Codex response and Claude response JSONs.
#
# Args:
#   round_number    — 1-based round index
#   codex_json      — Codex response JSON (per schemas/debate.json)
#   claude_json     — Claude response JSON (per schemas/debate.json)
#
# Returns: 0 on success, appends round to collector
# ---------------------------------------------------------------------------
collect_round_summary() {
  local round_number="${1:?Usage: collect_round_summary <round> <codex_json> <claude_json>}"
  local codex_json="${2:-'{}'}"
  local claude_json="${3:-'{}'}"

  if [[ -z "$_REPORT_COLLECTOR_FILE" || ! -f "$_REPORT_COLLECTOR_FILE" ]]; then
    echo "[codex-collab] WARNING: Report collector not initialized. Call init_report_collector first." >&2
    return 1
  fi

  if ! command -v python3 &>/dev/null; then
    echo "[codex-collab] WARNING: python3 required for report collection" >&2
    return 1
  fi

  # Append round data to collector via python3
  python3 -c "
import json, sys

round_num = int(sys.argv[1])
collector_file = sys.argv[2]

# Parse Codex response
try:
    codex = json.loads(sys.argv[3]) if sys.argv[3] != '{}' else {}
except (json.JSONDecodeError, TypeError):
    codex = {}

# Parse Claude response
try:
    claude = json.loads(sys.argv[4]) if sys.argv[4] != '{}' else {}
except (json.JSONDecodeError, TypeError):
    claude = {}

# Extract structured fields per schemas/debate.json
def extract_side(data):
    if not isinstance(data, dict):
        return {'position': '', 'confidence': 0, 'key_arguments': [], 'agrees_with_opponent': False, 'counterpoints': []}
    return {
        'position': str(data.get('position', ''))[:500],
        'confidence': float(data.get('confidence', 0)),
        'key_arguments': list(data.get('key_arguments', [])),
        'agrees_with_opponent': bool(data.get('agrees_with_opponent', False)),
        'counterpoints': list(data.get('counterpoints', [])),
    }

round_data = {
    'round': round_num,
    'codex': extract_side(codex),
    'claude': extract_side(claude),
}

# Read existing rounds, append new, write back
try:
    with open(collector_file, 'r') as f:
        rounds = json.load(f)
except (json.JSONDecodeError, IOError):
    rounds = []

if not isinstance(rounds, list):
    rounds = []

rounds.append(round_data)

with open(collector_file, 'w') as f:
    json.dump(rounds, f, ensure_ascii=False)
" "$round_number" "$_REPORT_COLLECTOR_FILE" "$codex_json" "$claude_json" 2>/dev/null

  return $?
}

# ---------------------------------------------------------------------------
# get_collected_rounds — Return collected rounds as JSON array
#
# Returns: JSON array of all collected round data
# ---------------------------------------------------------------------------
get_collected_rounds() {
  if [[ -z "$_REPORT_COLLECTOR_FILE" || ! -f "$_REPORT_COLLECTOR_FILE" ]]; then
    echo "[]"
    return 0
  fi
  cat "$_REPORT_COLLECTOR_FILE"
}

# ---------------------------------------------------------------------------
# cleanup_report_collector — Remove temp collector file
# ---------------------------------------------------------------------------
cleanup_report_collector() {
  if [[ -n "$_REPORT_COLLECTOR_FILE" && -f "$_REPORT_COLLECTOR_FILE" ]]; then
    rm -f "$_REPORT_COLLECTOR_FILE" 2>/dev/null || true
  fi
  _REPORT_COLLECTOR_FILE=""
}

# ===========================================================================
# REPORT ASSEMBLY — compiles collected rounds into a structured report
# ===========================================================================

# ---------------------------------------------------------------------------
# assemble_debate_report — Compile all rounds into a full debate report JSON
#
# Takes the collected rounds (or a provided JSON array) and assembles a
# complete debate report with:
#   - Per-round summaries with confidence scores
#   - Aggregate statistics (avg confidence, trend, convergence)
#   - Consensus detection result
#   - Round cap metadata
#
# Args:
#   topic           — Debate topic string
#   effective_max   — Effective max rounds (default_rounds + max_additional)
#   default_rounds  — Base round count from config (optional, default: 3)
#   max_additional  — Additional rounds allowed (optional, default: 2)
#   rounds_json     — JSON array of rounds (optional; uses collector if empty)
#
# Returns: Full report JSON to stdout
# ---------------------------------------------------------------------------
assemble_debate_report() {
  local topic="${1:-}"
  local effective_max="${2:-5}"
  local default_rounds="${3:-3}"
  local max_additional="${4:-2}"
  local rounds_json="${5:-}"

  # If no rounds_json provided, use collected rounds
  if [[ -z "$rounds_json" ]]; then
    rounds_json="$(get_collected_rounds)"
  fi

  if ! command -v python3 &>/dev/null; then
    echo '{"error":"python3 required"}'
    return 1
  fi

  python3 -c "
import json, sys
from datetime import datetime

topic = sys.argv[1]
effective_max = int(sys.argv[2])
default_rounds = int(sys.argv[3])
max_additional = int(sys.argv[4])

try:
    rounds = json.loads(sys.argv[5])
except (json.JSONDecodeError, TypeError):
    rounds = []

if not isinstance(rounds, list):
    rounds = []

total_rounds = len(rounds)

# --- Per-round summaries with confidence scores ---
round_summaries = []
codex_confidences = []
claude_confidences = []
consensus_round = None

for r in rounds:
    if not isinstance(r, dict):
        continue

    rn = r.get('round', len(round_summaries) + 1)
    codex = r.get('codex', {})
    claude = r.get('claude', {})

    codex_conf = float(codex.get('confidence', 0))
    claude_conf = float(claude.get('confidence', 0))
    codex_confidences.append(codex_conf)
    claude_confidences.append(claude_conf)

    codex_agrees = codex.get('agrees_with_opponent', False)
    claude_agrees = claude.get('agrees_with_opponent', False)

    # Detect consensus round
    if (codex_agrees or claude_agrees) and consensus_round is None:
        consensus_round = rn

    # Truncate positions for summary table
    codex_pos = str(codex.get('position', ''))[:120]
    claude_pos = str(claude.get('position', ''))[:120]

    summary = {
        'round': rn,
        'codex_position': codex_pos,
        'codex_confidence': codex_conf,
        'codex_key_arguments': codex.get('key_arguments', []),
        'codex_agrees': codex_agrees,
        'claude_position': claude_pos,
        'claude_confidence': claude_conf,
        'claude_key_arguments': claude.get('key_arguments', []),
        'claude_agrees': claude_agrees,
        'consensus': 'Yes' if (codex_agrees or claude_agrees) else 'No',
    }
    round_summaries.append(summary)

# --- Aggregate statistics ---
consensus_reached = consensus_round is not None

# Average confidence per side
avg_codex_conf = round(sum(codex_confidences) / len(codex_confidences), 3) if codex_confidences else 0
avg_claude_conf = round(sum(claude_confidences) / len(claude_confidences), 3) if claude_confidences else 0

# Confidence trend: compare first vs last round
def compute_trend(confs):
    if len(confs) < 2:
        return 'stable'
    delta = confs[-1] - confs[0]
    if delta > 0.05:
        return 'increasing'
    elif delta < -0.05:
        return 'decreasing'
    return 'stable'

codex_trend = compute_trend(codex_confidences)
claude_trend = compute_trend(claude_confidences)

# Overall convergence: are the two sides getting closer?
convergence = 'stable'
if len(codex_confidences) >= 2 and len(claude_confidences) >= 2:
    early_gap = abs(codex_confidences[0] - claude_confidences[0])
    late_gap = abs(codex_confidences[-1] - claude_confidences[-1])
    if late_gap < early_gap - 0.05:
        convergence = 'converging'
    elif late_gap > early_gap + 0.05:
        convergence = 'diverging'

# Final confidence (from last round)
final_codex_conf = codex_confidences[-1] if codex_confidences else 0
final_claude_conf = claude_confidences[-1] if claude_confidences else 0
final_confidence = round(max(final_codex_conf, final_claude_conf), 3)

# Final positions and arguments
last_round = rounds[-1] if rounds else {}
codex_final = last_round.get('codex', {})
claude_final = last_round.get('claude', {})

# --- Build report ---
report = {
    'report_version': '2.1.0',
    'generated_at': datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'),
    'topic': topic,

    # Round metadata
    'total_rounds': total_rounds,
    'max_rounds': effective_max,
    'default_rounds': default_rounds,
    'max_additional_rounds': max_additional,

    # Consensus result
    'consensus_reached': consensus_reached,
    'consensus_round': consensus_round,
    'consensus': 'Yes' if consensus_reached else 'No',

    # Per-round summaries (the core deliverable)
    'round_summaries': round_summaries,

    # Confidence statistics
    'confidence': {
        'final': final_confidence,
        'codex_final': final_codex_conf,
        'claude_final': final_claude_conf,
        'codex_average': avg_codex_conf,
        'claude_average': avg_claude_conf,
        'codex_trend': codex_trend,
        'claude_trend': claude_trend,
        'convergence': convergence,
        'codex_per_round': codex_confidences,
        'claude_per_round': claude_confidences,
    },

    # Final positions
    'codex_final_position': codex_final.get('position', ''),
    'claude_final_position': claude_final.get('position', ''),
    'codex_final_arguments': codex_final.get('key_arguments', []),
    'claude_final_arguments': claude_final.get('key_arguments', []),
}

print(json.dumps(report, ensure_ascii=False))
" "$topic" "$effective_max" "$default_rounds" "$max_additional" "$rounds_json" 2>/dev/null
}

# ===========================================================================
# REPORT FORMATTING — renders structured report as human-readable text
# ===========================================================================

# ---------------------------------------------------------------------------
# format_debate_report — Render assembled report JSON as formatted text
#
# Produces the Final Report Format from commands/codex-debate.md:
#   - Topic header
#   - Per-round summary table with confidence scores
#   - Final consensus / both positions
#   - Key arguments
#   - Confidence statistics
#   - User recommendation
#
# Args:
#   report_json — Full report JSON from assemble_debate_report()
#   verbosity   — "minimal" | "normal" | "verbose" (default: normal)
#
# Returns: Formatted text to stdout
# ---------------------------------------------------------------------------
format_debate_report() {
  local report_json="${1:-'{}'}"
  local verbosity="${2:-normal}"

  if ! command -v python3 &>/dev/null; then
    echo "[codex-collab] Report formatting requires python3"
    return 1
  fi

  python3 -c "
import json, sys

try:
    report = json.loads(sys.argv[1])
except (json.JSONDecodeError, TypeError):
    print('[codex-collab] ERROR: Invalid report JSON')
    sys.exit(1)

verbosity = sys.argv[2] if len(sys.argv) > 2 else 'normal'

topic = report.get('topic', 'Unknown')
total_rounds = report.get('total_rounds', 0)
max_rounds = report.get('max_rounds', 0)
default_rounds = report.get('default_rounds', 0)
max_additional = report.get('max_additional_rounds', 0)
consensus_reached = report.get('consensus_reached', False)
consensus_round = report.get('consensus_round')
round_summaries = report.get('round_summaries', [])
confidence = report.get('confidence', {})

lines = []

# === Header ===
lines.append('## Debate Report')
lines.append('')

# === Topic ===
lines.append('### Topic')
lines.append(topic)
lines.append('')

# === Round Summary Table ===
lines.append('### Round Summary')
lines.append('')
lines.append('| Round | Codex Position | Codex Conf | Claude Position | Claude Conf | Consensus |')
lines.append('|:-----:|:---------------|:----------:|:----------------|:-----------:|:---------:|')

for rs in round_summaries:
    rn = rs.get('round', '?')
    codex_pos = rs.get('codex_position', '')[:60]
    codex_conf = rs.get('codex_confidence', 0)
    claude_pos = rs.get('claude_position', '')[:60]
    claude_conf = rs.get('claude_confidence', 0)
    consensus_col = rs.get('consensus', 'No')
    if consensus_col == 'Yes':
        consensus_col = 'Yes \u2713'

    # Format confidence as percentage
    codex_pct = f'{codex_conf:.0%}'
    claude_pct = f'{claude_conf:.0%}'

    lines.append(f'| {rn} | {codex_pos} | {codex_pct} | {claude_pos} | {claude_pct} | {consensus_col} |')

lines.append('')

# === Consensus / Final Positions ===
if consensus_reached:
    lines.append('### Consensus Reached')
    lines.append(f'Consensus at round {consensus_round} of {total_rounds} (max: {max_rounds})')
else:
    lines.append('### No Consensus (Both Positions)')
    lines.append(f'Debate completed after {total_rounds} round(s) (max: {max_rounds})')

lines.append('')

codex_final_pos = report.get('codex_final_position', '')
claude_final_pos = report.get('claude_final_position', '')

if codex_final_pos:
    lines.append(f'**Codex (GPT-5.4):** {codex_final_pos}')
    lines.append('')
if claude_final_pos:
    lines.append(f'**Claude:** {claude_final_pos}')
    lines.append('')

# === Key Arguments ===
codex_args = report.get('codex_final_arguments', [])
claude_args = report.get('claude_final_arguments', [])

if codex_args or claude_args:
    lines.append('### Key Arguments')
    lines.append('')

if codex_args:
    lines.append('_From Codex (GPT-5.4):_')
    for arg in codex_args:
        lines.append(f'  - {arg}')
    lines.append('')

if claude_args:
    lines.append('_From Claude:_')
    for arg in claude_args:
        lines.append(f'  - {arg}')
    lines.append('')

# === Confidence Statistics (normal + verbose) ===
if verbosity in ('normal', 'verbose'):
    lines.append('### Confidence Statistics')
    lines.append('')
    lines.append(f'| Metric | Codex | Claude |')
    lines.append(f'|:-------|:-----:|:------:|')
    lines.append(f'| Final confidence | {confidence.get(\"codex_final\", 0):.0%} | {confidence.get(\"claude_final\", 0):.0%} |')
    lines.append(f'| Average confidence | {confidence.get(\"codex_average\", 0):.0%} | {confidence.get(\"claude_average\", 0):.0%} |')
    lines.append(f'| Trend | {confidence.get(\"codex_trend\", \"stable\")} | {confidence.get(\"claude_trend\", \"stable\")} |')
    lines.append(f'| Convergence | {confidence.get(\"convergence\", \"stable\")} ||')
    lines.append('')

# === Per-Round Confidence Path (verbose only) ===
if verbosity == 'verbose':
    codex_per_round = confidence.get('codex_per_round', [])
    claude_per_round = confidence.get('claude_per_round', [])
    if codex_per_round or claude_per_round:
        lines.append('### Confidence Path')
        lines.append('')
        max_len = max(len(codex_per_round), len(claude_per_round))
        for i in range(max_len):
            cc = f'{codex_per_round[i]:.0%}' if i < len(codex_per_round) else 'N/A'
            cl = f'{claude_per_round[i]:.0%}' if i < len(claude_per_round) else 'N/A'
            lines.append(f'  Round {i+1}: Codex {cc} | Claude {cl}')
        lines.append('')

# === Round Cap Metadata (verbose only) ===
if verbosity == 'verbose':
    lines.append('### Round Configuration')
    lines.append(f'  default_rounds: {default_rounds}')
    lines.append(f'  max_additional_rounds: {max_additional} (hard cap: 2)')
    lines.append(f'  effective_max: {max_rounds}')
    lines.append(f'  rounds_used: {total_rounds}')
    lines.append('')

# === User Recommendation ===
lines.append('### Recommendation')
if consensus_reached:
    lines.append('Consensus was reached. Review the agreed position and supporting arguments above.')
    lines.append('Use the consensus result to guide your implementation.')
else:
    lines.append('No consensus was reached. Review both positions and key arguments above.')
    lines.append('Use your judgment to decide the best approach for your project.')
lines.append('')

print('\n'.join(lines))
" "$report_json" "$verbosity" 2>/dev/null
}

# ---------------------------------------------------------------------------
# generate_and_save_debate_report — Full pipeline: assemble + format + save
#
# Convenience function that combines assembly, formatting, and saving.
# Called as the final step of debate execution in the workflow orchestrator.
#
# Args:
#   topic          — Debate topic
#   effective_max  — Effective max rounds
#   default_rounds — Base round count
#   max_additional — Additional rounds cap
#   rounds_json    — JSON array of rounds (optional; uses collector if empty)
#   project_root   — Project root for saving (optional)
#   verbosity      — Report verbosity: minimal | normal | verbose (optional)
#
# Returns: Formatted report text to stdout; saves to .codex-collab/reports/
# ---------------------------------------------------------------------------
generate_and_save_debate_report() {
  local topic="${1:-}"
  local effective_max="${2:-5}"
  local default_rounds="${3:-3}"
  local max_additional="${4:-2}"
  local rounds_json="${5:-}"
  local project_root="${6:-${CODEX_PROJECT_ROOT:-$(pwd)}}"
  local verbosity="${7:-normal}"

  # Step 1: Assemble structured report
  local report_json
  report_json="$(assemble_debate_report "$topic" "$effective_max" "$default_rounds" "$max_additional" "$rounds_json")"

  if [[ -z "$report_json" || "$report_json" == "null" ]]; then
    echo "[codex-collab] WARNING: Failed to assemble debate report" >&2
    return 1
  fi

  # Step 2: Format as text
  local formatted
  formatted="$(format_debate_report "$report_json" "$verbosity")"

  # Step 3: Save to reports directory (if save_report function is available)
  if declare -f save_report &>/dev/null; then
    local saved_path
    saved_path="$(save_report "codex-debate" "$formatted" "$project_root" "$report_json" 2>/dev/null)" || true
    if [[ -n "${saved_path:-}" ]]; then
      echo "[codex-collab] Debate report saved: $saved_path" >&2
    fi
  fi

  # Step 4: Output formatted report
  echo "$formatted"

  return 0
}

# ---------------------------------------------------------------------------
# get_round_confidence — Quick accessor: get confidence for a specific round
#
# Args:
#   round_number — 1-based round index
#   side         — "codex" or "claude"
#   rounds_json  — JSON array of rounds (optional; uses collector if empty)
#
# Returns: confidence value (0.0-1.0) or "0" if not found
# ---------------------------------------------------------------------------
get_round_confidence() {
  local round_number="${1:?Usage: get_round_confidence <round> <side> [rounds_json]}"
  local side="${2:?Usage: get_round_confidence <round> <side> [rounds_json]}"
  local rounds_json="${3:-}"

  if [[ -z "$rounds_json" ]]; then
    rounds_json="$(get_collected_rounds)"
  fi

  python3 -c "
import json, sys
try:
    rounds = json.loads(sys.argv[1])
    rn = int(sys.argv[2])
    side = sys.argv[3].lower()
    for r in rounds:
        if r.get('round') == rn:
            print(r.get(side, {}).get('confidence', 0))
            sys.exit(0)
    print(0)
except Exception:
    print(0)
" "$rounds_json" "$round_number" "$side" 2>/dev/null
}

# ---------------------------------------------------------------------------
# get_confidence_summary — Quick accessor: confidence stats for all rounds
#
# Args:
#   rounds_json — JSON array of rounds (optional; uses collector if empty)
#
# Returns: JSON object with codex/claude avg, final, trend
# ---------------------------------------------------------------------------
get_confidence_summary() {
  local rounds_json="${1:-}"

  if [[ -z "$rounds_json" ]]; then
    rounds_json="$(get_collected_rounds)"
  fi

  python3 -c "
import json, sys
try:
    rounds = json.loads(sys.argv[1])
    codex_confs = []
    claude_confs = []
    for r in rounds:
        if not isinstance(r, dict):
            continue
        cc = r.get('codex', {}).get('confidence', 0)
        cl = r.get('claude', {}).get('confidence', 0)
        if cc: codex_confs.append(float(cc))
        if cl: claude_confs.append(float(cl))

    def trend(confs):
        if len(confs) < 2: return 'stable'
        d = confs[-1] - confs[0]
        if d > 0.05: return 'increasing'
        elif d < -0.05: return 'decreasing'
        return 'stable'

    result = {
        'codex_average': round(sum(codex_confs)/len(codex_confs), 3) if codex_confs else 0,
        'claude_average': round(sum(claude_confs)/len(claude_confs), 3) if claude_confs else 0,
        'codex_final': codex_confs[-1] if codex_confs else 0,
        'claude_final': claude_confs[-1] if claude_confs else 0,
        'codex_trend': trend(codex_confs),
        'claude_trend': trend(claude_confs),
        'total_rounds': len(rounds),
    }
    print(json.dumps(result))
except Exception:
    print('{}')
" "$rounds_json" 2>/dev/null
}

# ===========================================================================
# CLI MODE — run directly for testing or pipeline integration
# ===========================================================================
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  CLI_ROUNDS=""
  CLI_TOPIC=""
  CLI_MAX_ROUNDS="5"
  CLI_DEFAULT_ROUNDS="3"
  CLI_MAX_ADDITIONAL="2"
  CLI_FORMAT="text"
  CLI_VERBOSITY="normal"
  CLI_SAVE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rounds)          CLI_ROUNDS="$2"; shift 2 ;;
      --topic)           CLI_TOPIC="$2"; shift 2 ;;
      --max-rounds)      CLI_MAX_ROUNDS="$2"; shift 2 ;;
      --default-rounds)  CLI_DEFAULT_ROUNDS="$2"; shift 2 ;;
      --max-additional)  CLI_MAX_ADDITIONAL="$2"; shift 2 ;;
      --format)          CLI_FORMAT="$2"; shift 2 ;;
      --verbosity)       CLI_VERBOSITY="$2"; shift 2 ;;
      --save)            CLI_SAVE="${2:-$(pwd)}"; shift 2 ;;
      --confidence-only)
        # Quick mode: just output confidence summary
        if [[ -n "${2:-}" ]]; then
          get_confidence_summary "$2"
          shift 2
        else
          echo '{"error":"--confidence-only requires rounds JSON argument"}' >&2
          exit 1
        fi
        exit 0
        ;;
      --help|-h)
        echo "Usage: debate-report.sh --rounds '<json>' --topic '<topic>' [options]"
        echo ""
        echo "Generates a debate report with per-round summaries and confidence scores."
        echo ""
        echo "Required:"
        echo "  --rounds <json>        JSON array of paired round objects"
        echo "  --topic <text>         Debate topic"
        echo ""
        echo "Options:"
        echo "  --max-rounds <N>       Effective max rounds (default: 5)"
        echo "  --default-rounds <N>   Base round count from config (default: 3)"
        echo "  --max-additional <N>   Additional rounds cap (default: 2)"
        echo "  --format <fmt>         Output format: 'text' (default) or 'json'"
        echo "  --verbosity <level>    minimal | normal | verbose (default: normal)"
        echo "  --save <dir>           Save report to <dir>/.codex-collab/reports/"
        echo "  --confidence-only <j>  Output only confidence summary for given rounds JSON"
        echo ""
        echo "Example:"
        echo "  debate-report.sh --rounds '[{\"round\":1,\"codex\":{\"position\":\"Use classes\",\"confidence\":0.8,\"key_arguments\":[\"encapsulation\"],\"agrees_with_opponent\":false},\"claude\":{\"position\":\"Use functions\",\"confidence\":0.7,\"key_arguments\":[\"composability\"],\"agrees_with_opponent\":false}}]' --topic 'classes vs functions'"
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$CLI_ROUNDS" ]]; then
    echo "Error: --rounds is required" >&2
    echo "Usage: debate-report.sh --rounds '<json>' --topic '<topic>'" >&2
    exit 1
  fi

  if [[ "$CLI_FORMAT" == "json" ]]; then
    # JSON output: just assemble, no formatting
    assemble_debate_report "$CLI_TOPIC" "$CLI_MAX_ROUNDS" "$CLI_DEFAULT_ROUNDS" "$CLI_MAX_ADDITIONAL" "$CLI_ROUNDS"
  else
    # Text output: assemble + format (+ optional save)
    if [[ -n "$CLI_SAVE" ]]; then
      CODEX_PROJECT_ROOT="$CLI_SAVE"
      generate_and_save_debate_report "$CLI_TOPIC" "$CLI_MAX_ROUNDS" "$CLI_DEFAULT_ROUNDS" "$CLI_MAX_ADDITIONAL" "$CLI_ROUNDS" "$CLI_SAVE" "$CLI_VERBOSITY"
    else
      report_json="$(assemble_debate_report "$CLI_TOPIC" "$CLI_MAX_ROUNDS" "$CLI_DEFAULT_ROUNDS" "$CLI_MAX_ADDITIONAL" "$CLI_ROUNDS")"
      format_debate_report "$report_json" "$CLI_VERBOSITY"
    fi
  fi
fi
