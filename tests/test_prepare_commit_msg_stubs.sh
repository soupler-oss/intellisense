#!/usr/bin/env bash
# tests/test_prepare_commit_msg_stubs.sh
#
# Tests for universal Intellisense-Metadata coverage (stub trailers).
#
# The hook now ALWAYS emits an Intellisense-Metadata trailer; only the content
# differs. Four emission paths exercised here:
#   1. No current-session-id pointer → no_session_signal stub
#   2. Pointer + classification.json missing → claude_with_intellisense + classification_state=missing
#   3. COMMIT_SOURCE=merge → merge stub
#   4. jq not available → degraded trailer with tooling_state=jq_unavailable
#
# Companion to tests/test_prepare_commit_msg.sh (existing positive paths).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/hooks/prepare-commit-msg"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# Helpers (mirror tests/test_prepare_commit_msg.sh patterns)
make_msg() {
    local tmp_msg; tmp_msg=$(mktemp)
    cat > "$tmp_msg" <<'EOF'
test: stub-emission case

Body line.
EOF
    echo "$tmp_msg"
}

count_trailer() {
    local file="$1" key="$2"
    awk -v k="$key" 'BEGIN{n=0} $0 ~ "^"k":" {n++} END{print n}' "$file" 2>/dev/null
}

extract_metadata() {
    local file="$1"
    grep '^Intellisense-Metadata:' "$file" | head -1 | sed 's/^Intellisense-Metadata: //'
}

run_hook() {
    # Args: cwd  msg_path  [commit_source]
    local cwd="$1" msg="$2" src="${3:-message}"
    ( cd "$cwd" && bash "$HOOK" "$msg" "$src" 2>/dev/null ) || true
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case S1: No current-session-id pointer → no_session_signal stub ==="
WS=$(mktemp -d)
mkdir -p "$WS/.intellisense/session"
# Intentionally do NOT write current-session-id
MSG=$(make_msg)
run_hook "$WS" "$MSG"

n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "S1: exactly one Intellisense-Metadata trailer emitted" \
    || fail "S1: $n trailers (expected 1)"

META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.v == 1' >/dev/null 2>&1 \
    && pass "S1: schema version v=2" \
    || fail "S1: v != 2 (got '$META')"
echo "$META" | jq -e '.author_type == "no_session_signal"' >/dev/null 2>&1 \
    && pass "S1: author_type=no_session_signal" \
    || fail "S1: author_type wrong (got $(echo "$META" | jq -r '.author_type'))"
echo "$META" | jq -e '.commit_kind == "single"' >/dev/null 2>&1 \
    && pass "S1: commit_kind=single" \
    || fail "S1: commit_kind wrong"
echo "$META" | jq -e '.stamping_source == "local_hook"' >/dev/null 2>&1 \
    && pass "S1: stamping_source=local_hook" \
    || fail "S1: stamping_source wrong"
# Privacy: dev-stub MUST NOT carry session UUID, cwd, tokens
echo "$META" | jq -e 'has("session") | not' >/dev/null 2>&1 \
    && pass "S1: no session UUID in dev stub (privacy)" \
    || fail "S1: session UUID leaked into dev stub"
echo "$META" | jq -e 'has("tokens") | not' >/dev/null 2>&1 \
    && pass "S1: no token counts in dev stub (privacy)" \
    || fail "S1: tokens leaked into dev stub"
echo "$META" | jq -e 'has("cwd") | not' >/dev/null 2>&1 \
    && pass "S1: no cwd in dev stub (privacy)" \
    || fail "S1: cwd leaked into dev stub"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case S2: Pointer exists, classification.json missing → claude_with_intellisense + classification_state=missing ==="
WS=$(mktemp -d)
mkdir -p "$WS/.intellisense/session"
SID="s2-sid-test-aaaa"
printf '%s' "$SID" > "$WS/.intellisense/session/current-session-id"
# Intentionally NO classification.json
MSG=$(make_msg)
run_hook "$WS" "$MSG"

n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "S2: exactly one Intellisense-Metadata trailer emitted" \
    || fail "S2: $n trailers (expected 1)"

META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.v == 1' >/dev/null 2>&1 \
    && pass "S2: schema version v=2" \
    || fail "S2: v != 2"
echo "$META" | jq -e '.author_type == "claude_with_intellisense"' >/dev/null 2>&1 \
    && pass "S2: author_type=claude_with_intellisense" \
    || fail "S2: author_type wrong"
echo "$META" | jq -e '.classification_state == "missing"' >/dev/null 2>&1 \
    && pass "S2: classification_state=missing" \
    || fail "S2: classification_state wrong (got $(echo "$META" | jq -r '.classification_state'))"
echo "$META" | jq -e '.stamping_source == "local_hook"' >/dev/null 2>&1 \
    && pass "S2: stamping_source=local_hook" \
    || fail "S2: stamping_source wrong"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case S3: COMMIT_SOURCE=merge → merge stub ==="
WS=$(mktemp -d)
mkdir -p "$WS/.intellisense/session"
# Set up a valid session so it would otherwise emit a Claude trailer;
# but COMMIT_SOURCE=merge should override to merge-stub.
SID="s3-sid-test-bbbb"
printf '%s' "$SID" > "$WS/.intellisense/session/current-session-id"
jq -n --arg sid "$SID" '{tier: "0", mode: "design_review_only", session_id: $sid, classification_id: "cls_s3", prompt_hash: "h"}' \
    > "$WS/.intellisense/session/$SID.classification.json"
MSG=$(make_msg)
run_hook "$WS" "$MSG" "merge"

n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "S3: exactly one Intellisense-Metadata trailer emitted on merge" \
    || fail "S3: $n trailers on merge (expected 1)"

META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.v == 1' >/dev/null 2>&1 \
    && pass "S3: schema version v=2" \
    || fail "S3: v != 2"
echo "$META" | jq -e '.author_type == "merge"' >/dev/null 2>&1 \
    && pass "S3: author_type=merge" \
    || fail "S3: author_type wrong (got $(echo "$META" | jq -r '.author_type'))"
echo "$META" | jq -e '.commit_kind == "merge"' >/dev/null 2>&1 \
    && pass "S3: commit_kind=merge" \
    || fail "S3: commit_kind wrong"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case S4: jq not available → degraded trailer with tooling_state=jq_unavailable ==="
WS=$(mktemp -d)
mkdir -p "$WS/.intellisense/session"
SID="s4-sid-test-cccc"
printf '%s' "$SID" > "$WS/.intellisense/session/current-session-id"
jq -n --arg sid "$SID" '{tier: "0", mode: "design_review_only", session_id: $sid, classification_id: "cls_s4", prompt_hash: "h"}' \
    > "$WS/.intellisense/session/$SID.classification.json"
MSG=$(make_msg)
# Hide jq by setting PATH to an empty dir; keep python3, awk, sed, grep available.
HIDE_JQ_DIR=$(mktemp -d)
# Symlink essential tools (NOT jq) into the empty dir
for t in bash sh date cat grep awk sed cp mv mkdir rm head printf python3 git uuidgen mktemp dirname basename readlink chmod ls; do
    real=$(command -v "$t" 2>/dev/null) || true
    [[ -n "$real" ]] && ln -s "$real" "$HIDE_JQ_DIR/$t" 2>/dev/null
done
( cd "$WS" && PATH="$HIDE_JQ_DIR" bash "$HOOK" "$MSG" "message" 2>/dev/null ) || true
rm -rf "$HIDE_JQ_DIR"

n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "S4: exactly one Intellisense-Metadata trailer emitted (degraded, jq missing)" \
    || fail "S4: $n trailers (expected 1)"

META=$(extract_metadata "$MSG")
# Use python3 to parse JSON since jq isn't strictly necessary for verification
echo "$META" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d.get("v")==1, d; assert d.get("tooling_state")=="jq_unavailable", d; assert d.get("classification_state")=="unavailable", d; print("OK")' >/dev/null 2>&1 \
    && pass "S4: degraded trailer is valid JSON with tooling_state=jq_unavailable" \
    || fail "S4: degraded trailer invalid or missing tooling_state (got '$META')"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case S5: no_session_signal stub stamps truthful path-tier ==="
# Staging a hooks/* file (Tier 1) should produce tier:1 in the dev stub,
# NOT tier:0.
WS=$(mktemp -d)
( cd "$WS" && git init -q -b master && git config user.email t@t.com && git config user.name t )
mkdir -p "$WS/.intellisense/session" "$WS/hooks"
# No current-session-id
echo "test" > "$WS/hooks/foo.sh"
( cd "$WS" && git add hooks/foo.sh )
MSG=$(make_msg)
run_hook "$WS" "$MSG"

META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.tier == 1' >/dev/null 2>&1 \
    && pass "S5: staged hooks/foo.sh → tier:1 in dev stub (truthful path-tier)" \
    || fail "S5: tier wrong (got $(echo "$META" | jq -r '.tier')); expected 1 because hooks/* is Tier 1"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case S6: classification.json corrupt → claude_with_intellisense + classification_state=corrupt ==="
WS=$(mktemp -d)
mkdir -p "$WS/.intellisense/session"
SID="s6-sid-corrupt"
printf '%s' "$SID" > "$WS/.intellisense/session/current-session-id"
# classification.json exists but lacks tier and mode (malformed/corrupt)
echo '{"unrelated": "field"}' > "$WS/.intellisense/session/$SID.classification.json"
MSG=$(make_msg)
run_hook "$WS" "$MSG"

n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "S6: exactly one Intellisense-Metadata trailer" \
    || fail "S6: $n trailers (expected 1)"
META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.author_type == "claude_with_intellisense"' >/dev/null 2>&1 \
    && pass "S6: author_type=claude_with_intellisense" \
    || fail "S6: author_type wrong"
echo "$META" | jq -e '.classification_state == "corrupt"' >/dev/null 2>&1 \
    && pass "S6: classification_state=corrupt (not missing, not ok)" \
    || fail "S6: classification_state wrong (got $(echo "$META" | jq -r '.classification_state'))"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case S7: COMMIT_SOURCE=squash → squash stub (NOT merge stub) ==="
WS=$(mktemp -d)
mkdir -p "$WS/.intellisense/session"
SID="s7-sid-squash"
printf '%s' "$SID" > "$WS/.intellisense/session/current-session-id"
jq -n --arg sid "$SID" '{tier: "0", mode: "design_review_only", session_id: $sid, classification_id: "cls_s7", prompt_hash: "h"}' \
    > "$WS/.intellisense/session/$SID.classification.json"
MSG=$(make_msg)
run_hook "$WS" "$MSG" "squash"

META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.author_type == "squash"' >/dev/null 2>&1 \
    && pass "S7: author_type=squash (not 'merge' — these are distinct enum values)" \
    || fail "S7: author_type wrong — squash was conflated with merge (got $(echo "$META" | jq -r '.author_type'))"
echo "$META" | jq -e '.commit_kind == "squash"' >/dev/null 2>&1 \
    && pass "S7: commit_kind=squash" \
    || fail "S7: commit_kind wrong"
rm -rf "$WS" "$MSG"

echo ""
echo "==================================================================="
echo "stub-emission tests: $PASS passed, $FAIL failed"
echo "==================================================================="
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
