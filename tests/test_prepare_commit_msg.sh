#!/usr/bin/env bash
# tests/test_prepare_commit_msg.sh
#
# Tests for hooks/prepare-commit-msg
#
# Covers the trailer contract:
# - All intellisense commits emit a single Intellisense-Metadata: <json> trailer
# - Tier 0 JSON: {v,tier,mode,session,version,tokens{input,output,cache_creation,cache_read,total}}
# - Tier 1/2 JSON: same + {skills, rules_expected, agents}
# - No-session → no trailer at all (legitimate non-intellisense commit)
# - Strip-and-replace (idempotent on amend / re-commit)
# - Existing non-intellisense trailers (task trailers, Change Contract:, Co-Authored-By:) preserved
# - Pending cursor written for post-commit to validate (expected_token_payload is JSON object)
# - corrupted_cursor blocks prepare-commit-msg
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK="$REPO_ROOT/hooks/prepare-commit-msg"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# Build a mock workspace with:
#   .intellisense/session/current-session-id    → SID
#   .intellisense/session/SID.classification.json → {tier, mode, session_id}
#   .intellisense/session/SID.usage.json        → {skills_used, agents_spawned}
# Args: tier mode skills_csv agents_csv [no_session_pointer]
make_workspace() {
    local tier="$1" mode="$2" skills_csv="$3" agents_csv="$4" skip_pointer="${5:-}"
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/.intellisense/session"
    local sid="sid-$(date +%s%N | cut -c-15)-test"

    [[ -z "$skip_pointer" ]] && printf '%s' "$sid" > "$tmp/.intellisense/session/current-session-id"

    if [[ "$tier" != "ABSENT" ]]; then
        jq -n --arg tier "$tier" --arg mode "$mode" --arg sid "$sid" \
            '{tier: $tier, mode: $mode, session_id: $sid, classification_id: "cls_test_xxx", prompt_hash: "abc12345"}' \
            > "$tmp/.intellisense/session/$sid.classification.json"
    fi

    # Build skills/agents arrays
    local skills_json='[]' agents_json='[]'
    if [[ -n "$skills_csv" ]]; then
        skills_json=$(echo "$skills_csv" | jq -R 'split(",")')
    fi
    if [[ -n "$agents_csv" ]]; then
        agents_json=$(echo "$agents_csv" | jq -R 'split(",")')
    fi
    jq -n --argjson s "$skills_json" --argjson a "$agents_json" --arg sid "$sid" \
        '{session_id: $sid, skills_used: $s, agents_spawned: $a, first_prompt_ts: "2026-05-19T04:00:00Z"}' \
        > "$tmp/.intellisense/session/$sid.usage.json"

    echo "$tmp $sid"
}

# Run the hook against a prepared commit-message file.
# Args: cwd  msg_path  (msg_source = "message" assumed)
run_hook() {
    local cwd="$1" msg="$2"
    ( cd "$cwd" && bash "$HOOK" "$msg" "message" 2>/dev/null ) || true
}

# Build a baseline commit message (mimics what git would write into COMMIT_EDITMSG)
make_msg() {
    local tmp_msg; tmp_msg=$(mktemp)
    cat > "$tmp_msg" <<'EOF'
test: dummy commit subject

This is the body of the commit.
EOF
    echo "$tmp_msg"
}

# Helper: count occurrences of a trailer key in a file.
# Uses awk so we get exactly one stdout integer regardless of match count.
count_trailer() {
    local file="$1" key="$2"
    awk -v k="$key" 'BEGIN{n=0} $0 ~ "^"k":" {n++} END{print n}' "$file" 2>/dev/null
}

# Extract the Intellisense-Metadata JSON value from a commit-message file (first match).
extract_metadata() {
    local file="$1"
    grep '^Intellisense-Metadata:' "$file" | head -1 | sed 's/^Intellisense-Metadata: //'
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 1: Tier 1 commit → single Intellisense-Metadata JSON trailer (full fields) ==="
read WS SID <<< "$(make_workspace "1" "bug_fix" "plan,tdd" "Explore,Plan")"
MSG=$(make_msg)
run_hook "$WS" "$MSG"

n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "Tier 1: exactly one Intellisense-Metadata line" || fail "Tier 1: $n Intellisense-Metadata lines (expected 1)"

META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.v == 1' >/dev/null 2>&1 && pass "Tier 1: schema version v=1" || fail "Tier 1: v != 1 (got '$META')"
echo "$META" | jq -e '.tier == 1' >/dev/null 2>&1 && pass "Tier 1: tier=1" || fail "Tier 1: tier wrong"
echo "$META" | jq -e '.mode == "bug_fix"' >/dev/null 2>&1 && pass "Tier 1: mode=bug_fix" || fail "Tier 1: mode wrong"
echo "$META" | jq -e '.session != null and (.session | length > 0)' >/dev/null 2>&1 && pass "Tier 1: session present" || fail "Tier 1: session missing"
echo "$META" | jq -e '.version != null' >/dev/null 2>&1 && pass "Tier 1: version present" || fail "Tier 1: version missing"
echo "$META" | jq -e '.skills == ["plan","tdd"]' >/dev/null 2>&1 && pass "Tier 1: skills=[plan,tdd]" || fail "Tier 1: skills wrong"
echo "$META" | jq -e '.agents == ["Explore","Plan"]' >/dev/null 2>&1 && pass "Tier 1: agents=[Explore,Plan]" || fail "Tier 1: agents wrong"
echo "$META" | jq -e '.rules_expected | type == "array"' >/dev/null 2>&1 && pass "Tier 1: rules_expected is array" || fail "Tier 1: rules_expected missing/wrong type"
# Token sub-fields — all 5 numbers
for tf in input output cache_creation cache_read total; do
    echo "$META" | jq -e --arg f "$tf" '.tokens[$f] | type == "number"' >/dev/null 2>&1 \
        && pass "Tier 1: tokens.$tf is number" \
        || fail "Tier 1: tokens.$tf missing or not a number"
done
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 2: Tier 0 commit → Intellisense-Metadata WITHOUT skills/rules_expected/agents ==="
read WS SID <<< "$(make_workspace "0" "refactor" "" "")"
MSG=$(make_msg)
run_hook "$WS" "$MSG"

n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "Tier 0: exactly one Intellisense-Metadata line" || fail "Tier 0: $n Intellisense-Metadata lines (expected 1)"

META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.tier == 0' >/dev/null 2>&1 && pass "Tier 0: tier=0" || fail "Tier 0: tier wrong"
echo "$META" | jq -e 'has("skills") | not' >/dev/null 2>&1 && pass "Tier 0: skills field omitted" || fail "Tier 0: skills field present"
echo "$META" | jq -e 'has("rules_expected") | not' >/dev/null 2>&1 && pass "Tier 0: rules_expected omitted" || fail "Tier 0: rules_expected present"
echo "$META" | jq -e 'has("agents") | not' >/dev/null 2>&1 && pass "Tier 0: agents field omitted" || fail "Tier 0: agents field present"
# Tokens still required even on Tier 0
for tf in input output cache_creation cache_read total; do
    echo "$META" | jq -e --arg f "$tf" '.tokens[$f] | type == "number"' >/dev/null 2>&1 \
        && pass "Tier 0: tokens.$tf is number" \
        || fail "Tier 0: tokens.$tf missing"
done
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 3: No active session → no_session_signal stub trailer ==="
# Every commit on
# an intellisense machine carries SOME trailer; no-session means author_type=no_session_signal.
read WS SID <<< "$(make_workspace "1" "bug_fix" "" "" "no_pointer")"
MSG=$(make_msg)
err_out=$( ( cd "$WS" && bash "$HOOK" "$MSG" "message" 2>&1 1>/dev/null ) || true )

n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "No-session: exactly one Intellisense-Metadata stub trailer" || fail "No-session: expected 1 stub, got $n trailers"
META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.author_type == "no_session_signal"' >/dev/null 2>&1 \
    && pass "No-session: author_type=no_session_signal" \
    || fail "No-session: author_type wrong (got '$META')"
[[ -z "$err_out" ]] && pass "No-session: no stderr warning" || fail "No-session: unexpected stderr '$err_out'"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 4: Pointer + classification.json missing → claude_with_intellisense + classification_state=missing stub ==="
# Emit a
# stub trailer with classification_state=missing, still log drift to stderr.
read WS SID <<< "$(make_workspace "ABSENT" "bug_fix" "" "")"
echo "ghost-session-id" > "$WS/.intellisense/session/current-session-id"
MSG=$(make_msg)
err_out=$( ( cd "$WS" && bash "$HOOK" "$MSG" "message" 2>&1 1>/dev/null ) || true )

n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "Classification-missing: exactly one stub trailer" || fail "Classification-missing: expected 1 stub, got $n"
META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.author_type == "claude_with_intellisense" and .classification_state == "missing"' >/dev/null 2>&1 \
    && pass "Classification-missing: author_type=claude_with_intellisense + classification_state=missing" \
    || fail "Classification-missing: wrong stub (got '$META')"
echo "$err_out" | grep -qi 'classif\|missing\|degraded' && pass "Classification-missing: drift warning still printed" || fail "Classification-missing: expected drift warning, got '$err_out'"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 5: Idempotency — running twice doesn't duplicate ==="
read WS SID <<< "$(make_workspace "1" "full_feature" "plan,tdd" "Explore")"
MSG=$(make_msg)
run_hook "$WS" "$MSG"
run_hook "$WS" "$MSG"

n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "Idempotency: exactly one Intellisense-Metadata after 2 runs" || fail "Idempotency: $n Intellisense-Metadata lines after 2 runs"
META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.tier == 1 and .mode == "full_feature"' >/dev/null 2>&1 \
    && pass "Idempotency: metadata still valid" || fail "Idempotency: metadata corrupted"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 6: Strip-and-replace — stale Intellisense-Metadata gets refreshed ==="
read WS SID <<< "$(make_workspace "1" "full_feature" "plan" "")"
MSG=$(make_msg)
# Pre-seed message with a STALE Intellisense-Metadata trailer
cat >> "$MSG" <<'EOF'

Intellisense-Metadata: {"v":1,"author_type":"claude_with_intellisense","commit_kind":"single","stamping_source":"local_hook","classification_state":"ok","tier":1,"mode":"STALE","session":"stale-sid","version":"0.0.0","tokens":{"input":99999,"output":99999,"cache_creation":99999,"cache_read":99999,"total":399996}}
EOF
run_hook "$WS" "$MSG"

n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "Strip-and-replace: exactly one Intellisense-Metadata line" || fail "Strip-and-replace: $n lines"
! grep -q '"STALE"' "$MSG" && pass "Strip-and-replace: stale mode removed" || fail "Strip-and-replace: stale 'STALE' still present"
! grep -q 'stale-sid' "$MSG" && pass "Strip-and-replace: stale session removed" || fail "Strip-and-replace: stale 'stale-sid' still present"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 7: Other trailers preserved (task trailer, Change Contract, Co-Authored-By) ==="
read WS SID <<< "$(make_workspace "1" "bug_fix" "plan" "Explore")"
MSG=$(make_msg)
cat >> "$MSG" <<'EOF'

Refs: #123
Change Contract: files_affected=2, estimated_lines=80, confidence=0.88, risk=medium
Co-Authored-By: Some Other Author <other@example.com>
EOF
run_hook "$WS" "$MSG"

grep -q '^Refs: #123$' "$MSG" && pass "task trailer preserved" || fail "task trailer was stripped"
grep -q '^Change Contract: ' "$MSG" && pass "Change Contract trailer preserved" || fail "Change Contract was stripped"
grep -q '^Co-Authored-By: Some Other Author' "$MSG" && pass "Co-Authored-By preserved" || fail "Co-Authored-By was stripped"
n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "Intellisense-Metadata still emitted alongside other trailers" || fail "Intellisense-Metadata missing"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 7b: prepare-commit-msg BLOCKS when corrupted_cursor is present ==="
read WS SID <<< "$(make_workspace "1" "bug_fix" "plan" "")"
jq -n --arg sid "$SID" '{
    session_id: $sid,
    committed_cursor: {last_processed_id: "old-id", tokens_consumed_pre_cursor: 100},
    corrupted_cursor: {
        last_processed_id: "stale-id",
        tokens_consumed_pre_cursor: 999,
        expected_session: $sid,
        expected_token_payload: {input:0, output:0, cache_creation:0, cache_read:0, total:0},
        nonce: "test-nonce",
        prepared_at: "2026-05-19T00:00:00Z"
    }
}' > "$WS/.intellisense/session/$SID.token-cursor.json"

MSG=$(make_msg)
err_out=$( ( cd "$WS" && bash "$HOOK" "$MSG" "message" ) 2>&1 1>/dev/null )
exit_code=$?

[[ "$exit_code" == "1" ]] && pass "prepare-commit-msg exits 1 when corrupted_cursor present" || fail "prepare-commit-msg exited $exit_code (expected 1)"
echo "$err_out" | grep -qi 'corrupted\|blocked' && pass "clear error message printed" || fail "error message missing/wrong: '$err_out'"
n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "0" ]] && pass "no trailers injected" || fail "trailers injected despite block ($n)"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 8: Pending cursor is written for post-commit to validate (JSON token payload) ==="
read WS SID <<< "$(make_workspace "1" "full_feature" "plan" "")"
MSG=$(make_msg)
run_hook "$WS" "$MSG"

CURSOR_FILE="$WS/.intellisense/session/$SID.token-cursor.json"
if [[ -f "$CURSOR_FILE" ]]; then
    pass "Cursor file created"
    es=$(jq -r '.pending_cursor.expected_session // empty' "$CURSOR_FILE")
    [[ "$es" == "$SID" ]] && pass "pending_cursor.expected_session matches active session" || fail "expected_session: '$es'"
    # expected_token_payload must be an OBJECT now (not a string)
    payload_type=$(jq -r '.pending_cursor.expected_token_payload | type' "$CURSOR_FILE")
    [[ "$payload_type" == "object" ]] && pass "expected_token_payload is JSON object" || fail "expected_token_payload type: '$payload_type'"
    # And it should have all 5 numeric sub-fields
    for tf in input output cache_creation cache_read total; do
        jq -e --arg f "$tf" '.pending_cursor.expected_token_payload[$f] | type == "number"' \
            "$CURSOR_FILE" >/dev/null 2>&1 \
            && pass "expected_token_payload.$tf is number" \
            || fail "expected_token_payload.$tf missing/wrong type"
    done
else
    fail "Cursor file was not created"
fi
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 9: routing.escalations[] trailer preserves event_id / ts / reason ==="
# Seed a routing.jsonl whose events carry the new hotfix fields. Assert the
# trailer's routing.escalations[] passes them through (a stripped ts
# and reason; cross-channel dedup needs event_id stable across channels).
read WS SID <<< "$(make_workspace "2" "full_feature" "plan" "Explore")"
ROUTING_FILE="$WS/.intellisense/session/$SID.routing.jsonl"
cat > "$ROUTING_FILE" <<EOF
{"event_id":"abc123def4567890","ts":"2026-06-01T10:00:00Z","kind":"escalation","from_tier":0,"to_tier":2,"trigger":"path_pattern","reason":"financial","phase":"implement"}
{"event_id":"deadbeef00000001","ts":"2026-06-01T10:05:00Z","kind":"escalation","from_tier":0,"to_tier":2,"trigger":"path_pattern","reason":"auth/identity","phase":"implement"}
EOF
MSG=$(make_msg)
run_hook "$WS" "$MSG"
META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.routing.escalations | length == 2' >/dev/null 2>&1 && pass "routing.escalations has 2 entries" || fail "routing.escalations missing/wrong length"
echo "$META" | jq -e '.routing.escalations[0].event_id == "abc123def4567890"' >/dev/null 2>&1 && pass "trailer preserves event_id" || fail "trailer dropped event_id (got: $(echo "$META" | jq -c '.routing.escalations[0]'))"
echo "$META" | jq -e '.routing.escalations[0].ts == "2026-06-01T10:00:00Z"' >/dev/null 2>&1 && pass "trailer preserves ts" || fail "trailer dropped ts"
echo "$META" | jq -e '.routing.escalations[0].reason == "financial"' >/dev/null 2>&1 && pass "trailer preserves reason" || fail "trailer dropped reason"
echo "$META" | jq -e '.routing.escalations[1].reason == "auth/identity"' >/dev/null 2>&1 && pass "second escalation reason preserved" || fail "second reason dropped"
# from_tier / to_tier / trigger / phase still present (regression guard)
echo "$META" | jq -e '.routing.escalations[0].from_tier == 0 and .routing.escalations[0].to_tier == 2 and .routing.escalations[0].trigger == "path_pattern" and .routing.escalations[0].phase == "implement"' >/dev/null 2>&1 && pass "original fields still present" || fail "original fields regressed"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case INT: pre-existing claude_inline trailer is stripped → exactly one claude_with_intellisense when hook runs ==="
# The 'exactly one trailer' guarantee: when the hook DOES run on a message that
# already carries Claude's inline trailer, STRIP_REGEX removes it and the hook
# writes one accurate claude_with_intellisense (with tokens). Never two; never inline+hook.
read WS SID <<< "$(make_workspace "1" "bug_fix" "plan" "")"
MSG=$(mktemp)
cat > "$MSG" <<'EOF'
test: subject

body line

Intellisense-Metadata: {"v":1,"author_type":"claude_inline","commit_kind":"single","stamping_source":"agent_inline","classification_state":"ok","tier":1,"mode":"bug_fix","session":"prior-inline","version":"1.0.0","skills":[],"agents":[],"rules_expected":[]}
EOF
run_hook "$WS" "$MSG"
n=$(count_trailer "$MSG" "Intellisense-Metadata")
[[ "$n" == "1" ]] && pass "INT: exactly one Intellisense-Metadata after hook (inline stripped)" || fail "INT: $n Intellisense-Metadata lines (expected 1)"
META=$(extract_metadata "$MSG")
echo "$META" | jq -e '.author_type == "claude_with_intellisense"' >/dev/null 2>&1 \
    && pass "INT: surviving trailer is claude_with_intellisense (hook overwrote inline)" \
    || fail "INT: author_type=$(echo "$META" | jq -r '.author_type // "?"') (expected claude_with_intellisense)"
echo "$META" | jq -e '.stamping_source == "local_hook"' >/dev/null 2>&1 \
    && pass "INT: stamping_source=local_hook" || fail "INT: stamping_source wrong"
echo "$META" | jq -e 'has("tokens")' >/dev/null 2>&1 \
    && pass "INT: hook-stamped trailer carries tokens" || fail "INT: tokens missing on hook trailer"
rm -rf "$WS" "$MSG"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
