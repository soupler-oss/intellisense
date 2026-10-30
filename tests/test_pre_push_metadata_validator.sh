#!/usr/bin/env bash
# tests/test_pre_push_metadata_validator.sh
#
# Tests for intellisense_validate_new_trailer_set: malformed JSON, unknown
# author_type values and unsupported schema versions are rejected.
#
# The validator function lives in hooks/pre-push. We exercise it by:
#   1. Creating a throwaway git repo with a controlled commit
#   2. Sourcing hooks/pre-push as a library (won't execute main flow)
#   3. Calling intellisense_validate_new_trailer_set against the controlled commits
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRE_PUSH="$REPO_ROOT/hooks/pre-push"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# Make a throwaway repo with a baseline commit on master and a feature branch
# with N additional commits whose messages we control.
make_repo() {
    # Returns path to a working repo with a bare "remote" set as origin so
    # origin/master resolves (the validator's range is origin/master..HEAD).
    local tmp; tmp=$(mktemp -d)
    local remote="$tmp/remote.git"
    git init -q --bare -b master "$remote"
    local work="$tmp/work"
    ( cd "$tmp" \
        && git clone -q "$remote" work \
        && cd work \
        && git config user.email t@t.com \
        && git config user.name t \
        && echo init > base.txt \
        && git add base.txt \
        && git commit -q -m "init" \
        && git push -q origin master \
        && git checkout -q -b feat )
    echo "$work"
}

# Append a controlled commit to the current branch with a specific trailer body.
# Args: repo, commit_subject, full_trailer_block (e.g., "Intellisense-Metadata: {...}")
append_commit_with_trailer() {
    local repo="$1" subject="$2" trailer="$3"
    local f="commit-$(date +%s%N)"
    ( cd "$repo" \
        && echo data > "$f" \
        && git add "$f" \
        && git commit -q --allow-empty -m "$(printf '%s\n\nbody\n\n%s' "$subject" "$trailer")" )
}

# Run the validator function and report its exit status + stderr.
# Uses subshell so we can source hooks/pre-push without polluting our env.
# Args: repo, gate_mode (enforced|pilot)
run_validator() {
    local repo="$1" gate_mode="${2:-enforced}"
    ( cd "$repo"
      # Stub the parts of pre-push that require real env so we can just
      # source and call intellisense_validate_new_trailer_set in isolation.
      DEFAULT_BRANCH="master"
      export DEFAULT_BRANCH
      # Source pre-push file but trap its main-flow exit. The function we
      # care about is defined before any top-level exit.
      # Trick: extract just the function using sed.
      sed -n '/^intellisense_validate_new_trailer_set() {/,/^}/p' "$PRE_PUSH" > /tmp/_validator.$$
      # shellcheck disable=SC1090
      source /tmp/_validator.$$
      rm -f /tmp/_validator.$$
      # Provide the gate_mode helper if validator calls one
      # (current validator reads gate_mode from local var; pass via env)
      intellisense_validate_new_trailer_set 2>&1
    )
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case V1: malformed JSON in Intellisense-Metadata → validator flags drift ==="
REPO=$(make_repo)
append_commit_with_trailer "$REPO" "feat: malformed metadata" "Intellisense-Metadata: {not-valid-json"
OUT=$(run_validator "$REPO" enforced)
# Expect either non-zero exit OR explicit "malformed"/"invalid"/"drift" wording in output
echo "$OUT" | grep -qiE 'malformed|invalid|drift|BLOCKED' \
    && pass "V1: malformed JSON metadata is flagged (not silently passed)" \
    || fail "V1: validator silently accepted malformed JSON (output was: $(echo "$OUT" | head -3))"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case V2: unknown author_type → validator flags drift ==="
REPO=$(make_repo)
append_commit_with_trailer "$REPO" "feat: bogus author_type" \
    'Intellisense-Metadata: {"v":1,"author_type":"made_up_value","commit_kind":"single","stamping_source":"local_hook"}'
OUT=$(run_validator "$REPO" enforced)
echo "$OUT" | grep -qiE 'unknown|author_type|drift|BLOCKED' \
    && pass "V2: unknown author_type is flagged" \
    || fail "V2: validator silently accepted unknown author_type (output: $(echo "$OUT" | head -3))"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case V3: valid no_session_signal stub → validator passes ==="
REPO=$(make_repo)
append_commit_with_trailer "$REPO" "feat: valid stub" \
    'Intellisense-Metadata: {"v":1,"author_type":"no_session_signal","commit_kind":"single","stamping_source":"local_hook","tier":0}'
OUT=$(run_validator "$REPO" enforced)
echo "$OUT" | grep -qiE 'malformed|invalid|BLOCKED' \
    && fail "V3: valid stub was incorrectly flagged (output: $(echo "$OUT" | head -3))" \
    || pass "V3: valid no_session_signal stub passes validator"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case V4: unsupported schema version → flagged ==="
REPO=$(make_repo)
append_commit_with_trailer "$REPO" "feat: unknown schema" \
    'Intellisense-Metadata: {"v":7,"author_type":"no_session_signal","commit_kind":"single","stamping_source":"local_hook","tier":0}'
OUT=$(run_validator "$REPO" enforced)
echo "$OUT" | grep -qiE 'unsupported Intellisense-Metadata schema version' \
    && pass "V4: unsupported schema version flagged" \
    || fail "V4: v=7 trailer was accepted (output: $(echo "$OUT" | head -3))"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case V5: valid claude_inline (no tokens) → not flagged ==="
REPO=$(make_repo)
append_commit_with_trailer "$REPO" "feat: inline" \
    'Intellisense-Metadata: {"v":1,"author_type":"claude_inline","commit_kind":"single","stamping_source":"agent_inline","classification_state":"ok","tier":0,"mode":"design_review_only","session":"s","version":"1.0.0"}
Co-Authored-By: Claude <noreply@anthropic.com>'
OUT=$(run_validator "$REPO" enforced)
echo "$OUT" | grep -qiE 'BLOCKED|unknown author_type' \
    && fail "V5: valid claude_inline was flagged (output: $(echo "$OUT" | head -3))" \
    || pass "V5: valid claude_inline (no tokens, with co-author) passes"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case V6: claude_inline carrying tokens → flagged ==="
REPO=$(make_repo)
append_commit_with_trailer "$REPO" "feat: inline w/ tokens" \
    'Intellisense-Metadata: {"v":1,"author_type":"claude_inline","commit_kind":"single","stamping_source":"agent_inline","classification_state":"ok","tier":0,"mode":"design_review_only","session":"s","version":"1.0.0","tokens":{"input":1,"output":1,"cache_creation":0,"cache_read":0,"total":2}}'
OUT=$(run_validator "$REPO" enforced)
echo "$OUT" | grep -qiE 'BLOCKED|token' \
    && pass "V6: claude_inline with tokens is flagged" \
    || fail "V6: tokens-bearing claude_inline not flagged (output: $(echo "$OUT" | head -3))"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case V7: under-stamped inline tier (scripts/* declared Tier 0) → flagged ==="
REPO=$(make_repo)
( cd "$REPO" \
    && mkdir -p scripts && echo "echo hi" > scripts/z.sh && git add scripts/z.sh \
    && git commit -q -m "$(printf 'feat: scripts change\n\nbody\n\nIntellisense-Metadata: %s' '{"v":1,"author_type":"claude_inline","commit_kind":"single","stamping_source":"agent_inline","classification_state":"ok","tier":0,"mode":"design_review_only","session":"s","version":"1.0.0"}')" )
OUT=$(run_validator "$REPO" enforced)
echo "$OUT" | grep -qiE 'BLOCKED|tier' \
    && pass "V7: under-stamped inline tier is flagged" \
    || fail "V7: under-stamped inline tier not flagged (output: $(echo "$OUT" | head -3))"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case V8 (P2-3): claude_inline wrong source values → flagged ==="
REPO=$(make_repo)
append_commit_with_trailer "$REPO" "feat: inline bad source" \
    'Intellisense-Metadata: {"v":1,"author_type":"claude_inline","commit_kind":"merge","stamping_source":"local_hook","classification_state":"ok","tier":0,"mode":"design_review_only","session":"s","version":"1.0.0"}'
OUT=$(run_validator "$REPO" enforced)
echo "$OUT" | grep -qiE 'BLOCKED|commit_kind|stamping_source' \
    && pass "V8: wrong commit_kind/stamping_source flagged" \
    || fail "V8: not flagged (output: $(echo "$OUT" | head -3))"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case V9 (P2-2): inline tier below policy floor → flagged ==="
REPO=$(make_repo)
mkdir -p "$REPO/.intellisense"; echo '{"policy_minimum_tier":1}' > "$REPO/.intellisense/manifest.json"
( cd "$REPO" && git add .intellisense/manifest.json && git commit -q -m "chore: manifest" )
append_commit_with_trailer "$REPO" "docs: normal file" \
    'Intellisense-Metadata: {"v":1,"author_type":"claude_inline","commit_kind":"single","stamping_source":"agent_inline","classification_state":"ok","tier":0,"mode":"design_review_only","session":"s","version":"1.0.0"}'
OUT=$(run_validator "$REPO" enforced)
echo "$OUT" | grep -qiE 'BLOCKED|tier|floor|policy' \
    && pass "V9: inline tier below policy floor flagged" \
    || fail "V9: policy floor not enforced (output: $(echo "$OUT" | head -3))"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case V10: claude_inline w/o Co-Authored-By → flagged (fail-closed) ==="
# Asserts the missing co-author is added to missing_trailers (→ blocks in
# enforced). The exact exit code under this harness is subject to its isolation
# technique (sed-extracts only intellisense_validate_new_trailer_set); the authoritative
# block is verified by the PR validator (test_validate_intellisense_trailers_pr.sh T18, exit 1).
REPO=$(make_repo)
append_commit_with_trailer "$REPO" "feat: inline no coauthor" \
    'Intellisense-Metadata: {"v":1,"author_type":"claude_inline","commit_kind":"single","stamping_source":"agent_inline","classification_state":"ok","tier":0,"mode":"design_review_only","session":"s","version":"1.0.0"}'
OUT=$(run_validator "$REPO" enforced)
echo "$OUT" | grep -qiE 'Co-Authored-By|missing-Co-Authored|BLOCKED' \
    && pass "V10: missing co-author is flagged (fail-closed)" \
    || fail "V10: missing co-author not flagged (output: $(echo "$OUT" | head -3))"
rm -rf "$REPO"

echo ""
echo "==================================================================="
echo "metadata validator tests: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
