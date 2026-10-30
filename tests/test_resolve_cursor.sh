#!/usr/bin/env bash
# tests/test_resolve_cursor.sh
#
# Tests for `bash setup.sh --resolve-cursor` — the recovery path post-commit references
# when it marks a token cursor as corrupted. Before this flag existed, devs
# who hit corruption were told to run a command that didn't work.
#
# Resolution modes:
#   trust-final → corrupted_cursor → committed_cursor (accept dev's edits as
#                  the new attribution truth)
#   reset       → discard corrupted_cursor entirely; next commit re-attributes
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# Build a minimal git-repo workspace with an active session that has a
# corrupted_cursor in its token-cursor.json.
make_corrupted_workspace() {
    local tmp
    tmp=$(mktemp -d)
    cd "$tmp"
    git init -q -b master >/dev/null 2>&1
    git config user.email "t@e.com"; git config user.name "T"
    mkdir -p .intellisense/session
    local sid="sid-resolve-test"
    printf '%s' "$sid" > .intellisense/session/current-session-id
    jq -n --arg sid "$sid" '{
        session_id: $sid,
        committed_cursor: {last_processed_id: "old-id", tokens_consumed_pre_cursor: 100},
        corrupted_cursor: {
            last_processed_id: "corrupted-id",
            tokens_consumed_pre_cursor: 999,
            expected_session: $sid,
            expected_token_payload: {input: 1, output: 1, cache_creation: 1, cache_read: 1, total: 4},
            nonce: "test-nonce",
            prepared_at: "2026-05-19T04:00:00Z"
        }
    }' > ".intellisense/session/$sid.token-cursor.json"
    echo "$tmp"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 1: trust-final → corrupted_cursor promoted to committed_cursor ==="
WS=$(make_corrupted_workspace)
( cd "$WS" && bash "$SETUP" --resolve-cursor trust-final --non-interactive >/dev/null 2>&1 )
SID="sid-resolve-test"

committed=$(jq -r '.committed_cursor.last_processed_id' "$WS/.intellisense/session/$SID.token-cursor.json")
tokens=$(jq -r '.committed_cursor.tokens_consumed_pre_cursor' "$WS/.intellisense/session/$SID.token-cursor.json")
corrupt=$(jq -r '.corrupted_cursor // empty' "$WS/.intellisense/session/$SID.token-cursor.json")

[[ "$committed" == "corrupted-id" ]] && pass "trust-final: committed.last_processed_id = corrupted_cursor's value" \
    || fail "trust-final: committed = '$committed' (expected 'corrupted-id')"
[[ "$tokens" == "999" ]] && pass "trust-final: committed.tokens_consumed_pre_cursor = corrupted's 999" \
    || fail "trust-final: tokens = '$tokens' (expected 999)"
[[ -z "$corrupt" ]] && pass "trust-final: corrupted_cursor cleared" \
    || fail "trust-final: corrupted_cursor still present"
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 2: reset → corrupted_cursor discarded, committed unchanged ==="
WS=$(make_corrupted_workspace)
( cd "$WS" && bash "$SETUP" --resolve-cursor reset --non-interactive >/dev/null 2>&1 )
SID="sid-resolve-test"

committed=$(jq -r '.committed_cursor.last_processed_id' "$WS/.intellisense/session/$SID.token-cursor.json")
tokens=$(jq -r '.committed_cursor.tokens_consumed_pre_cursor' "$WS/.intellisense/session/$SID.token-cursor.json")
corrupt=$(jq -r '.corrupted_cursor // empty' "$WS/.intellisense/session/$SID.token-cursor.json")

[[ "$committed" == "old-id" ]] && pass "reset: committed.last_processed_id unchanged" \
    || fail "reset: committed = '$committed' (expected 'old-id')"
[[ "$tokens" == "100" ]] && pass "reset: committed.tokens unchanged" \
    || fail "reset: tokens = '$tokens' (expected 100)"
[[ -z "$corrupt" ]] && pass "reset: corrupted_cursor cleared" \
    || fail "reset: corrupted_cursor still present"
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 3: no corrupted_cursor → idempotent no-op, exit 0 ==="
WS=$(make_corrupted_workspace)
SID="sid-resolve-test"
# Strip the corruption first, then verify resolve-cursor is a no-op
jq 'del(.corrupted_cursor)' "$WS/.intellisense/session/$SID.token-cursor.json" > "$WS/.intellisense/session/$SID.token-cursor.json.tmp"
mv "$WS/.intellisense/session/$SID.token-cursor.json.tmp" "$WS/.intellisense/session/$SID.token-cursor.json"

before=$(jq -c . "$WS/.intellisense/session/$SID.token-cursor.json")
out=$( ( cd "$WS" && bash "$SETUP" --resolve-cursor trust-final --non-interactive 2>&1 ) )
rc=$?
after=$(jq -c . "$WS/.intellisense/session/$SID.token-cursor.json")

[[ "$rc" == "0" ]] && pass "no-corruption: exit 0" || fail "no-corruption: exit $rc"
echo "$out" | grep -qi 'nothing to resolve\|healthy' && pass "no-corruption: friendly message" || fail "no-corruption: message was '$out'"
[[ "$before" == "$after" ]] && pass "no-corruption: file unchanged" || fail "no-corruption: file mutated"
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 4: non-interactive without resolution arg → error, exit non-zero ==="
WS=$(make_corrupted_workspace)
out=$( ( cd "$WS" && bash "$SETUP" --resolve-cursor --non-interactive 2>&1 ) )
rc=$?

[[ "$rc" -ne 0 ]] && pass "missing-arg: non-zero exit" || fail "missing-arg: exit was 0"
echo "$out" | grep -qi 'non-interactive\|trust-final\|reset' && pass "missing-arg: error mentions the choices" \
    || fail "missing-arg: error doesn't mention choices: '$out'"
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 5: --resolve-cursor outside a git repo → error ==="
WS=$(mktemp -d)
out=$( ( cd "$WS" && bash "$SETUP" --resolve-cursor trust-final --non-interactive 2>&1 ) )
rc=$?
[[ "$rc" -ne 0 ]] && pass "no-git-repo: non-zero exit" || fail "no-git-repo: exit was 0"
echo "$out" | grep -qi 'git repo\|not a git' && pass "no-git-repo: error explains why" \
    || fail "no-git-repo: error was '$out'"
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
