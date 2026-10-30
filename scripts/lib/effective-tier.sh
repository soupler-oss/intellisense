#!/usr/bin/env bash
# effective-tier.sh — tier resolver for Live mode's Bash hooks.
#
#   effective_tier = max(prompt_tier, changed_path_tier, policy_tier)
#
#     prompt_tier        — from the prompt classifier (per prompt)
#     changed_path_tier  — the engine's tier for the affected files (the repository's .intellisense.yml)
#     policy_tier        — the repository's floor: the policy's minimum_tier, or the Live manifest's
#                          policy_minimum_tier (.intellisense/manifest.json), whichever is higher
#
# The path rules live only in the engine (internal/tier); this file holds no copy of them. When the engine is missing, every path is treated as Tier 1 (fail-safe: full
# gating, never a silent relaxation) and a warning names the fix.
#
# Sourced by scripts/preToolUse-contract-gate.sh, scripts/intellisense-ship.sh and the commit hooks.
# No top-level `set -e` / `set -u`.

_effective_tier_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=engine.sh
. "$_effective_tier_dir/engine.sh"
unset _effective_tier_dir

# Tier used for a path when the engine cannot be asked.
INTELLISENSE_FALLBACK_TIER="${INTELLISENSE_FALLBACK_TIER:-1}"

_intellisense_engine_missing_warned=0
_intellisense_warn_engine_missing() {
    [ "$_intellisense_engine_missing_warned" = "1" ] && return 0
    _intellisense_engine_missing_warned=1
    echo "intellisense: the engine is not installed, so every file counts as Tier $INTELLISENSE_FALLBACK_TIER. Fix: intellisense live install (or put intellisense on PATH)." >&2
}

# intellisense_path_tier <relative-path> [repo-dir]
#   echoes the tier of one path.
intellisense_path_tier() {
    printf '%s\n' "$1" | intellisense_changed_path_tier_from_lines "${2:-}"
}

# intellisense_changed_path_tier_from_lines [repo-dir]
#   Reads newline-separated paths from stdin; echoes their tier (the highest file tier, raised to the
#   policy's minimum_tier). Empty input → "0".
intellisense_changed_path_tier_from_lines() {
    local paths tier
    paths="$(cat)"
    if [ -z "$(printf '%s' "$paths" | tr -d '[:space:]')" ]; then
        echo 0
        return 0
    fi
    tier="$(printf '%s\n' "$paths" | intellisense_engine_tier "${1:-}")"
    case "$tier" in
        [0-9]) echo "$tier" ;;
        *) _intellisense_warn_engine_missing; echo "$INTELLISENSE_FALLBACK_TIER" ;;
    esac
}

# intellisense_policy_tier <repo-root>
#   echoes the repository's tier floor.
intellisense_policy_tier() {
    local repo="${1:-.}" floor=0 engine val
    engine="$(intellisense_engine)"
    if [ -n "$engine" ]; then
        val="$("$engine" policy get --dir "$repo" minimum_tier 2>/dev/null)"
        case "$val" in [0-9]) floor="$val" ;; esac
    fi
    local manifest="$repo/.intellisense/manifest.json"
    if [ -f "$manifest" ] && command -v jq >/dev/null 2>&1; then
        val="$(jq -r '.policy_minimum_tier // 0' "$manifest" 2>/dev/null)"
        case "$val" in [0-9]) [ "$val" -gt "$floor" ] && floor="$val" ;; esac
    fi
    echo "$floor"
}

# intellisense_effective_tier <prompt_tier> <path_tier> <policy_tier>
#   echoes the highest of the three. Empty / non-numeric arguments count as 0.
intellisense_effective_tier() {
    local max=0 v
    for v in "${1:-0}" "${2:-0}" "${3:-0}"; do
        case "$v" in
            [0-9]) [ "$v" -gt "$max" ] && max="$v" ;;
        esac
    done
    echo "$max"
}
