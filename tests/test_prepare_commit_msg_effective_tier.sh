#!/usr/bin/env bash
# tests/test_prepare_commit_msg_effective_tier.sh
#
# Regression test for hooks/prepare-commit-msg effective-tier composition.
#
# Bug shape: per-prompt classifier tier can drift mid-task
# (sub-prompt heuristic misclassifications — e.g. "have you run tests?" gets
# classified Tier 0 inside an otherwise-Tier-1 task). The hook stamped the
# classifier's tier verbatim into Intellisense-Metadata, so commits touching Tier 1
# paths (setup.sh, verify-setup.sh) shipped with tier=0.
#
# Fix shape: compose effective_tier = max(classifier_tier, staged_path_tier,
# policy_tier) before building INTELLISENSE_METADATA_JSON. Mirrors the composition
# already used by scripts/preToolUse-contract-gate.sh and hooks/pre-push.
#
# Case A is the actual RED-then-GREEN regression. Cases B and C are guard
# rails to prove the composition does not spuriously escalate Tier 0 work
# and does not silently demote a correctly-classified Tier 2 prompt.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/hooks/prepare-commit-msg"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# Build an isolated git workspace with a real git repo (so the hook's
# `git diff --cached --name-only` call returns the staged file), plus the
# .intellisense/session/ scaffolding the hook reads. The fixture stages exactly one
# file so path-tier derivation is unambiguous.
#
# Args:
#   $1 — classifier tier ("0", "1", or "2") written into classification.json
#   $2 — classifier mode written into classification.json
#   $3 — source path: either a real path under REPO_ROOT to copy + stage (so
#        path patterns like ^setup\.sh$ match exactly as on real commits), or
#        the sentinel "README" to stage a synthetic Tier 0 README.md.
make_staged_workspace() {
    local tier="$1" mode="$2" source_arg="$3"
    local tmp; tmp=$(mktemp -d)
    local sid="sid-$(date +%s%N | cut -c-15)-eff"

    (
        cd "$tmp"
        git init -q -b master
        git -c user.email=t@t -c user.name=t commit --allow-empty -m "init" -q
    )

    mkdir -p "$tmp/.intellisense/session"
    printf '%s' "$sid" > "$tmp/.intellisense/session/current-session-id"
    jq -n --arg tier "$tier" --arg mode "$mode" --arg sid "$sid" \
        '{tier: $tier, mode: $mode, session_id: $sid, classification_id: "cls_test_eff", prompt_hash: "eff12345"}' \
        > "$tmp/.intellisense/session/$sid.classification.json"
    jq -n --arg sid "$sid" \
        '{session_id: $sid, skills_used: [], agents_spawned: [], first_prompt_ts: "2026-05-21T00:00:00Z"}' \
        > "$tmp/.intellisense/session/$sid.usage.json"

    case "$source_arg" in
        README)
            echo "# readme" > "$tmp/README.md"
            ( cd "$tmp" && git add README.md )
            ;;
        *)
            if [ ! -f "$REPO_ROOT/$source_arg" ]; then
                echo "FATAL: fixture source $REPO_ROOT/$source_arg missing" >&2
                exit 1
            fi
            local dst="$tmp/$source_arg"
            mkdir -p "$(dirname "$dst")"
            cp "$REPO_ROOT/$source_arg" "$dst"
            ( cd "$tmp" && git add "$source_arg" )
            ;;
    esac

    echo "$tmp $sid"
}

run_hook() {
    local cwd="$1" msg="$2"
    ( cd "$cwd" && bash "$HOOK" "$msg" "message" 2>/dev/null ) || true
}

make_msg() {
    local tmp_msg; tmp_msg=$(mktemp)
    cat > "$tmp_msg" <<'EOF'
test: effective-tier regression fixture
EOF
    echo "$tmp_msg"
}

extract_metadata() {
    local file="$1"
    grep '^Intellisense-Metadata:' "$file" | head -1 | sed 's/^Intellisense-Metadata: //'
}

assert_tier() {
    local label="$1" msg_file="$2" expected="$3"
    local meta actual
    meta=$(extract_metadata "$msg_file")
    if [ -z "$meta" ]; then
        fail "$label: no Intellisense-Metadata trailer emitted"
        return
    fi
    actual=$(echo "$meta" | jq -r '.tier // "<missing>"' 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
        pass "$label: emitted tier=$expected"
    else
        fail "$label: emitted tier=$actual (expected $expected). Full metadata: $meta"
    fi
}

echo "Running test_prepare_commit_msg_effective_tier.sh"
echo "─────────────────────────────────────────"

# ── Case A — RED-then-GREEN ──────────────────────────────────────────────────
# Classifier says tier=0, staged file is setup.sh (Tier 1 per the engine's
# `intellisense classify --tier-only`, via scripts/lib/effective-tier.sh). Pre-fix the hook emits tier=0 (trusts
# classifier verbatim). Post-fix it emits tier=1 (max-composes path-tier in).
echo "=== Case A: classifier tier=0 + staged setup.sh → tier MUST be 1 ==="
read WS SID <<< "$(make_staged_workspace "0" "design_review_only" "setup.sh")"
MSG=$(make_msg)
run_hook "$WS" "$MSG"
assert_tier "Case A" "$MSG" "1"
rm -rf "$WS" "$MSG"

# ── Case B — guard against spurious escalation ───────────────────────────────
# Classifier says tier=0, staged file is a synthetic README.md (Tier 0).
# Composition must NOT escalate. max(0,0,0)=0.
echo "=== Case B: classifier tier=0 + staged README.md → tier MUST stay 0 ==="
read WS SID <<< "$(make_staged_workspace "0" "refactor" "README")"
MSG=$(make_msg)
run_hook "$WS" "$MSG"
assert_tier "Case B" "$MSG" "0"
rm -rf "$WS" "$MSG"

# ── Case C — guard against demotion ──────────────────────────────────────────
# Classifier already correct on a Tier 2 prompt; staged file is benign.
# Composition must preserve the classifier's higher tier. max(2,0,0)=2.
echo "=== Case C: classifier tier=2 + staged README.md → tier MUST stay 2 ==="
read WS SID <<< "$(make_staged_workspace "2" "bug_fix" "README")"
MSG=$(make_msg)
run_hook "$WS" "$MSG"
assert_tier "Case C" "$MSG" "2"
rm -rf "$WS" "$MSG"

echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
