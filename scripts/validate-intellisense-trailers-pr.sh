#!/bin/bash

# validate-intellisense-trailers-pr.sh — Layer 3 of Intellisense-Metadata coverage
#
# Server-side validator invoked from the GitHub Action on every PR. Walks
# the commits between --base and --head, requires each commit to carry a
# well-formed Intellisense-Metadata trailer (matching the pre-push schema at
# hooks/pre-push:418-458), and honors the same .intellisense/exception-allowlist.yaml
# governance rules (90-day cap, reason required, no self-approval).
#
# Exit codes:
#   0 — all commits OK (or no commits in range, or all-allowlisted)
#   1 — at least one commit fails validation
#
# Usage:
#   validate-intellisense-trailers-pr.sh --base <sha> --head <sha> [--allowlist <path>]
#
# Why this is a separate script (not just a function inside the workflow YAML):
#   Easier to unit-test in isolation (see tests/test_validate_intellisense_trailers_pr.sh).
#   Same script can be invoked from other CI systems if we ever leave GitHub.

set -euo pipefail

# -- Argument parsing ---------------------------------------------------------

BASE=""
HEAD=""
ALLOWLIST=""
SHOW_HELP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --base)
            [ $# -ge 2 ] || { echo "❌ --base requires a SHA" >&2; exit 1; }
            BASE="$2"; shift 2
            ;;
        --head)
            [ $# -ge 2 ] || { echo "❌ --head requires a SHA" >&2; exit 1; }
            HEAD="$2"; shift 2
            ;;
        --allowlist)
            [ $# -ge 2 ] || { echo "❌ --allowlist requires a path" >&2; exit 1; }
            ALLOWLIST="$2"; shift 2
            ;;
        --help|-h)
            SHOW_HELP=1; shift
            ;;
        *)
            echo "❌ Unknown argument: $1" >&2
            echo "   Run with --help for usage." >&2
            exit 1
            ;;
    esac
done

# -- Help ---------------------------------------------------------------------

if [ "$SHOW_HELP" = "1" ]; then
    cat <<'USAGE'
Usage: validate-intellisense-trailers-pr.sh --base <sha> --head <sha> [options]

Walks commits in base..head and validates each one carries a well-formed
Intellisense-Metadata JSON trailer. Used by the GitHub Action to gate PR merges.

Arguments:
  --base <sha>            Base commit SHA (PR target branch tip).
  --head <sha>            Head commit SHA (PR source branch tip).
  --allowlist <path>      Optional override for the allowlist file path.
                          Defaults to .intellisense/exception-allowlist.yaml in cwd.
  --help, -h              Show this help.

Exit codes:
  0   all commits valid (or no commits in range, or all allowlisted)
  1   one or more commits failed validation

The validator mirrors hooks/pre-push on schema + allowlist semantics —
they share the .intellisense/exception-allowlist.yaml file as the single source of
truth for exceptions.

USAGE
    exit 0
fi

# -- Pre-flight checks --------------------------------------------------------

if [ -z "$BASE" ] || [ -z "$HEAD" ]; then
    echo "❌ Both --base and --head are required. Run with --help." >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq not found on PATH. Install jq for JSON validation." >&2
    exit 1
fi

# Default allowlist path is relative to cwd (matches the pre-push per-repo behavior).
[ -z "$ALLOWLIST" ] && ALLOWLIST=".intellisense/exception-allowlist.yaml"

# -- Helper: check if a commit is on the allowlist with passing governance ---
# Returns:
#   0 — allowlisted, all governance OK (caller should skip metadata check)
#   1 — not on allowlist (caller should validate normally)
#   2 — allowlisted BUT governance failed (caller MUST block, msg already printed)
_allowlist_check() {
    local sha="$1"
    [ -f "$ALLOWLIST" ] || return 1

    # Find the entry block for this SHA.
    local entry
    entry="$(awk -v target="$sha" '
        /^- *sha:/ {
            line=$0
            sub(/^- *sha:[[:space:]]*/, "", line)
            gsub(/"/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == target) { capture=1; print "sha: " target; next }
            capture=0; next
        }
        capture && /^  +(reason|expiry|added_by):/ { print }
        capture && /^- *sha:/                       { capture=0 }
    ' "$ALLOWLIST" 2>/dev/null)"

    [ -z "$entry" ] && return 1

    local reason expiry added_by
    reason="$(echo "$entry" | awk -F':' '/^[[:space:]]*reason:/  {sub(/^[[:space:]]*reason:[[:space:]]*/, ""); gsub(/"/, ""); sub(/[[:space:]]+$/, ""); print}')"
    expiry="$(echo "$entry" | awk -F':' '/^[[:space:]]*expiry:/  {sub(/^[[:space:]]*expiry:[[:space:]]*/, ""); gsub(/"/, ""); sub(/[[:space:]]+$/, ""); print}')"
    added_by="$(echo "$entry" | awk -F':' '/^[[:space:]]*added_by:/ {sub(/^[[:space:]]*added_by:[[:space:]]*/, ""); gsub(/"/, ""); sub(/[[:space:]]+$/, ""); print}')"

    if [ -z "$reason" ]; then
        echo "❌ BLOCKED: allowlist entry for $sha missing required 'reason'" >&2
        return 2
    fi
    if [ -z "$expiry" ]; then
        echo "❌ BLOCKED: allowlist entry for $sha missing required 'expiry'" >&2
        return 2
    fi

    local today_epoch expiry_epoch cap_epoch
    if expiry_epoch=$(date -u -j -f "%Y-%m-%d" "$expiry" +%s 2>/dev/null); then
        :
    elif expiry_epoch=$(date -u -d "$expiry" +%s 2>/dev/null); then
        :
    else
        echo "❌ BLOCKED: allowlist entry for $sha has unparseable expiry '$expiry'" >&2
        return 2
    fi
    today_epoch=$(date -u +%s)
    cap_epoch=$((today_epoch + 7776000))

    if [ "$expiry_epoch" -lt "$today_epoch" ]; then
        echo "❌ BLOCKED: allowlist entry for $sha is expired (expiry=$expiry)" >&2
        return 2
    fi
    if [ "$expiry_epoch" -gt "$cap_epoch" ]; then
        echo "❌ BLOCKED: allowlist entry for $sha has expiry >90 days from today (expiry=$expiry exceeds 90-day cap)" >&2
        return 2
    fi

    local commit_author
    commit_author="$(git log -1 --format=%ae "$sha" 2>/dev/null)"
    if [ -n "$added_by" ] && [ -n "$commit_author" ] && [ "$added_by" = "$commit_author" ]; then
        echo "❌ BLOCKED: allowlist entry for $sha is self-approval (added_by=$added_by == commit author)" >&2
        return 2
    fi

    return 0
}

# Path tier from the intellisense engine, the only tier model (internal/tier, reading the repository's
# .intellisense.yml). Paths on stdin; prints the tier, or 0 when the engine is not installed — the push
# gate, which requires the engine, still checks the evidence.
_intellisense_engine() {
    local candidate
    for candidate in "${INTELLISENSE_BIN:-}" "${INTELLISENSE_HOME:-$HOME/.intellisense}/bin/intellisense"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    command -v intellisense 2>/dev/null
}
_engine_path_tier() {
    local engine path n=0 t
    engine="$(_intellisense_engine)"
    set --
    while IFS= read -r path || [ -n "$path" ]; do
        [ -z "$path" ] && continue
        set -- "$@" "$path"
        n=$((n + 1))
    done
    if [ "$n" -eq 0 ] || [ -z "$engine" ]; then
        printf '0'
        return 0
    fi
    t="$("$engine" classify --tier-only "$@" 2>/dev/null)"
    case "$t" in [0-9]) printf '%s' "$t" ;; *) printf '0' ;; esac
}

# -- Helper: the path-tier the engine gives a list of files (stdin) ----------
_derive_commit_path_tier() {
    _engine_path_tier
}

# -- Helper: validate one commit's Intellisense-Metadata trailer ---------------------
# Returns 0 on pass, 1 on fail (with stderr message). Uses
# `git interpret-trailers --parse` so the trailer block is correctly
# extracted from the message (no false positives from body text).
_validate_one_commit() {
    local sha="$1"
    local msg
    msg="$(git log -1 --format=%B "$sha" 2>/dev/null)"

    # Allowlist precedence — short-circuit before metadata check.
    _allowlist_check "$sha"
    case $? in
        0) return 0 ;;
        2) return 1 ;;
        1) ;;
    esac

    # Duplicate-trailer detection via interpret-trailers --parse.
    local md_count
    md_count="$(echo "$msg" | git interpret-trailers --parse 2>/dev/null | grep -c '^Intellisense-Metadata:')"
    if [ "$md_count" -gt 1 ]; then
        echo "❌ BLOCKED: commit ${sha:0:7} has $md_count Intellisense-Metadata trailers (duplicates ambiguous; need exactly one)" >&2
        return 1
    fi

    # Extract the trailer line via interpret-trailers --parse so body prose /
    # quoted JSON that happens to start with "Intellisense-Metadata:" is NOT mistaken
    # for a real trailer.
    local metadata_line
    metadata_line="$(echo "$msg" | git interpret-trailers --parse 2>/dev/null | grep '^Intellisense-Metadata:' | head -1 | sed 's/^Intellisense-Metadata: //')"

    if [ -z "$metadata_line" ]; then
        echo "❌ BLOCKED: commit ${sha:0:7} has no Intellisense-Metadata trailer" >&2
        echo "   Fix: ensure prepare-commit-msg is installed, or add commit to .intellisense/exception-allowlist.yaml with governance." >&2
        return 1
    fi

    # Parse-validate the JSON.
    if ! echo "$metadata_line" | jq -e . >/dev/null 2>&1; then
        echo "❌ BLOCKED: commit ${sha:0:7} has malformed JSON in Intellisense-Metadata trailer (invalid JSON; cannot parse)" >&2
        return 1
    fi

    # Schema v=1 fields.
    local schema_v
    schema_v="$(echo "$metadata_line" | jq -r '.v // empty' 2>/dev/null)"
    if [ "$schema_v" != "1" ]; then
        echo "❌ BLOCKED: commit ${sha:0:7} Intellisense-Metadata is not v=1 (got v=${schema_v:-absent})" >&2
        return 1
    fi

    local author_type
    author_type="$(echo "$metadata_line" | jq -r '.author_type // empty' 2>/dev/null)"
    if [ -z "$author_type" ]; then
        echo "❌ BLOCKED: commit ${sha:0:7} Intellisense-Metadata missing author_type" >&2
        return 1
    fi

    # Baseline fields for every author_type.
    local missing=""
    local field
    for field in v author_type commit_kind stamping_source; do
        echo "$metadata_line" | jq -e --arg f "$field" 'has($f)' >/dev/null 2>&1 \
            || missing="$missing $field"
    done

    # Per-author_type enum (mirrors hooks/pre-push:418-458).
    case "$author_type" in
        merge|squash|no_session_signal)
            : # baseline only
            ;;
        claude_with_intellisense)
            echo "$metadata_line" | jq -e 'has("session")' >/dev/null 2>&1 \
                || missing="$missing session"
            local cls_state
            cls_state="$(echo "$metadata_line" | jq -r '.classification_state // "ok"' 2>/dev/null)"
            if [ "$cls_state" = "ok" ]; then
                for field in tier mode version tokens; do
                    echo "$metadata_line" | jq -e --arg f "$field" 'has($f)' >/dev/null 2>&1 \
                        || missing="$missing $field"
                done
            fi
            ;;
        claude_inline)
            # Inline (agent-written, hooksPath-independent) trailer. Two-contract
            # model: source fields are value-checked so inline cannot masquerade
            # as hook-stamped/merge. Tokens are NEVER computed by Claude → not
            # required, and REJECTED if present (fail-closed).
            for field in session tier mode version; do
                echo "$metadata_line" | jq -e --arg f "$field" 'has($f)' >/dev/null 2>&1 \
                    || missing="$missing $field"
            done
            # Exact source values (must match the generator's contract).
            local inline_ck inline_ss
            inline_ck="$(echo "$metadata_line" | jq -r '.commit_kind // empty' 2>/dev/null)"
            inline_ss="$(echo "$metadata_line" | jq -r '.stamping_source // empty' 2>/dev/null)"
            if [ "$inline_ck" != "single" ]; then
                echo "❌ BLOCKED: commit ${sha:0:7} claude_inline commit_kind='$inline_ck' (must be 'single')" >&2
                return 1
            fi
            if [ "$inline_ss" != "agent_inline" ]; then
                echo "❌ BLOCKED: commit ${sha:0:7} claude_inline stamping_source='$inline_ss' (must be 'agent_inline')" >&2
                return 1
            fi
            local inline_tier
            inline_tier="$(echo "$metadata_line" | jq -r '.tier // 0' 2>/dev/null)"
            if [ "$inline_tier" != "0" ]; then
                for field in skills agents rules_expected; do
                    echo "$metadata_line" | jq -e --arg f "$field" 'has($f)' >/dev/null 2>&1 \
                        || missing="$missing $field"
                done
            fi
            if echo "$metadata_line" | jq -e 'has("tokens")' >/dev/null 2>&1; then
                echo "❌ BLOCKED: commit ${sha:0:7} claude_inline must not carry a tokens field (Claude cannot self-report tokens)" >&2
                return 1
            fi
            # INLINE TIER GUARD: an untrusted manual trailer must not under-state
            # risk. declared tier must be >= max(commit_path_tier, policy_floor),
            # matching the generator's effective-tier contract.
            local inline_path_tier inline_policy_tier inline_floor inline_repo
            inline_path_tier="$(git diff-tree --no-commit-id --name-only -r --root "$sha" 2>/dev/null | _derive_commit_path_tier)"
            inline_path_tier="${inline_path_tier:-0}"
            inline_policy_tier=0
            inline_repo="$(git rev-parse --show-toplevel 2>/dev/null)"
            if [ -n "$inline_repo" ] && [ -f "$inline_repo/.intellisense/manifest.json" ]; then
                inline_policy_tier="$(jq -r '.policy_minimum_tier // 0' "$inline_repo/.intellisense/manifest.json" 2>/dev/null)"
                case "$inline_policy_tier" in 0|1|2) ;; *) inline_policy_tier=0 ;; esac
            fi
            inline_floor="$inline_path_tier"
            [ "$inline_policy_tier" -gt "$inline_floor" ] 2>/dev/null && inline_floor="$inline_policy_tier"
            case "$inline_tier" in 0|1|2) ;; *) inline_tier=0 ;; esac
            if [ "$inline_tier" -lt "$inline_floor" ] 2>/dev/null; then
                echo "❌ BLOCKED: commit ${sha:0:7} claude_inline declares tier $inline_tier but max(path=$inline_path_tier, policy=$inline_policy_tier) requires tier $inline_floor (under-stamped)" >&2
                return 1
            fi
            # Co-author guard (§3.7, fail-closed): a claude_inline trailer is
            # plain text anyone can write. Without Claude author/co-author
            # evidence we refuse to attribute the commit as intellisense+Claude — a
            # stderr warning alone would not stop analytics (which ingests git data,
            # not validator stderr) from recording a human commit as Claude's.
            if ! printf '%s' "$msg" | grep -qiE '^Co-Authored-By:.*Claude'; then
                echo "❌ BLOCKED: commit ${sha:0:7} claude_inline has no Co-Authored-By: Claude evidence (cannot attribute a possibly human-authored commit as intellisense+Claude)" >&2
                return 1
            fi
            ;;
        bot|github_ui|external_contributor|unknown)
            echo "$metadata_line" | jq -e 'has("attribution_basis")' >/dev/null 2>&1 \
                || missing="$missing attribution_basis"
            ;;
        *)
            echo "❌ BLOCKED: commit ${sha:0:7} Intellisense-Metadata has unknown author_type='$author_type' (not in enum)" >&2
            return 1
            ;;
    esac

    if [ -n "$missing" ]; then
        echo "❌ BLOCKED: commit ${sha:0:7} Intellisense-Metadata missing required fields:$missing" >&2
        return 1
    fi

    return 0
}

# -- Walk the range -----------------------------------------------------------

# `base..head` gives commits in head NOT in base. Empty range → 0 commits → exit 0.
total=0
failed=0
while read -r sha; do
    [ -z "$sha" ] && continue
    total=$((total + 1))
    if ! _validate_one_commit "$sha"; then
        failed=$((failed + 1))
    fi
done < <(git rev-list "${BASE}..${HEAD}" 2>/dev/null)

if [ "$failed" -gt 0 ]; then
    echo "" >&2
    echo "❌ intellisense/trailers: $failed/$total commit(s) failed validation" >&2
    exit 1
fi

if [ "$total" -gt 0 ]; then
    echo "✅ intellisense/trailers: $total commit(s) validated"
fi

exit 0
