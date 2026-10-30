#!/usr/bin/env bash
# tests/test_routing_telemetry.sh
#
# cross-channel routing telemetry invariants:
#   1. Docs parser example uses v=1 / dual-read guidance.
#   2. Docs dedup contract references `(session, event_id)`, with a fallback
#      key for rows whose event_id is empty.
#   3. End-to-end: 3 repeated gated edits → 1 routing event → trailer carries
#      event_id → heartbeat aggregates to 1 unique.
#
# These checks are intentionally lightweight (grep + shell) so the test stays
# fast and runs without spinning up the full integration harness.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$REPO_ROOT/scripts/preToolUse-contract-gate.sh"
HOOK="$REPO_ROOT/hooks/prepare-commit-msg"
LIB="$REPO_ROOT/scripts/lib/heartbeat-payload.sh"
DOC="$REPO_ROOT/docs/telemetry-contract.md"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# ─── Case 1: docs name the current schema version ────────────────────────────
echo "=== Case 1: docs parser example uses v=1 / dual-read guidance ==="
if grep -qE 'v=1|currently `1`|current schema version' "$DOC"; then
    pass "Case 1: docs reference v=1 as current"
else
    fail "Case 1: docs missing v=1 reference"
fi
# dual-read note must be present (additive fields under unknown-field-ignore)
if grep -qiE 'dual.?read|unknown fields|ignore.*unknown' "$DOC"; then
    pass "Case 1: docs describe dual-read / unknown-field tolerance"
else
    fail "Case 1: docs missing dual-read guidance"
fi

# ─── Case 2: docs dedup key references (session, event_id) ───────────────────
echo "=== Case 2: docs dedup contract uses event_id, with a fallback key ==="
if grep -qE '\(session, event_id\)|\bevent_id\b' "$DOC"; then
    pass "Case 2: docs reference event_id"
else
    fail "Case 2: docs missing event_id reference"
fi
# fallback key documented
if grep -qiE 'fallback' "$DOC"; then
    pass "Case 2: docs document the fallback key"
else
    fail "Case 2: docs missing fallback-key guidance"
fi
# index-based dedup is not a valid key
if grep -qE 'session, escalation_index_or_ts|session, position-in-array|session, escalation array index' "$DOC"; then
    fail "Case 2: docs recommend an index-based dedup key"
else
    pass "Case 2: docs do not recommend index-based dedup"
fi
# unique-events clarification — routing counts are events, not invocations
if grep -qiE 'unique.*(escalation|event)|not.*gated.*tool.*invocation|not.*tool.*invocation|per.*unique.*event' "$DOC"; then
    pass "Case 2: docs clarify routing counts are unique events"
else
    fail "Case 2: docs missing unique-events clarification"
fi

# ─── Case 3: end-to-end — gate writes once, trailer preserves, heartbeat dedupes ─
echo "=== Case 3: end-to-end — 3 gated edits → 1 event → trailer → heartbeat dedup ==="
FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/.intellisense/session" "$FIX/app/account"
git -C "$FIX" init -q -b feat/test 2>/dev/null
git -C "$FIX" config user.email test@test 2>/dev/null
git -C "$FIX" config user.name test 2>/dev/null
touch "$FIX/app/account/Account.php"
SID="rtest-sid-1"
cat > "$FIX/.intellisense/session/${SID}.classification.json" <<EOF
{ "tier": "0", "mode": "bug_fix", "confidence": 0.9, "classification_id": "cls_rtest" }
EOF
SETTINGS="$FIX/settings.json"
echo '{ "intellisense": { "gate_mode": "pilot", "audit_chain_enforcement": "warn" } }' > "$SETTINGS"

PAYLOAD_FACTORY() {
    jq -nc \
        --arg p "$1" \
        --arg s "$SID" \
        --arg c "$FIX" \
        '{tool_name:"Edit", tool_input:{file_path:$p}, session_id:$s, cwd:$c}'
}

for _i in 1 2 3; do
    INTELLISENSE_SETTINGS_FILE="$SETTINGS" \
    INTELLISENSE_EFFECTIVE_TIER_LIB="$REPO_ROOT/scripts/lib/effective-tier.sh" \
    bash "$GATE" <<<"$(PAYLOAD_FACTORY app/account/Account.php)" >/dev/null 2>&1 || true
done

ROUTING="$FIX/.intellisense/session/${SID}.routing.jsonl"
if [ -f "$ROUTING" ]; then
    NUM=$(wc -l <"$ROUTING" | tr -d ' ')
    if [ "$NUM" = "1" ]; then
        pass "Case 3a: 3 gated invocations → 1 routing event"
    else
        fail "Case 3a: expected 1 event, got $NUM"
        cat "$ROUTING"
    fi
    EID=$(jq -r '.event_id // empty' "$ROUTING" 2>/dev/null)
    if [ -n "$EID" ]; then
        pass "Case 3a: event carries event_id ($EID)"
    else
        fail "Case 3a: event missing event_id"
    fi
else
    fail "Case 3a: routing.jsonl never written"
fi

# Trailer phase: feed the routing.jsonl through prepare-commit-msg.
# Build a minimal usage.json so the hook treats this as a real intellisense session.
cat > "$FIX/.intellisense/session/${SID}.usage.json" <<EOF
{ "session_id": "$SID", "skills_used": ["plan"], "agents_spawned": [], "first_prompt_ts": "2026-06-01T10:00:00Z" }
EOF
printf '%s' "$SID" > "$FIX/.intellisense/session/current-session-id"

MSG=$(mktemp)
cat > "$MSG" <<'EOF'
test: routing trailer end-to-end

body
EOF
( cd "$FIX" && bash "$HOOK" "$MSG" "message" 2>/dev/null ) || true

META=$(grep '^Intellisense-Metadata:' "$MSG" | head -1 | sed 's/^Intellisense-Metadata: //')
echo "$META" | jq -e '.routing.escalations | length == 1' >/dev/null 2>&1 \
    && pass "Case 3b: trailer routing.escalations has the single event" \
    || fail "Case 3b: trailer escalations length wrong (META=$META)"
echo "$META" | jq -e '.routing.escalations[0].event_id != null and (.routing.escalations[0].event_id | length > 0)' >/dev/null 2>&1 \
    && pass "Case 3b: trailer escalation carries event_id" \
    || fail "Case 3b: trailer escalation missing event_id"
echo "$META" | jq -e '.routing.escalations[0].reason == "financial"' >/dev/null 2>&1 \
    && pass "Case 3b: trailer escalation carries reason=financial" \
    || fail "Case 3b: trailer escalation reason wrong/missing"

# Heartbeat phase: aggregate yesterday's events. Rewrite ts to yesterday so
# hb_behavior_stats' "period startswith" filter accepts the event, then
# append duplicates to exercise dedup.
PERIOD=$(date -u -v-1d +%Y-%m-%d 2>/dev/null || date -u --date=yesterday +%Y-%m-%d)
SINGLE_LINE=$(jq -c --arg p "$PERIOD" '.ts = ($p + "T10:00:00Z")' "$ROUTING")
{
    printf '%s\n' "$SINGLE_LINE"
    printf '%s\n' "$SINGLE_LINE"
    printf '%s\n' "$SINGLE_LINE"
} > "$ROUTING"

# shellcheck source=../scripts/lib/heartbeat-payload.sh
source "$LIB"
STATS=$(hb_behavior_stats "[\"$FIX\"]" "$PERIOD")
echo "$STATS" | jq -e '.routing_stats.escalations_today == 1' >/dev/null 2>&1 \
    && pass "Case 3c: heartbeat dedupes 3 duplicate rows → escalations_today=1" \
    || fail "Case 3c: escalations_today=$(echo "$STATS" | jq -r '.routing_stats.escalations_today')"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
