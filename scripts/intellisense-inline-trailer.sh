#!/usr/bin/env bash
# scripts/intellisense-inline-trailer.sh
#
# Generate ONE `Intellisense-Metadata: <json>` trailer line on stdout for Claude to
# include in a commit message. This is the hooksPath-INDEPENDENT path to
# stamping: where the prepare-commit-msg hook is absent (beads owns
# core.hooksPath, fresh clone, second machine, --no-verify), this generator
# still produces attribution.
#
# Properties:
#   - no file mutation, no commit-message mutation, no hook dependency
#   - read-only git inspection only (staged paths / commit diff for tier)
#
# author_type = "claude_inline". Tokens are NEVER emitted — they require the
# transcript-walk + two-phase cursor that only the hook can do, and faking them
# would trip post-commit Case C. When the hook DOES run, it strips this line and
# replaces it with an accurate claude_with_intellisense trailer (one trailer either way).
#
# Usage:
#   intellisense-inline-trailer.sh              # tier from staged files (default; pre-commit)
#   intellisense-inline-trailer.sh --staged     # explicit
#   intellisense-inline-trailer.sh --commit REF # tier from a commit's diff (amend / /ship / repair)
#

set -uo pipefail

MODE="staged"
COMMIT_REF=""
while [ $# -gt 0 ]; do
    case "$1" in
        --staged) MODE="staged"; shift ;;
        --commit) MODE="commit"; COMMIT_REF="${2:-HEAD}"; shift 2 ;;
        *) shift ;;
    esac
done

# ─── Resolve workspace (session state) and INTELLISENSE_SETUP (VERSION + rules) ──────
WS="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
SESSION_DIR="$WS/.intellisense/session"

HOOK_SOURCE="$(readlink "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")"
if [[ "$HOOK_SOURCE" != /* ]]; then
    HOOK_SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && cd "$(dirname "$HOOK_SOURCE")" && pwd)/$(basename "$HOOK_SOURCE")"
fi
INTELLISENSE_SETUP="$(cd "$(dirname "$HOOK_SOURCE")/.." && pwd)"

# ─── Identify active session — no session => emit nothing (not a Claude commit) ─
POINTER="$SESSION_DIR/current-session-id"
[[ -f "$POINTER" ]] || exit 0
SID="$(cat "$POINTER" 2>/dev/null)"
[[ -z "$SID" ]] && exit 0

CLASSIFICATION="$SESSION_DIR/$SID.classification.json"
[[ -f "$CLASSIFICATION" ]] || exit 0   # no classification => don't stamp

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

_derive_path_tier() {
    _engine_path_tier
}

if [ "$MODE" = "commit" ]; then
    # --root so a root commit (no parent) still lists its files instead of empty.
    PATH_TIER="$(git diff-tree --no-commit-id --name-only -r --root "$COMMIT_REF" 2>/dev/null | _derive_path_tier)"
else
    PATH_TIER="$(git diff --cached --name-only 2>/dev/null | _derive_path_tier)"
fi
PATH_TIER="${PATH_TIER:-0}"

# ─── jq-degraded path: emit NOTHING ─────────────────────────────────────────
# Without jq we cannot assemble a complete trailer, and a partial one (missing
# mode/version) would be REJECTED by the pre-push and PR validators — which is worse than
# no stamp (it would fail the push/PR). So emit nothing and exit 0; the commit
# is simply unstamped on a jq-less host. (INTELLISENSE_TEST_SIMULATE_NO_JQ forces this
# path in tests, mirroring hooks/prepare-commit-msg.)
if [ "${INTELLISENSE_TEST_SIMULATE_NO_JQ:-0}" = "1" ] || ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

# ─── Classifier tier/mode + effective-tier composition ──────────────────────
CLASSIFIER_TIER="$(jq -r '.tier // 0' "$CLASSIFICATION" 2>/dev/null)"
MODE_VAL="$(jq -r '.mode // empty' "$CLASSIFICATION" 2>/dev/null)"
case "$CLASSIFIER_TIER" in 0|1|2) ;; *) CLASSIFIER_TIER=0 ;; esac

POLICY_TIER="0"
EFFECTIVE_TIER_LIB="$INTELLISENSE_SETUP/scripts/lib/effective-tier.sh"
if [[ -f "$EFFECTIVE_TIER_LIB" ]]; then
    # shellcheck disable=SC1090
    source "$EFFECTIVE_TIER_LIB" 2>/dev/null || true
fi
if declare -F intellisense_policy_tier >/dev/null 2>&1; then
    POLICY_TIER="$(intellisense_policy_tier "$WS" 2>/dev/null || echo 0)"
fi
case "$POLICY_TIER" in 0|1|2) ;; *) POLICY_TIER=0 ;; esac

TIER="$CLASSIFIER_TIER"
if declare -F intellisense_effective_tier >/dev/null 2>&1; then
    TIER="$(intellisense_effective_tier "$CLASSIFIER_TIER" "$PATH_TIER" "$POLICY_TIER" 2>/dev/null || echo "$CLASSIFIER_TIER")"
else
    for _c in "$PATH_TIER" "$POLICY_TIER"; do
        case "$_c" in 0|1|2) [ "$_c" -gt "$TIER" ] && TIER="$_c" ;; esac
    done
fi

# ─── VERSION ─────────────────────────────────────────────────────────────────
INTELLISENSE_VERSION="unknown"
[[ -f "$INTELLISENSE_SETUP/VERSION" ]] && INTELLISENSE_VERSION="$(tr -d '[:space:]' < "$INTELLISENSE_SETUP/VERSION")"

# ─── skills / agents (usage.json) ────────────────────────────────────────────
USAGE="$SESSION_DIR/$SID.usage.json"
SKILLS_JSON='[]'; AGENTS_JSON='[]'
if [[ -f "$USAGE" ]]; then
    SKILLS_JSON="$(jq -c '.skills_used // []' "$USAGE" 2>/dev/null || echo '[]')"
    AGENTS_JSON="$(jq -c '.agents_spawned // []' "$USAGE" 2>/dev/null || echo '[]')"
fi

# ─── rules_expected from tier+mode (classifier-rules.json) ───────────────────
RULES_JSON='[]'
CLASSIFIER_RULES="$INTELLISENSE_SETUP/scripts/classifier-rules.json"
if [[ -f "$CLASSIFIER_RULES" && "$TIER" != "0" && -n "$MODE_VAL" ]]; then
    KEY="tier_${TIER}_${MODE_VAL}"
    RULES_JSON="$(jq -c --arg k "$KEY" '.load_files_by_classification[$k] // []' "$CLASSIFIER_RULES" 2>/dev/null || echo '[]')"
    if [[ "$RULES_JSON" == "[]" && "$TIER" == "2" ]]; then
        RULES_JSON="$(jq -c '.load_files_by_classification.tier_2_default // []' "$CLASSIFIER_RULES" 2>/dev/null || echo '[]')"
    fi
fi

# ─── Build the trailer. Tier 0 omits skills/agents/rules_expected (mirrors hook). ─
if [[ "$TIER" == "0" ]]; then
    JSON="$(jq -nc \
        --argjson tier "$TIER" --arg mode "$MODE_VAL" --arg session "$SID" --arg version "$INTELLISENSE_VERSION" \
        '{v:1, author_type:"claude_inline", commit_kind:"single", stamping_source:"agent_inline",
          classification_state:"ok", tier:$tier, mode:$mode, session:$session, version:$version}')"
else
    JSON="$(jq -nc \
        --argjson tier "$TIER" --arg mode "$MODE_VAL" --arg session "$SID" --arg version "$INTELLISENSE_VERSION" \
        --argjson skills "$SKILLS_JSON" --argjson agents "$AGENTS_JSON" --argjson rules "$RULES_JSON" \
        '{v:1, author_type:"claude_inline", commit_kind:"single", stamping_source:"agent_inline",
          classification_state:"ok", tier:$tier, mode:$mode, session:$session, version:$version,
          skills:$skills, agents:$agents, rules_expected:$rules}')"
fi

printf 'Intellisense-Metadata: %s\n' "$JSON"
exit 0
