#!/usr/bin/env bash
# engine.sh — find and call the intellisense engine (the Go binary) from Live mode's Bash.
#
# The engine is the ONLY tier model: internal/tier reads the repository's .intellisense.yml, so an
# in-session edit, a commit, a push and CI all get the same tier. Bash never keeps its own copy of the
# path rules, the comment-only fast lane or the dangerous-phrase list.
#
# Lookup order: $INTELLISENSE_BIN, ${INTELLISENSE_HOME:-~/.intellisense}/bin/intellisense (linked by
# `intellisense live install` / setup.sh), then `intellisense` on PATH.
#
# Sourced: no top-level `set -e` / `set -u`. bash 3.2 compatible.

intellisense_engine() {
    local candidate
    for candidate in "${INTELLISENSE_BIN:-}" "${INTELLISENSE_HOME:-$HOME/.intellisense}/bin/intellisense"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    command -v intellisense 2>/dev/null
}

# intellisense_engine_tier [repo-dir]   (newline-separated repo-relative paths on stdin)
#   Echoes the tier the engine gives those paths (path rules + the policy's minimum_tier), or nothing
#   when the engine is missing or the directory is not a repository. Empty input → 0.
intellisense_engine_tier() {
    local dir="${1:-${INTELLISENSE_TIER_DIR:-.}}" engine path n=0
    engine="$(intellisense_engine)" || return 1
    [ -n "$engine" ] || return 1
    set --
    while IFS= read -r path || [ -n "$path" ]; do
        [ -z "$path" ] && continue
        set -- "$@" "$path"
        n=$((n + 1))
    done
    if [ "$n" -eq 0 ]; then
        echo 0
        return 0
    fi
    "$engine" classify --dir "$dir" --tier-only "$@" 2>/dev/null
}
