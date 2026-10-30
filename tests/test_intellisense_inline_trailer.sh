#!/usr/bin/env bash
# tests/test_intellisense_inline_trailer.sh
#
# Unit tests for scripts/intellisense-inline-trailer.sh.
#
# The generator PRINTS one `Intellisense-Metadata: <json>` line to stdout for Claude to
# include in `git commit`. It is hooksPath-independent (no hook dependency, no
# file/message mutation; read-only git inspection only).
#
# Contract:
#   - author_type = "claude_inline", stamping_source = "agent_inline",
#     commit_kind = "single"
#   - has session, tier, mode, version; skills/agents/rules_expected when tier!=0
#   - NEVER carries a tokens field (Claude can't compute them)
#   - tier = max(classifier, path_tier, policy); path_tier from staged files
#     (--staged, default) OR a commit ref (--commit <ref>) for amend/ship/repair
#   - no current-session-id  -> emits nothing, exit 0
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$REPO_ROOT/scripts/intellisense-inline-trailer.sh"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "  ✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "  ✓ $*"; }

# Build a temp git repo with seeded intellisense session state.
# Args: sid  tier  mode  skills_json  agents_json
make_repo() {
    local sid="$1" tier="$2" mode="$3" skills="$4" agents="$5"
    local tmp; tmp=$(mktemp -d)
    cd "$tmp" || return 1
    git init -q -b master >/dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test"
    git config commit.gpgsign false 2>/dev/null

    mkdir -p .intellisense/session
    printf '%s' "$sid" > .intellisense/session/current-session-id
    jq -nc --argjson tier "$tier" --arg mode "$mode" \
        '{tier:$tier, mode:$mode, classification_id:"cls_test", prompt_hash:"abc"}' \
        > ".intellisense/session/$sid.classification.json"
    jq -nc --argjson skills "$skills" --argjson agents "$agents" \
        '{skills_used:$skills, agents_spawned:$agents}' \
        > ".intellisense/session/$sid.usage.json"
    printf '%s' "$tmp"
}

# Extract the JSON payload from a `Intellisense-Metadata: {...}` line.
payload_of() { sed 's/^Intellisense-Metadata: //'; }

echo "Test 1: happy path (Tier 0, staged .md) → one well-formed claude_inline line, no tokens"
TMP=$(make_repo "sess-aaa" 0 "design_review_only" '[]' '[]')
cd "$TMP"
echo "doc" > README.md && git add README.md
OUT="$(bash "$GEN" 2>/dev/null)"
NLINES="$(printf '%s' "$OUT" | grep -c '^Intellisense-Metadata: ')"
[ "$NLINES" = "1" ] && pass "exactly one Intellisense-Metadata line" || fail "expected 1 line, got $NLINES (out=$OUT)"
# line-anchored: no leading whitespace
printf '%s\n' "$OUT" | grep -qE '^[[:space:]]+Intellisense-Metadata:' && fail "line has leading whitespace" || pass "line is anchored (no leading whitespace)"
JSON="$(printf '%s' "$OUT" | payload_of)"
echo "$JSON" | jq -e . >/dev/null 2>&1 && pass "payload is valid JSON" || fail "payload not valid JSON: $JSON"
[ "$(echo "$JSON" | jq -r '.author_type')" = "claude_inline" ] && pass "author_type=claude_inline" || fail "author_type wrong"
[ "$(echo "$JSON" | jq -r '.stamping_source')" = "agent_inline" ] && pass "stamping_source=agent_inline" || fail "stamping_source wrong"
[ "$(echo "$JSON" | jq -r '.session')" = "sess-aaa" ] && pass "session present" || fail "session wrong"
[ "$(echo "$JSON" | jq -r '.mode')" = "design_review_only" ] && pass "mode present" || fail "mode wrong"
echo "$JSON" | jq -e 'has("version")' >/dev/null 2>&1 && pass "version present" || fail "version missing"
echo "$JSON" | jq -e 'has("tokens")' >/dev/null 2>&1 && fail "tokens field present (must be absent)" || pass "no tokens field"

echo "Test 2: Tier 1 (staged scripts/*) → tier>=1 and skills/agents/rules_expected present"
TMP=$(make_repo "sess-bbb" 0 "full_feature" '["plan","tdd"]' '[]')
cd "$TMP"
mkdir -p scripts && echo "x" > scripts/foo.sh && git add scripts/foo.sh
JSON="$(bash "$GEN" 2>/dev/null | payload_of)"
T="$(echo "$JSON" | jq -r '.tier')"
[ "$T" -ge 1 ] 2>/dev/null && pass "effective tier >=1 from staged scripts/ (got $T)" || fail "tier not escalated from staged path (got $T)"
echo "$JSON" | jq -e 'has("skills") and has("agents") and has("rules_expected")' >/dev/null 2>&1 \
    && pass "skills/agents/rules_expected present for tier!=0" || fail "tier!=0 fields missing"
[ "$(echo "$JSON" | jq -r '.skills | join(",")')" = "plan,tdd" ] && pass "skills carried from usage.json" || fail "skills wrong"

echo "Test 3: --commit <ref> mode → tier derived from commit diff when nothing staged"
TMP=$(make_repo "sess-ccc" 0 "full_feature" '[]' '[]')
cd "$TMP"
mkdir -p hooks && echo "h" > hooks/some-hook && git add hooks/some-hook
git commit -q -F <(echo "seed") --no-verify 2>/dev/null
# nothing staged now; --commit HEAD should still see hooks/ → tier>=1
JSON="$(bash "$GEN" --commit HEAD 2>/dev/null | payload_of)"
T="$(echo "$JSON" | jq -r '.tier')"
[ "$T" -ge 1 ] 2>/dev/null && pass "--commit HEAD derives tier from commit diff (got $T)" || fail "--commit tier wrong (got $T)"

echo "Test 4: no current-session-id → no output, exit 0"
TMP=$(mktemp -d); cd "$TMP"; git init -q -b master >/dev/null 2>&1
OUT="$(bash "$GEN" 2>/dev/null)"; RC=$?
[ -z "$OUT" ] && [ "$RC" = "0" ] && pass "no session → empty output, exit 0" || fail "expected empty/exit0, got rc=$RC out=$OUT"

echo "Test 5 (P3): jq unavailable → emits nothing (a partial trailer would be validator-rejected)"
TMP=$(make_repo "sess-jq" 0 "design_review_only" '[]' '[]')
cd "$TMP"
echo doc > README.md && git add README.md
OUT="$(INTELLISENSE_TEST_SIMULATE_NO_JQ=1 bash "$GEN" 2>/dev/null)"; RC=$?
[ -z "$OUT" ] && [ "$RC" = "0" ] && pass "jq-missing → empty output, exit 0" || fail "jq-missing emitted (rc=$RC): $OUT"

echo ""
echo "─────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────────────"
[ "$FAIL" -eq 0 ]
