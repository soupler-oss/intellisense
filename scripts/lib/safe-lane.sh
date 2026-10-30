#!/usr/bin/env bash
# scripts/lib/safe-lane.sh — the "small-task fast lane" predicates for Live mode's Bash hooks.
#
# Used by scripts/userPromptSubmit-classifier.sh (dangerous-phrase guard on the prompt) and
# scripts/preToolUse-contract-gate.sh (safe-path relaxation). Each predicate asks the engine
# (internal/tier), which holds the only copy of the dangerous phrases, the safe paths (the policy's
# level-0 tier) and the per-language comment rules.
#
# FAIL-CLOSED everywhere: when the engine cannot be asked, a predicate reports "NOT safe" (and a
# phrase check reports "dangerous"), so a degraded install gets full gating, never the lane.
#
# No top-level `set -e` / `set -u` — this file is sourced into other shells.

_safe_lane_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=effective-tier.sh
type intellisense_path_tier >/dev/null 2>&1 || . "$_safe_lane_dir/effective-tier.sh" 2>/dev/null || true
type intellisense_engine >/dev/null 2>&1 || . "$_safe_lane_dir/engine.sh" 2>/dev/null || true
unset _safe_lane_dir

# intellisense_has_dangerous_phrase <text>
#   0 (true) when <text> says something is being disabled, bypassed or commented out — the fast lane is
#   then forbidden. Empty text → 1. Engine missing → 0 (fail closed).
intellisense_has_dangerous_phrase() {
    local text="$1" engine
    [ -n "$text" ] || return 1
    engine="$(intellisense_engine 2>/dev/null)"
    [ -n "$engine" ] || return 0
    printf '%s' "$text" | "$engine" check-phrase >/dev/null 2>&1
}

# intellisense_is_safe_path <relative-path> [repo-dir]
#   0 only when the engine puts the path in Tier 0 by a rule (docs, tests …) and the policy floor is 0.
intellisense_is_safe_path() {
    local path="$1" engine tier
    [ -n "$path" ] || return 1
    engine="$(intellisense_engine 2>/dev/null)"
    [ -n "$engine" ] || return 1
    tier="$("$engine" classify --dir "${2:-${INTELLISENSE_TIER_DIR:-.}}" --tier-only "$path" 2>/dev/null)"
    [ "$tier" = "0" ]
}

# intellisense_is_comment_or_doc_only_diff   (a unified diff on stdin)
#   0 only when every added or removed line is a comment (or prose, for a doc file) in the language of
#   the file named by the diff's "+++ b/" header. Unknown language, code lines or an empty diff → 1.
intellisense_is_comment_or_doc_only_diff() {
    local engine
    engine="$(intellisense_engine 2>/dev/null)"
    if [ -z "$engine" ]; then
        cat >/dev/null
        return 1
    fi
    "$engine" check-comment-only >/dev/null 2>&1
}
