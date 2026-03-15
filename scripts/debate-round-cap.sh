#!/usr/bin/env bash
# debate-round-cap.sh — Debate round cap calculator and enforcer
#
# Calculates the effective maximum rounds for a debate based on config:
#   effective_max = default_rounds + max_additional_rounds
#
# The max_additional_rounds is HARD-CAPPED at 2 (enforced by load-config.sh).
# This means additional rounds can never exceed default + 2, regardless of config.
#
# Usage:
#   # Source for shell functions:
#   source scripts/debate-round-cap.sh
#   effective_max=$(get_effective_max_rounds)
#   is_within_cap 4   # returns 0 (true) if round 4 is within cap
#
#   # Or run directly:
#   ./scripts/debate-round-cap.sh [--check <round_number>]
#
# Environment:
#   Requires load-config.sh to be sourced or CODEX_CONFIG_LOADED=1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Hard cap constant — max_additional_rounds can NEVER exceed this value
readonly DEBATE_ADDITIONAL_ROUNDS_HARD_CAP=2

# ---------------------------------------------------------------------------
# Ensure config is loaded
# ---------------------------------------------------------------------------
_ensure_config() {
  if [[ "${CODEX_CONFIG_LOADED:-0}" != "1" ]]; then
    # shellcheck source=load-config.sh
    source "${SCRIPT_DIR}/load-config.sh"
    load_config
  fi
}

# ---------------------------------------------------------------------------
# Get effective maximum rounds from config
# ---------------------------------------------------------------------------
get_effective_max_rounds() {
  _ensure_config

  local default_rounds
  local max_additional

  default_rounds=$(config_get "debate.default_rounds" "3")
  max_additional=$(config_get "debate.max_additional_rounds" "2")

  # Enforce hard cap on additional rounds (defense in depth — load-config.sh also clamps)
  if [[ "$max_additional" -gt "$DEBATE_ADDITIONAL_ROUNDS_HARD_CAP" ]]; then
    max_additional=$DEBATE_ADDITIONAL_ROUNDS_HARD_CAP
  fi
  if [[ "$max_additional" -lt 0 ]]; then
    max_additional=0
  fi

  local effective_max=$(( default_rounds + max_additional ))
  echo "$effective_max"
}

# ---------------------------------------------------------------------------
# Get the default rounds (without additional)
# ---------------------------------------------------------------------------
get_default_rounds() {
  _ensure_config
  config_get "debate.default_rounds" "3"
}

# ---------------------------------------------------------------------------
# Get max additional rounds (with hard cap applied)
# ---------------------------------------------------------------------------
get_max_additional_rounds() {
  _ensure_config

  local max_additional
  max_additional=$(config_get "debate.max_additional_rounds" "2")

  # Enforce hard cap
  if [[ "$max_additional" -gt "$DEBATE_ADDITIONAL_ROUNDS_HARD_CAP" ]]; then
    max_additional=$DEBATE_ADDITIONAL_ROUNDS_HARD_CAP
  fi
  if [[ "$max_additional" -lt 0 ]]; then
    max_additional=0
  fi

  echo "$max_additional"
}

# ---------------------------------------------------------------------------
# Check if a given round number is within the cap
# Returns 0 (true) if within cap, 1 (false) if exceeds cap
# ---------------------------------------------------------------------------
is_within_cap() {
  local round_number="${1:?Usage: is_within_cap <round_number>}"
  local effective_max
  effective_max=$(get_effective_max_rounds)

  if [[ "$round_number" -le "$effective_max" ]]; then
    return 0
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Format round cap info for display
# ---------------------------------------------------------------------------
format_round_cap_info() {
  _ensure_config

  local default_rounds max_additional effective_max
  default_rounds=$(get_default_rounds)
  max_additional=$(get_max_additional_rounds)
  effective_max=$(get_effective_max_rounds)

  echo "max_rounds: ${effective_max} (default: ${default_rounds} + additional: ${max_additional}, hard cap: ${DEBATE_ADDITIONAL_ROUNDS_HARD_CAP})"
}

# ---------------------------------------------------------------------------
# CLI mode
# ---------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  CHECK_ROUND=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)
        CHECK_ROUND="$2"
        shift 2
        ;;
      --info)
        source "${SCRIPT_DIR}/load-config.sh"
        format_round_cap_info
        exit 0
        ;;
      --help|-h)
        echo "Usage: debate-round-cap.sh [--check <round>] [--info]"
        echo ""
        echo "Calculates effective debate round cap from config."
        echo ""
        echo "  --check <N>  Check if round N is within the cap (exit 0=yes, 1=no)"
        echo "  --info       Display round cap breakdown"
        echo "  (no args)    Print effective max rounds number"
        exit 0
        ;;
      *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
  done

  source "${SCRIPT_DIR}/load-config.sh"

  if [[ -n "$CHECK_ROUND" ]]; then
    effective=$(get_effective_max_rounds)
    if is_within_cap "$CHECK_ROUND"; then
      echo "Round ${CHECK_ROUND} is within cap (effective max: ${effective})"
      exit 0
    else
      echo "Round ${CHECK_ROUND} EXCEEDS cap (effective max: ${effective})"
      exit 1
    fi
  else
    get_effective_max_rounds
  fi
fi
