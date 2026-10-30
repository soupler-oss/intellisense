#!/usr/bin/env bash
# contract-file.sh — where a branch's change contract lives, and how Live mode reads it.
#
# One contract per branch: .intellisense/contracts/<branch, / → __>.md. It is committed with the change, so
# the same file approves edits in Live mode (front matter `state: approved`) and is the push gate's evidence
# (Core mode validates its front matter against the policy's contract fields). Live mode's validator reads the
# front matter as JSON through the engine (`intellisense contract show`).
#
# Sourced: no top-level `set -e` / `set -u`. bash 3.2 compatible.

_contract_file_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
type intellisense_engine >/dev/null 2>&1 || . "$_contract_file_dir/engine.sh"
unset _contract_file_dir

# intellisense_contract_file <repo-root> <branch>
intellisense_contract_file() {
    printf '%s/.intellisense/contracts/%s.md\n' "$1" "${2//\//__}"
}

# intellisense_contract_json <contract.md> <out.json>
#   Writes the front matter as JSON. The shared field names fill Live mode's: scope → requirement,
#   risk → risk_level (when those are absent). Returns 1 when the engine is missing or the file has no valid
#   front matter (the caller reports it).
intellisense_contract_json() {
    local file="$1" out="$2" engine
    engine="$(intellisense_engine)"
    [ -n "$engine" ] || return 1
    "$engine" contract show "$file" 2>/dev/null \
        | jq '(if has("requirement") then . else (if has("scope") then .requirement = .scope else . end) end)
              | (if has("risk_level") then . else (if has("risk") then .risk_level = .risk else . end) end)' \
        >"$out" 2>/dev/null || return 1
    [ -s "$out" ]
}

# intellisense_contract_set <contract.md> key=value...
intellisense_contract_set() {
    local engine
    engine="$(intellisense_engine)"
    [ -n "$engine" ] || return 1
    "$engine" contract set "$@" >/dev/null 2>&1
}
