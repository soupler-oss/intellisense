#!/bin/bash

# apply-merge-policy.sh — Layer 4 of Intellisense-Metadata coverage
#
# Per-repo merge-method policy enforcement: disables `squash merge` and
# `merge commit` (both destroy or hide trailers on `main`) and keeps
# `rebase merge` enabled (preserves per-commit trailers).
#
# Why this exists:
#   `git merge --squash` defeats `git interpret-trailers --parse`, and testing
#   confirmed GitHub's server-side squash breaks parsing even on
#   single-commit PRs because the inserted `Co-authored-by:` line splits
#   the trailer block. The only safe merge strategy is rebase.
#
# Usage:
#   scripts/apply-merge-policy.sh --repo <owner/repo> [--repo ...] [options]
#
# This script is idempotent — re-running on an already-configured repo
# detects the target state and skips the PATCH call.
#
# Per-repo opt-out: a repo's `.intellisense/manifest.json` may declare a
# `merge_policy_override` field (the merge-method exception path). When
# present, this script skips the repo and logs the reason. Use the
# `--manifest-dir` flag to point at the repo's working copy when
# running the script remotely.

set -euo pipefail

# -- Argument parsing ---------------------------------------------------------

REPOS=()
DRY_RUN=0
RESTORE_DEFAULTS=0
MANIFEST_DIR=""
SHOW_HELP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --repo)
            [ $# -ge 2 ] || { echo "❌ --repo requires a value (owner/repo)" >&2; exit 1; }
            REPOS+=("$2"); shift 2
            ;;
        --dry-run)
            DRY_RUN=1; shift
            ;;
        --restore-defaults)
            RESTORE_DEFAULTS=1; shift
            ;;
        --manifest-dir)
            [ $# -ge 2 ] || { echo "❌ --manifest-dir requires a path" >&2; exit 1; }
            MANIFEST_DIR="$2"; shift 2
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
Usage: apply-merge-policy.sh --repo <owner/repo> [--repo <owner/repo>...] [options]

Applies the intellisense merge-method policy to one or more GitHub repos:
  allow_squash_merge   = false   (trailers don't survive squash)
  allow_merge_commit   = false   (creates trailerless synthetic commits)
  allow_rebase_merge   = true    (only mode that preserves head trailers)

Options:
  --repo <owner/repo>     Repo to configure. Repeatable for batch operations.
  --dry-run               Print planned changes without making API calls.
  --restore-defaults      Re-enable all 3 merge methods (GitHub defaults).
                          Use with care — undoes merge-method enforcement.
  --manifest-dir <path>   Directory containing .intellisense/manifest.json for
                          opt-out detection. Defaults to current directory.
  --help, -h              Show this help.

Requires:
  - gh CLI authenticated with permission to PATCH the target repo settings.
  - jq for JSON parsing (idempotency check + opt-out detection).

Opt-out:
  Repos that opt out via .intellisense/manifest.json:
    {"merge_policy_override": "<rationale>"}
  are skipped with a log line; no PATCH is sent.

USAGE
    exit 0
fi

# -- Pre-flight checks --------------------------------------------------------

if ! command -v gh >/dev/null 2>&1; then
    echo "❌ gh CLI not found on PATH." >&2
    echo "   Install GitHub CLI: https://cli.github.com/" >&2
    echo "   Then authenticate: gh auth login" >&2
    exit 1
fi

if [ ${#REPOS[@]} -eq 0 ]; then
    echo "❌ At least one --repo <owner/repo> required." >&2
    echo "   Run with --help for usage." >&2
    exit 1
fi

# -- Opt-out detection --------------------------------------------------------

# check_opt_out — read .intellisense/manifest.json from --manifest-dir (or cwd) and
# echo the value of `merge_policy_override` if non-empty. Returns 0 if an
# override is present, 1 otherwise.
check_opt_out() {
    local manifest_path
    if [ -n "$MANIFEST_DIR" ]; then
        manifest_path="$MANIFEST_DIR/.intellisense/manifest.json"
    else
        manifest_path=".intellisense/manifest.json"
    fi
    [ -f "$manifest_path" ] || return 1
    command -v jq >/dev/null 2>&1 || return 1
    local override
    override="$(jq -r '.merge_policy_override // empty' "$manifest_path" 2>/dev/null)"
    [ -z "$override" ] && return 1
    echo "$override"
    return 0
}

# -- Target state -------------------------------------------------------------

if [ "$RESTORE_DEFAULTS" = "1" ]; then
    TARGET_SQUASH="true"
    TARGET_MERGE="true"
    TARGET_REBASE="true"
    POLICY_LABEL="GitHub defaults (all 3 merge methods enabled)"
else
    TARGET_SQUASH="false"
    TARGET_MERGE="false"
    TARGET_REBASE="true"
    POLICY_LABEL="intellisense rebase-only"
fi

# -- Opt-out applies only to the intellisense-apply path, not --restore-defaults ------

if [ "$RESTORE_DEFAULTS" = "0" ]; then
    if override="$(check_opt_out)"; then
        echo "⊘ .intellisense/manifest.json declares merge_policy_override='$override'"
        echo "  Skipping — opt-out honored (merge_policy_override in .intellisense/manifest.json)."
        exit 0
    fi
fi

# -- Apply to each repo -------------------------------------------------------

overall_exit=0

for repo in "${REPOS[@]}"; do
    echo "→ $repo: applying $POLICY_LABEL"

    # Idempotency check — GET current state, compare to target. If they
    # match, skip the PATCH (no-op for already-configured repos).
    current_state="$(gh api "/repos/$repo" 2>/dev/null || echo '{}')"
    if command -v jq >/dev/null 2>&1; then
        cur_squash="$(echo "$current_state" | jq -r '.allow_squash_merge // "unknown"')"
        cur_merge="$(echo "$current_state"  | jq -r '.allow_merge_commit // "unknown"')"
        cur_rebase="$(echo "$current_state" | jq -r '.allow_rebase_merge // "unknown"')"

        if [ "$cur_squash" = "$TARGET_SQUASH" ] \
            && [ "$cur_merge"  = "$TARGET_MERGE"  ] \
            && [ "$cur_rebase" = "$TARGET_REBASE" ]; then
            echo "  ✓ already in target state — unchanged (idempotent skip)"
            continue
        fi
    fi

    if [ "$DRY_RUN" = "1" ]; then
        echo "  [dry-run] would PATCH /repos/$repo with:"
        echo "             allow_squash_merge=$TARGET_SQUASH"
        echo "             allow_merge_commit=$TARGET_MERGE"
        echo "             allow_rebase_merge=$TARGET_REBASE"
        continue
    fi

    if gh api -X PATCH "/repos/$repo" \
            -F "allow_squash_merge=$TARGET_SQUASH" \
            -F "allow_merge_commit=$TARGET_MERGE" \
            -F "allow_rebase_merge=$TARGET_REBASE" \
            >/dev/null 2>&1; then
        echo "  ✓ applied"
    else
        echo "  ✗ FAILED to apply policy to $repo (gh api PATCH returned non-zero)" >&2
        echo "    Re-run with gh CLI in interactive mode for full error output." >&2
        overall_exit=1
    fi
done

exit $overall_exit
