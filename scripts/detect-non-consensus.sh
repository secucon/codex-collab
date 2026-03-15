#!/usr/bin/env bash
# detect-non-consensus.sh — Non-consensus detection for codex-collab debates (v2.1.0)
#
# Analyzes debate round data to determine if Claude and Codex proposals diverge,
# returning a structured non-consensus state with both proposals when they do.
#
# Detection Logic:
#   1. Parse all rounds for agrees_with_opponent flags
#   2. If ANY participant agrees → consensus (not handled here)
#   3. If NO participant agrees after all rounds → non-consensus detected
#   4. Return structured JSON with both final proposals, divergence metrics
#
# Usage:
#   # Source for shell functions:
#   source scripts/detect-non-consensus.sh
#   result=$(detect_non_consensus "$rounds_json" "$topic")
#
#   # Or run directly:
#   ./scripts/detect-non-consensus.sh --rounds '<json_array>' [--topic '<topic>']
#   ./scripts/detect-non-consensus.sh --jsonl '<file.jsonl>' [--topic '<topic>']
#
# Output JSON fields:
#   consensus_state: "consensus" | "non-consensus"
#   consensus_reached: boolean
#   divergence_score: 0.0-1.0 (how far apart the final positions are)
#   total_rounds: number
#   codex_proposal: { position, confidence, key_arguments }
#   claude_proposal: { position, confidence, key_arguments }
#   convergence_trend: "converging" | "diverging" | "stable"
#   summary: human-readable summary of the non-consensus state
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

# ===========================================================================
# CORE DETECTION LOGIC
# ===========================================================================

# ---------------------------------------------------------------------------
# detect_non_consensus — Main detection function
#
# Analyzes debate rounds to determine if proposals diverge (non-consensus).
# Returns structured JSON with both proposals and divergence metrics.
#
# Args:
#   rounds_json — JSON array of round objects. Each round should have:
#     {
#       "round": N,
#       "codex": { "position": "...", "confidence": 0.8, "key_arguments": [...], "agrees_with_opponent": false },
#       "claude": { "position": "...", "confidence": 0.7, "key_arguments": [...], "agrees_with_opponent": false }
#     }
#     OR flat per-turn format:
#     { "position": "...", "confidence": 0.8, "agrees_with_opponent": false, "side": "codex" }
#   topic — Debate topic string (optional)
#
# Returns: JSON with consensus_state, both proposals, divergence metrics
# ---------------------------------------------------------------------------
detect_non_consensus() {
  local rounds_json="${1:-'[]'}"
  local topic="${2:-}"

  if ! command -v python3 &>/dev/null; then
    echo '{"error":"python3 required","consensus_state":"unknown"}'
    return 1
  fi

  python3 -c "
import json, sys

def analyze_rounds(rounds_raw, topic):
    \"\"\"Analyze debate rounds and detect non-consensus.\"\"\"

    try:
        rounds = json.loads(rounds_raw) if isinstance(rounds_raw, str) else rounds_raw
    except (json.JSONDecodeError, TypeError):
        return {
            'error': 'Invalid rounds JSON',
            'consensus_state': 'unknown',
            'consensus_reached': False,
        }

    if not isinstance(rounds, list) or len(rounds) == 0:
        return {
            'consensus_state': 'unknown',
            'consensus_reached': False,
            'total_rounds': 0,
            'summary': 'No debate rounds to analyze',
        }

    # --- Normalize rounds into paired format ---
    paired_rounds = []
    codex_turns = []
    claude_turns = []

    for r in rounds:
        if not isinstance(r, dict):
            continue

        # Format 1: Paired { round: N, codex: {...}, claude: {...} }
        if 'codex' in r and 'claude' in r:
            paired_rounds.append({
                'round': r.get('round', len(paired_rounds) + 1),
                'codex': r['codex'],
                'claude': r['claude'],
            })
        # Format 2: Flat per-turn { position: ..., side: 'codex'|'claude' }
        elif 'side' in r or 'role' in r:
            side = r.get('side', r.get('role', '')).lower()
            if side in ('codex', 'gpt', 'gpt-5.4'):
                codex_turns.append(r)
            elif side in ('claude', 'claude-sonnet'):
                claude_turns.append(r)
        # Format 3: JSONL message.delta with content (extract position JSON)
        elif r.get('type') == 'message.delta' and 'content' in r:
            try:
                content = json.loads(r['content'])
                # Assign alternating: odd = codex, even = claude
                if len(codex_turns) <= len(claude_turns):
                    codex_turns.append(content)
                else:
                    claude_turns.append(content)
            except (json.JSONDecodeError, TypeError):
                pass

    # Build paired rounds from flat turns
    if not paired_rounds and (codex_turns or claude_turns):
        max_len = max(len(codex_turns), len(claude_turns))
        for i in range(max_len):
            codex = codex_turns[i] if i < len(codex_turns) else {}
            claude = claude_turns[i] if i < len(claude_turns) else {}
            paired_rounds.append({
                'round': i + 1,
                'codex': codex,
                'claude': claude,
            })

    if not paired_rounds:
        return {
            'consensus_state': 'unknown',
            'consensus_reached': False,
            'total_rounds': 0,
            'summary': 'Could not parse debate rounds',
        }

    # --- Check for consensus in ANY round ---
    consensus_round = None
    for pr in paired_rounds:
        codex_agrees = pr.get('codex', {}).get('agrees_with_opponent', False)
        claude_agrees = pr.get('claude', {}).get('agrees_with_opponent', False)
        if codex_agrees or claude_agrees:
            consensus_round = pr['round']
            break

    if consensus_round is not None:
        # Consensus was reached — return consensus state
        last = paired_rounds[-1]
        return {
            'consensus_state': 'consensus',
            'consensus_reached': True,
            'consensus_round': consensus_round,
            'total_rounds': len(paired_rounds),
            'topic': topic,
            'summary': f'Consensus reached at round {consensus_round} of {len(paired_rounds)}',
        }

    # --- Non-consensus detected: extract both final proposals ---
    last_round = paired_rounds[-1]
    codex_final = last_round.get('codex', {})
    claude_final = last_round.get('claude', {})

    codex_proposal = {
        'position': codex_final.get('position', ''),
        'confidence': codex_final.get('confidence', 0),
        'key_arguments': codex_final.get('key_arguments', []),
    }

    claude_proposal = {
        'position': claude_final.get('position', ''),
        'confidence': claude_final.get('confidence', 0),
        'key_arguments': claude_final.get('key_arguments', []),
    }

    # --- Calculate divergence score ---
    # Divergence is based on:
    #   1. Both participants' confidence remaining high (neither yielding)
    #   2. Lack of convergence in confidence trends across rounds
    #   3. Number of unique counterpoints (more = more divergent)

    codex_confidences = []
    claude_confidences = []
    for pr in paired_rounds:
        cc = pr.get('codex', {}).get('confidence', 0)
        cl = pr.get('claude', {}).get('confidence', 0)
        if cc: codex_confidences.append(cc)
        if cl: claude_confidences.append(cl)

    # Base divergence: average of both final confidences (both staying high = divergent)
    codex_conf = codex_final.get('confidence', 0.5)
    claude_conf = claude_final.get('confidence', 0.5)
    base_divergence = (codex_conf + claude_conf) / 2.0

    # Trend adjustment: if confidences are converging (getting closer), reduce divergence
    convergence_trend = 'stable'
    if len(codex_confidences) >= 2 and len(claude_confidences) >= 2:
        early_gap = abs(codex_confidences[0] - claude_confidences[0])
        late_gap = abs(codex_confidences[-1] - claude_confidences[-1])
        if late_gap < early_gap - 0.05:
            convergence_trend = 'converging'
            base_divergence *= 0.85  # reduce divergence for converging debates
        elif late_gap > early_gap + 0.05:
            convergence_trend = 'diverging'
            base_divergence = min(1.0, base_divergence * 1.15)

    # Clamp divergence score to [0.0, 1.0]
    divergence_score = max(0.0, min(1.0, round(base_divergence, 2)))

    # --- Build per-round position summary ---
    round_positions = []
    for pr in paired_rounds:
        rp = {
            'round': pr['round'],
            'codex_position': pr.get('codex', {}).get('position', ''),
            'codex_confidence': pr.get('codex', {}).get('confidence', 0),
            'claude_position': pr.get('claude', {}).get('position', ''),
            'claude_confidence': pr.get('claude', {}).get('confidence', 0),
        }
        round_positions.append(rp)

    # --- Construct summary ---
    summary_parts = [
        f'No consensus after {len(paired_rounds)} round(s).',
        f'Codex maintains: \"{codex_proposal[\"position\"][:80]}\"' if codex_proposal['position'] else '',
        f'Claude maintains: \"{claude_proposal[\"position\"][:80]}\"' if claude_proposal['position'] else '',
        f'Divergence: {divergence_score} ({convergence_trend})',
    ]
    summary = ' '.join(p for p in summary_parts if p)

    return {
        'consensus_state': 'non-consensus',
        'consensus_reached': False,
        'total_rounds': len(paired_rounds),
        'topic': topic,
        'divergence_score': divergence_score,
        'convergence_trend': convergence_trend,
        'codex_proposal': codex_proposal,
        'claude_proposal': claude_proposal,
        'round_positions': round_positions,
        'summary': summary,
    }


# --- Main ---
rounds_raw = sys.argv[1] if len(sys.argv) > 1 else '[]'
topic = sys.argv[2] if len(sys.argv) > 2 else ''

result = analyze_rounds(rounds_raw, topic)
print(json.dumps(result, ensure_ascii=False))
" "$rounds_json" "$topic" 2>/dev/null
}

# ---------------------------------------------------------------------------
# detect_non_consensus_from_jsonl — Parse JSONL file and detect non-consensus
#
# Reads a JSONL file (as produced by fake-codex.sh or codex CLI), extracts
# debate round data, and runs non-consensus detection.
#
# Args:
#   jsonl_file — Path to JSONL file with debate round events
#   topic      — Debate topic string (optional)
#
# Returns: Same JSON as detect_non_consensus
# ---------------------------------------------------------------------------
detect_non_consensus_from_jsonl() {
  local jsonl_file="${1:?Usage: detect_non_consensus_from_jsonl <file> [topic]}"
  local topic="${2:-}"

  if [[ ! -f "$jsonl_file" ]]; then
    echo '{"error":"JSONL file not found","consensus_state":"unknown"}'
    return 1
  fi

  if ! command -v python3 &>/dev/null; then
    echo '{"error":"python3 required","consensus_state":"unknown"}'
    return 1
  fi

  local rounds_json
  rounds_json=$(python3 -c "
import json, sys

lines = []
with open(sys.argv[1], 'r') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            lines.append(obj)
        except json.JSONDecodeError:
            continue

# Extract position content from message.delta events or round objects
events = []
round_numbers = []
for obj in lines:
    if obj.get('type') == 'round' and 'number' in obj:
        round_numbers.append(obj['number'])
    elif obj.get('type') == 'message.delta' and 'content' in obj:
        try:
            content = json.loads(obj['content'])
            if 'position' in content:
                # Assign round number if available
                rn = round_numbers[-1] if round_numbers else len(events) + 1
                content['_round'] = rn
                events.append(content)
        except (json.JSONDecodeError, TypeError):
            pass
    elif 'position' in obj:
        events.append(obj)

# JSONL from Codex CLI contains only Codex responses.
# Build paired rounds with codex data; claude side is empty
# (orchestrator fills claude data separately at runtime).
# For detection purposes, if all events lack agrees_with_opponent=true,
# we treat this as non-consensus from the Codex side.
paired = []
for i, ev in enumerate(events):
    rn = ev.pop('_round', i + 1) if '_round' in ev else i + 1
    paired.append({
        'round': rn,
        'codex': ev,
        'claude': {},  # Claude data not in JSONL — filled by orchestrator
    })

print(json.dumps(paired, ensure_ascii=False))
" "$jsonl_file" 2>/dev/null)

  detect_non_consensus "$rounds_json" "$topic"
}

# ---------------------------------------------------------------------------
# is_non_consensus — Quick check: returns 0 if non-consensus, 1 if consensus
#
# Args:
#   rounds_json — JSON array of round objects
#
# Returns: exit code 0 = non-consensus, 1 = consensus or unknown
# ---------------------------------------------------------------------------
is_non_consensus() {
  local rounds_json="${1:-'[]'}"
  local result
  result=$(detect_non_consensus "$rounds_json" "" 2>/dev/null)

  local state
  state=$(python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    print(d.get('consensus_state', 'unknown'))
except Exception:
    print('unknown')
" "$result" 2>/dev/null)

  if [[ "$state" == "non-consensus" ]]; then
    return 0
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# format_non_consensus_display — Format non-consensus result for user display
#
# Args:
#   detection_result — JSON output from detect_non_consensus
#
# Returns: Formatted text output
# ---------------------------------------------------------------------------
format_non_consensus_display() {
  local detection_result="${1:?Usage: format_non_consensus_display <result_json>}"

  python3 -c "
import json, sys

try:
    data = json.loads(sys.argv[1])

    state = data.get('consensus_state', 'unknown')
    if state != 'non-consensus':
        print('[codex-collab] Consensus state: ' + state)
        sys.exit(0)

    topic = data.get('topic', 'Unknown')
    total_rounds = data.get('total_rounds', 0)
    divergence = data.get('divergence_score', 0)
    trend = data.get('convergence_trend', 'stable')
    codex = data.get('codex_proposal', {})
    claude = data.get('claude_proposal', {})

    print()
    print('┌─────────────────────────────────────────────────────────────┐')
    print('│  ⚖️  Non-Consensus Detected — Both Proposals Diverge')
    print('├─────────────────────────────────────────────────────────────┤')
    print(f'│  📌 Topic:       {topic[:50]}')
    print(f'│  🔄 Rounds:      {total_rounds}')
    print(f'│  📊 Divergence:  {divergence} ({trend})')
    print('└─────────────────────────────────────────────────────────────┘')
    print()

    # Codex proposal
    print('### 🤖 Codex Proposal (GPT-5.4)')
    print()
    print(f'**Position:** {codex.get(\"position\", \"N/A\")}')
    print(f'**Confidence:** {codex.get(\"confidence\", 0)}')
    args = codex.get('key_arguments', [])
    if args:
        print('**Key Arguments:**')
        for a in args:
            print(f'  - {a}')
    print()

    # Claude proposal
    print('### 🧠 Claude Proposal')
    print()
    print(f'**Position:** {claude.get(\"position\", \"N/A\")}')
    print(f'**Confidence:** {claude.get(\"confidence\", 0)}')
    args = claude.get('key_arguments', [])
    if args:
        print('**Key Arguments:**')
        for a in args:
            print(f'  - {a}')
    print()

    # Round-by-round convergence
    round_positions = data.get('round_positions', [])
    if round_positions:
        print('### 📈 Convergence Path')
        print()
        for rp in round_positions:
            rn = rp.get('round', '?')
            cc = rp.get('codex_confidence', 0)
            cl = rp.get('claude_confidence', 0)
            cp = rp.get('codex_position', '')[:60]
            clp = rp.get('claude_position', '')[:60]
            print(f'  Round {rn}:')
            print(f'    Codex  ({cc}): {cp}')
            print(f'    Claude ({cl}): {clp}')
        print()

    # User guidance
    print('---')
    print()
    print('⚖️  **No consensus was reached.** Both proposals are presented above.')
    print('  → Review the arguments from both Codex and Claude')
    print('  → Use your judgment to decide the best approach')
    print('  → The full debate is saved in your session history')
    print()

except Exception as e:
    print(f'[codex-collab] ⚠ Error formatting non-consensus display: {e}')
" "$detection_result" 2>/dev/null
}

# ===========================================================================
# CLI MODE
# ===========================================================================
if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  CLI_ROUNDS=""
  CLI_JSONL=""
  CLI_TOPIC=""
  CLI_FORMAT="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --rounds)   CLI_ROUNDS="$2"; shift 2 ;;
      --jsonl)    CLI_JSONL="$2"; shift 2 ;;
      --topic)    CLI_TOPIC="$2"; shift 2 ;;
      --display)  CLI_FORMAT="true"; shift ;;
      --help|-h)
        echo "Usage: detect-non-consensus.sh [--rounds '<json>'] [--jsonl '<file>'] [--topic '<topic>'] [--display]"
        echo ""
        echo "Detects non-consensus in codex-collab debate rounds."
        echo ""
        echo "Options:"
        echo "  --rounds <json>   JSON array of round objects"
        echo "  --jsonl <file>    JSONL file with debate round events"
        echo "  --topic <text>    Debate topic string"
        echo "  --display         Format output for user display (instead of raw JSON)"
        echo ""
        echo "Output (JSON):"
        echo "  consensus_state:   'consensus' | 'non-consensus' | 'unknown'"
        echo "  consensus_reached: boolean"
        echo "  divergence_score:  0.0-1.0 (how far apart final positions are)"
        echo "  codex_proposal:    { position, confidence, key_arguments }"
        echo "  claude_proposal:   { position, confidence, key_arguments }"
        echo "  convergence_trend: 'converging' | 'diverging' | 'stable'"
        echo "  round_positions:   per-round position and confidence data"
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$CLI_ROUNDS" && -z "$CLI_JSONL" ]]; then
    echo "Error: --rounds or --jsonl is required" >&2
    echo "Usage: detect-non-consensus.sh --rounds '<json>' [--topic '<topic>']" >&2
    exit 1
  fi

  result=""
  if [[ -n "$CLI_JSONL" ]]; then
    result=$(detect_non_consensus_from_jsonl "$CLI_JSONL" "$CLI_TOPIC")
  else
    result=$(detect_non_consensus "$CLI_ROUNDS" "$CLI_TOPIC")
  fi

  if [[ "$CLI_FORMAT" == "true" ]]; then
    format_non_consensus_display "$result"
  else
    echo "$result"
  fi
fi
