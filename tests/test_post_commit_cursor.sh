#!/usr/bin/env bash
# tests/test_post_commit_cursor.sh
#
# Tests for post-commit: hooks/post-commit (Phase 2 of the two-phase token cursor).
#
# Per the plan's post-commit decision tree (updated 2026-05-19 for Intellisense-Metadata JSON):
#   A) Session + Tokens object match expected exactly → promote pending → committed
#   B) Session matches + Tokens object parseable (5 numeric fields) but values
#      differ → promote anyway, log informational drift
#   C) Tokens missing/unparseable OR Session changed → mark corrupted_cursor
#      and DO NOT advance — next intellisense commit blocks even in pilot mode.
#
# Format note: commits now carry a single `Intellisense-Metadata: <json>` trailer.
# The JSON has the shape:
#   {"v":1, "tier":N, "mode":"...", "session":"...", "version":"...",
#    "skills":[...], "rules_expected":[...], "agents":[...],
#    "tokens":{"input":N, "output":N, "cache_creation":N, "cache_read":N, "total":N}}
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/hooks/post-commit"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# Helper: build an Intellisense-Metadata JSON trailer value with the given session
# and token components. Tier defaults to 1 (Tier 0 doesn't change the
# post-commit decision tree, which only inspects .session and .tokens).
metadata_json() {
    local sid="$1" in_tok="$2" out_tok="$3" cc_tok="$4" cr_tok="$5"
    local total=$((in_tok + out_tok + cc_tok + cr_tok))
    jq -nc \
        --arg sid "$sid" \
        --argjson input "$in_tok" \
        --argjson output "$out_tok" \
        --argjson cc "$cc_tok" \
        --argjson cr "$cr_tok" \
        --argjson total "$total" \
        '{v:1, tier:1, mode:"bug_fix", session:$sid, version:"1.0.0",
          skills:["plan"], rules_expected:[], agents:[],
          tokens:{input:$input, output:$output, cache_creation:$cc,
                  cache_read:$cr, total:$total}}'
}

# Helper: build the expected_token_payload object (matches what prepare-commit-msg writes).
expected_tokens_obj() {
    local in_tok="$1" out_tok="$2" cc_tok="$3" cr_tok="$4"
    local total=$((in_tok + out_tok + cc_tok + cr_tok))
    jq -nc \
        --argjson input "$in_tok" \
        --argjson output "$out_tok" \
        --argjson cc "$cc_tok" \
        --argjson cr "$cr_tok" \
        --argjson total "$total" \
        '{input:$input, output:$output, cache_creation:$cc,
          cache_read:$cr, total:$total}'
}

# Build a real git repo with a controlled HEAD commit message and a cursor file.
# Args: sid  commit_msg_body  expected_session  expected_tokens_json
make_repo() {
    local sid="$1" body="$2" exp_session="$3" exp_tokens_json="$4"
    local tmp; tmp=$(mktemp -d)
    cd "$tmp"
    git init -q -b master >/dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false 2>/dev/null

    mkdir -p .intellisense/session
    printf '%s' "$sid" > .intellisense/session/current-session-id

    # Seed a cursor file with a pending_cursor (expected_token_payload is now JSON object)
    jq -n \
        --arg sid "$sid" \
        --arg exp_session "$exp_session" \
        --argjson exp_tokens "$exp_tokens_json" \
        '{
            session_id: $sid,
            committed_cursor: {last_processed_id: "old-cursor-id", tokens_consumed_pre_cursor: 100},
            pending_cursor: {
                last_processed_id: "new-cursor-id",
                tokens_consumed_pre_cursor: 200,
                expected_session: $exp_session,
                expected_token_payload: $exp_tokens,
                nonce: "test-nonce",
                prepared_at: "2026-05-19T04:00:00Z"
            }
        }' > ".intellisense/session/$sid.token-cursor.json"

    echo "dummy" > dummy.txt
    git add dummy.txt
    git commit -q -F <(echo "$body") --no-verify 2>/dev/null

    echo "$tmp"
}

run_post_commit() {
    local repo="$1"
    ( cd "$repo" && bash "$HOOK" 2>/dev/null ) || true
}

read_cursor_field() {
    local repo="$1" sid="$2" path="$3"
    jq -r "$path" "$repo/.intellisense/session/$sid.token-cursor.json" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case A: Clean match → cursor promoted ==="
SID="sid-clean-aaa"
META=$(metadata_json "$SID" 100 50 30 20)
EXP_TOK=$(expected_tokens_obj 100 50 30 20)
MSG="fix: clean commit

Intellisense-Metadata: $META"
REPO=$(make_repo "$SID" "$MSG" "$SID" "$EXP_TOK")
run_post_commit "$REPO"

committed_id=$(read_cursor_field "$REPO" "$SID" '.committed_cursor.last_processed_id')
committed_tokens=$(read_cursor_field "$REPO" "$SID" '.committed_cursor.tokens_consumed_pre_cursor')
pending_present=$(read_cursor_field "$REPO" "$SID" '.pending_cursor // empty')
corrupted_present=$(read_cursor_field "$REPO" "$SID" '.corrupted_cursor // empty')

[[ "$committed_id" == "new-cursor-id" ]] && pass "Case A: committed_cursor.last_processed_id advanced" || fail "Case A: last_processed_id is '$committed_id', expected 'new-cursor-id'"
[[ "$committed_tokens" == "200" ]] && pass "Case A: committed_cursor.tokens_consumed_pre_cursor advanced" || fail "Case A: tokens is '$committed_tokens', expected 200"
[[ -z "$pending_present" ]] && pass "Case A: pending_cursor cleared" || fail "Case A: pending_cursor still present"
[[ -z "$corrupted_present" ]] && pass "Case A: no corrupted_cursor" || fail "Case A: corrupted_cursor unexpectedly present"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case B: Session matches, token parseable but values differ ==="
SID="sid-driftB-bbb"
# Final commit shows different token totals (dev edited tokens object in $EDITOR)
META=$(metadata_json "$SID" 1 1 1 1)        # final: 1/1/1/1 (total=4)
EXP_TOK=$(expected_tokens_obj 100 50 30 20) # expected: 100/50/30/20 (total=200)
MSG="fix: dev edited token

Intellisense-Metadata: $META"
REPO=$(make_repo "$SID" "$MSG" "$SID" "$EXP_TOK")
run_post_commit "$REPO"

committed_id=$(read_cursor_field "$REPO" "$SID" '.committed_cursor.last_processed_id')
pending_present=$(read_cursor_field "$REPO" "$SID" '.pending_cursor // empty')
corrupted_present=$(read_cursor_field "$REPO" "$SID" '.corrupted_cursor // empty')

[[ "$committed_id" == "new-cursor-id" ]] && pass "Case B: cursor still advances (trust the final committed token)" || fail "Case B: cursor did not advance ('$committed_id')"
[[ -z "$pending_present" ]] && pass "Case B: pending_cursor cleared" || fail "Case B: pending still present"
[[ -z "$corrupted_present" ]] && pass "Case B: no corrupted_cursor (drift is informational)" || fail "Case B: corrupted_cursor wrongly set"
if [[ -f "$HOME/.claude-intellisense/cursor-conflicts.log" ]]; then
    tail -5 "$HOME/.claude-intellisense/cursor-conflicts.log" | grep -q 'informational drift' && pass "Case B: informational drift logged" || fail "Case B: no drift log entry"
fi
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case C: Intellisense-Metadata trailer entirely missing → corruption ==="
SID="sid-corrupt-ccc"
EXP_TOK=$(expected_tokens_obj 100 50 30 20)
MSG="fix: trailer hand-removed

(no Intellisense-Metadata line at all)"
REPO=$(make_repo "$SID" "$MSG" "$SID" "$EXP_TOK")
run_post_commit "$REPO"

committed_id=$(read_cursor_field "$REPO" "$SID" '.committed_cursor.last_processed_id')
pending_present=$(read_cursor_field "$REPO" "$SID" '.pending_cursor // empty')
corrupted_present=$(read_cursor_field "$REPO" "$SID" '.corrupted_cursor // empty')

[[ "$committed_id" == "old-cursor-id" ]] && pass "Case C: committed_cursor unchanged (no advance on corruption)" || fail "Case C: cursor advanced ('$committed_id')"
[[ -n "$corrupted_present" ]] && pass "Case C: corrupted_cursor marked" || fail "Case C: corrupted_cursor not marked"
[[ -z "$pending_present" ]] && pass "Case C: pending_cursor moved out (to corrupted)" || fail "Case C: pending still present"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case C2: Intellisense-Metadata present but tokens object missing fields → corruption ==="
SID="sid-bad-tokens-fff"
EXP_TOK=$(expected_tokens_obj 100 50 30 20)
# Build a trailer with tokens object missing cache_creation
BAD_META=$(jq -nc \
    --arg sid "$SID" \
    '{v:1, tier:1, mode:"bug_fix", session:$sid, version:"1.0.0",
      skills:[], rules_expected:[], agents:[],
      tokens:{input:1, output:1, total:2}}')   # missing cache_creation, cache_read
MSG="fix: incomplete tokens object

Intellisense-Metadata: $BAD_META"
REPO=$(make_repo "$SID" "$MSG" "$SID" "$EXP_TOK")
run_post_commit "$REPO"

committed_id=$(read_cursor_field "$REPO" "$SID" '.committed_cursor.last_processed_id')
corrupted_present=$(read_cursor_field "$REPO" "$SID" '.corrupted_cursor // empty')

[[ "$committed_id" == "old-cursor-id" ]] && pass "Case C2: cursor unchanged when tokens object incomplete" || fail "Case C2: cursor advanced unexpectedly"
[[ -n "$corrupted_present" ]] && pass "Case C2: corrupted_cursor marked" || fail "Case C2: no corruption flag"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case C': Intellisense-Metadata.session changed (dev edited session value) → corruption ==="
SID="sid-sess-changed-ddd"
META=$(metadata_json "SOMETHING-ELSE" 100 50 30 20)
EXP_TOK=$(expected_tokens_obj 100 50 30 20)
MSG="fix: session value tampered

Intellisense-Metadata: $META"
REPO=$(make_repo "$SID" "$MSG" "$SID" "$EXP_TOK")
run_post_commit "$REPO"

committed_id=$(read_cursor_field "$REPO" "$SID" '.committed_cursor.last_processed_id')
corrupted_present=$(read_cursor_field "$REPO" "$SID" '.corrupted_cursor // empty')

[[ "$committed_id" == "old-cursor-id" ]] && pass "Case C': committed_cursor unchanged" || fail "Case C': cursor advanced unexpectedly"
[[ -n "$corrupted_present" ]] && pass "Case C': corrupted_cursor marked" || fail "Case C': no corruption flag"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case E: claude_inline final (no tokens) + stale pending → no-op, NO corruption ==="
# Hook-absent path: prepare-commit-msg did NOT run for this commit, so the
# trailer is an agent-written claude_inline (no tokens). A stale pending_cursor
# from a prior commit must NOT be turned into corrupted_cursor just because the
# inline trailer lacks tokens — post-commit no-ops on non-claude_with_intellisense.
SID="sid-inline-ggg"
EXP_TOK=$(expected_tokens_obj 100 50 30 20)
INLINE=$(jq -nc --arg sid "$SID" \
    '{v:1, author_type:"claude_inline", commit_kind:"single", stamping_source:"agent_inline",
      classification_state:"ok", tier:0, mode:"design_review_only", session:$sid, version:"1.0.0"}')
MSG="fix: inline-stamped (hook absent)

Intellisense-Metadata: $INLINE"
REPO=$(make_repo "$SID" "$MSG" "$SID" "$EXP_TOK")
run_post_commit "$REPO"

committed_id=$(read_cursor_field "$REPO" "$SID" '.committed_cursor.last_processed_id')
corrupted_present=$(read_cursor_field "$REPO" "$SID" '.corrupted_cursor // empty')
pending_present=$(read_cursor_field "$REPO" "$SID" '.pending_cursor // empty')

[[ -z "$corrupted_present" ]] && pass "Case E: no corrupted_cursor for claude_inline final" || fail "Case E: corrupted_cursor wrongly set"
[[ "$committed_id" == "old-cursor-id" ]] && pass "Case E: committed_cursor unchanged (no false promote)" || fail "Case E: cursor advanced ('$committed_id')"
[[ -n "$pending_present" ]] && pass "Case E: pending_cursor left intact (no-op)" || fail "Case E: pending_cursor disturbed"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case D: No cursor file → silent no-op ==="
# Real scenario: a commit happens without any prepare-commit-msg having run
# (e.g. before prepare-commit-msg was installed, or in a non-intellisense repo).
SID="sid-nocursor-eee"
MSG="fix: pre-intellisense commit

(no trailers)"
tmp=$(mktemp -d)
cd "$tmp"
git init -q -b master >/dev/null 2>&1
git config user.email "test@example.com"
git config user.name "Test"
mkdir -p .intellisense/session
printf '%s' "$SID" > .intellisense/session/current-session-id
# Note: NO cursor file at all
echo "dummy" > dummy.txt
git add dummy.txt
git commit -q -m "$MSG" --no-verify
( cd "$tmp" && bash "$HOOK" 2>/dev/null ) || true
[[ ! -f "$tmp/.intellisense/session/$SID.token-cursor.json" ]] && pass "Case D: no-op when cursor file missing" || fail "Case D: cursor file unexpectedly created"
rm -rf "$tmp"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
