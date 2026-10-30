#!/bin/bash
# Sanitization regression suite for the heartbeat usage parser.
# Asserts that user-content (prompts, raw JSON, full paths) NEVER leaks
# into parse_error_detail, warnings[], stdout, or stderr — across all
# state transitions (A real / B idle / C partial+warnings / D fatal).
#
# This file exists separately from test_heartbeat_payload.sh because
# sanitization is a security boundary. Reviewers should see changes
# to this file as a discrete signal.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSER="$REPO_ROOT/scripts/lib/heartbeat_usage_parser.py"
PRICES="$REPO_ROOT/scripts/lib/heartbeat-prices.json"
PERIOD="2026-05-18"
CANARY="SECRET_PROMPT_CANARY_DO_NOT_LEAK"

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }
pass() { PASS=$((PASS+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ─── State A — clean usage, no warnings, no error ───────────────────────────
mkdir -p "$TMP/A/-Users-test-Project-foo"
cat > "$TMP/A/-Users-test-Project-foo/sess-aaaa.jsonl" <<JSONL
{"type":"assistant","timestamp":"${PERIOD}T10:00:00Z","sessionId":"aaaa-1111","message":{"model":"claude-opus-4-7","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JSONL

OUT_A="$(python3 "$PARSER" --period "$PERIOD" --prices "$PRICES" --transcripts-dir "$TMP/A" 2>&1)"
echo "$OUT_A" | jq -e '.cost_estimation_status == "complete"' >/dev/null && pass || fail "A: status not complete"
echo "$OUT_A" | jq -e '.sessions == 1' >/dev/null && pass || fail "A: sessions != 1"
echo "$OUT_A" | jq -e 'has("error") | not' >/dev/null && pass || fail "A: error key present"
echo "$OUT_A" | jq -e '.warnings == []' >/dev/null && pass || fail "A: warnings non-empty"

# ─── State B — idle, no transcripts ──────────────────────────────────────────
mkdir -p "$TMP/B"
OUT_B="$(python3 "$PARSER" --period "$PERIOD" --prices "$PRICES" --transcripts-dir "$TMP/B" 2>&1)"
echo "$OUT_B" | jq -e '.sessions == 0 and .cost_estimation_status == "complete" and (has("error") | not)' >/dev/null \
    && pass || fail "B: idle shape wrong"
echo "$OUT_B" | jq -e '.warnings == []' >/dev/null && pass || fail "B: warnings non-empty when idle"

# ─── State C — partial parse with canary prompt + unknown model ─────────────
mkdir -p "$TMP/C/-Users-test-Project-secret"
{
  # Good line with usage
  echo "{\"type\":\"assistant\",\"timestamp\":\"${PERIOD}T10:00:00Z\",\"sessionId\":\"cccc-1111\",\"message\":{\"model\":\"claude-opus-4-7\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":500,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
  # Malformed line containing the canary — must NOT leak
  echo "{\"message\":{\"content\":\"${CANARY}\", \"usage\":"
  # Unknown model
  echo "{\"type\":\"assistant\",\"timestamp\":\"${PERIOD}T11:00:00Z\",\"sessionId\":\"cccc-2222\",\"message\":{\"model\":\"claude-experimental-x-99\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
} > "$TMP/C/-Users-test-Project-secret/sess-cccc.jsonl"

OUT_C="$(python3 "$PARSER" --period "$PERIOD" --prices "$PRICES" --transcripts-dir "$TMP/C" 2>"$TMP/err_C.log")"

# Good line still aggregated (not zeroed by the bad line)
echo "$OUT_C" | jq -e '.input_tokens >= 1100' >/dev/null && pass || fail "C: good lines not aggregated (got $(echo "$OUT_C" | jq -c .input_tokens))"
# Warnings carry parse_partial
echo "$OUT_C" | jq -e '[.warnings[] | select(.type == "parse_partial")] | length == 1' >/dev/null && pass || fail "C: parse_partial warning missing"
# Unknown model surfaced
echo "$OUT_C" | jq -e '.unknown_models | index("claude-experimental-x-99") != null' >/dev/null && pass || fail "C: unknown_model not listed"
echo "$OUT_C" | jq -e '.cost_estimation_status == "partial"' >/dev/null && pass || fail "C: status not partial"

# SANITIZATION ASSERTIONS — across all output paths
! echo "$OUT_C" | grep -q "$CANARY" && pass || fail "C: canary leaked into stdout"
! grep -q "$CANARY" "$TMP/err_C.log" && pass || fail "C: canary leaked into stderr"
! echo "$OUT_C" | grep -q "/Users/" && pass || fail "C: full path leaked"
! echo "$OUT_C" | grep -q "$HOME" && pass || fail "C: \$HOME leaked"
! echo "$OUT_C" | grep -q "\.claude/projects" && pass || fail "C: .claude/projects path leaked"

# ─── State D — fatal: transcripts dir unreadable / prices bogus ─────────────
OUT_D="$(python3 "$PARSER" --period "$PERIOD" --prices /no/such/prices.json --transcripts-dir "$TMP/A" 2>"$TMP/err_D.log")"
echo "$OUT_D" | jq -e '.error == "parse_failed"' >/dev/null && pass || fail "D: error not parse_failed"
echo "$OUT_D" | jq -e '.cost_estimation_status == "unavailable"' >/dev/null && pass || fail "D: status not unavailable"
echo "$OUT_D" | jq -e '.parse_error_detail | length <= 120' >/dev/null && pass || fail "D: parse_error_detail too long"
echo "$OUT_D" | jq -e '.parse_error_detail | test("[{}\\[\\]]") | not' >/dev/null && pass || fail "D: parse_error_detail contains JSON braces"
! echo "$OUT_D" | grep -q "/Users/" && pass || fail "D: full path leaked"
! grep -q "Traceback" "$TMP/err_D.log" && pass || fail "D: traceback in stderr"

# ─── Static-grep CI guard — forbidden patterns in implementation ────────────
# parse_error_detail must never be assigned from raw exception/stderr/line content.
if grep -nE 'parse_error_detail.*=.*(stderr|stdout|traceback|raw_line|line_content|exc\.args|str\(exc\)|repr\(exc\))' "$PARSER" >/dev/null; then
    fail "static-grep: parse_error_detail assigned from raw parser output"
else
    pass
fi
# Required: builder function exists
grep -q '^def build_parse_error_detail' "$PARSER" && pass || fail "static-grep: build_parse_error_detail() missing"
# Required: empty_summary uses curated builder for any error detail
if grep -nE 'empty_summary.*parse_error_detail.*=.*"' "$PARSER" >/dev/null; then
    # Inline string usage is fine ONLY if it comes from build_parse_error_detail
    :
fi

# ─── Copied-runtime isolation grep (heartbeat-payload.sh side) ──────────────
# The library must not hardcode repo paths.
if grep -nE 'INTELLISENSE_SETUP_PATH/(scripts|hooks)' "$REPO_ROOT/scripts/lib/heartbeat-payload.sh" >/dev/null; then
    fail "isolation: heartbeat-payload.sh references INTELLISENSE_SETUP_PATH/scripts or /hooks"
else
    pass
fi
if grep -nE 'INTELLISENSE_SETUP_PATH/(scripts|hooks)' "$REPO_ROOT/scripts/intellisense-heartbeat.sh" >/dev/null; then
    fail "isolation: intellisense-heartbeat.sh references INTELLISENSE_SETUP_PATH/scripts or /hooks"
else
    pass
fi

# ─── Robustness cases ─────────────────────────────────────────────────────────

# Case U1: Bad usage field must not zero the whole day.
# Reproduce: one valid usage line + one line where input_tokens is an OBJECT
# (not a number). Good line aggregates, bad line counted in
# warnings, NOT a fatal State D.
echo "=== U1: bad usage field zeroes the day (must be partial, not fatal) ==="
mkdir -p "$TMP/R1/-Users-test-Project-x"
{
  # Valid line
  echo "{\"type\":\"assistant\",\"timestamp\":\"${PERIOD}T10:00:00Z\",\"sessionId\":\"r1-1\",\"message\":{\"model\":\"claude-opus-4-7\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
  # Bad-shape usage field — input_tokens is an object, not a number.
  # This is structurally-valid JSON but semantically wrong.
  echo "{\"type\":\"assistant\",\"timestamp\":\"${PERIOD}T11:00:00Z\",\"sessionId\":\"r1-2\",\"message\":{\"model\":\"claude-opus-4-7\",\"usage\":{\"input_tokens\":{\"nested\":\"object\"},\"output_tokens\":50,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
} > "$TMP/R1/-Users-test-Project-x/sess-r1.jsonl"

OUT_R1="$(python3 "$PARSER" --period "$PERIOD" --prices "$PRICES" --transcripts-dir "$TMP/R1" 2>/dev/null)"

# Valid line MUST still aggregate (input_tokens >= 100). State C, not D.
echo "$OUT_R1" | jq -e '.input_tokens >= 100' >/dev/null && pass \
    || fail "U1: bad usage field zeroed the day — got input_tokens=$(echo "$OUT_R1" | jq -c .input_tokens)"
# Must NOT be fatal State D
echo "$OUT_R1" | jq -e '.error == "parse_failed" | not' >/dev/null && pass \
    || fail "U1: bad usage field caused fatal State D"
# Bad line must surface in warnings (parse_partial)
echo "$OUT_R1" | jq -e '[.warnings[] | select(.type == "parse_partial")] | length >= 1' >/dev/null && pass \
    || fail "U1: parse_partial warning missing"

# Case U2: Missing python3 must not drop the entire heartbeat.
# usage_summary is mandatory. If python3 is unavailable,
# emit State D usage_summary and let the rest of the payload send.
# Old behavior (current bug): intellisense-heartbeat.sh exits 2.
echo "=== U2: missing python3 must not abort the heartbeat ==="
# Build a stub bin with the binaries the script needs EXCEPT python3.
# /usr/bin/python3 exists on macOS so a naive PATH would still find it;
# we sandbox to a single bin dir with hand-picked tools.
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
for tool in jq curl bash sh sed awk grep cat head tail tr cut date find mkdir rm mktemp stat ls wc dirname basename realpath touch chmod cp mv pwd uname env xargs sort sleep printf which command sort; do
    src="$(command -v "$tool" 2>/dev/null)"
    [ -n "$src" ] && ln -sf "$src" "$STUB_BIN/$tool"
done
# Deliberately NO python3 in $STUB_BIN.

HB_R2_OUT="$(env -i HOME="$HOME" USER="$(whoami)" \
    PATH="$STUB_BIN" \
    HB_VERSION_FILE="$TMP/fake-version" \
    HB_CLAUDE_PROJECTS_DIR="$TMP/nonexistent" \
    bash "$REPO_ROOT/scripts/intellisense-heartbeat.sh" --dry-run 2>"$TMP/err_R2.log")"
HB_R2_RC=$?

# Confirm python3 was actually unavailable under that PATH (test sanity)
if env -i PATH="$STUB_BIN" command -v python3 >/dev/null 2>&1; then
    fail "U2 setup: stub PATH still has python3 — test would not reproduce"
    fail "U2: (skipped — bad setup)"
else
    # Heartbeat must produce a payload (exit 0) AND that payload must contain
    # a usage_summary block — even if it's State D.
    [ "$HB_R2_RC" = "0" ] && pass \
        || fail "U2: heartbeat exited $HB_R2_RC (must be 0 even without python3) — stderr: $(head -3 "$TMP/err_R2.log" | tr '\n' ' ')"
    # Payload is now the v3 wrapper {org_id, heartbeats:[<inner>]} — look inside.
    echo "$HB_R2_OUT" | jq -e '.heartbeats[0].usage_summary | type == "object"' >/dev/null 2>&1 && pass \
        || fail "U2: usage_summary missing from payload when python3 absent (out: $(echo "$HB_R2_OUT" | head -c 200))"
fi

# Case U3: Old mtime must not exclude valid in-period events.
# Plan: mtime is optimization only; event timestamp is correctness boundary.
echo "=== U3: old mtime must not skip yesterday's events ==="
mkdir -p "$TMP/R3/-Users-test-Project-stale"
echo "{\"type\":\"assistant\",\"timestamp\":\"${PERIOD}T12:00:00Z\",\"sessionId\":\"r3-1\",\"message\":{\"model\":\"claude-opus-4-7\",\"usage\":{\"input_tokens\":777,\"output_tokens\":111,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}" \
    > "$TMP/R3/-Users-test-Project-stale/sess-r3.jsonl"
# Force a mtime well before the 2-day cutoff
touch -t 202401010000 "$TMP/R3/-Users-test-Project-stale/sess-r3.jsonl" 2>/dev/null || \
    touch -d "2024-01-01" "$TMP/R3/-Users-test-Project-stale/sess-r3.jsonl"

OUT_R3="$(python3 "$PARSER" --period "$PERIOD" --prices "$PRICES" --transcripts-dir "$TMP/R3" 2>/dev/null)"
echo "$OUT_R3" | jq -e '.input_tokens == 777' >/dev/null && pass \
    || fail "U3: old mtime excluded a valid in-period event — got input_tokens=$(echo "$OUT_R3" | jq -c .input_tokens)"
echo "$OUT_R3" | jq -e '.sessions >= 1' >/dev/null && pass \
    || fail "U3: sessions not counted for backdated-mtime file"

# Case U4: Duplicate assistant turns in transcript must not inflate cost.
# Claude Code re-logs the same (sessionId, requestId) on resume / sidechain /
# summarization. Summing both copies double-counts tokens. The fix dedupes
# by (sessionId, requestId) with fallback to (sessionId, message.id).
echo "=== U4: duplicate (sessionId,requestId) events must not inflate cost ==="
mkdir -p "$TMP/R4/-Users-test-Project-dup"
{
  # First copy of the request
  echo "{\"type\":\"assistant\",\"timestamp\":\"${PERIOD}T10:00:00Z\",\"sessionId\":\"r4-1\",\"requestId\":\"req_dup_A\",\"message\":{\"id\":\"msg_A\",\"model\":\"claude-opus-4-7\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":500,\"cache_creation_input_tokens\":2000,\"cache_read_input_tokens\":4000}}}"
  # Exact replay — same sessionId + requestId, different timestamp
  echo "{\"type\":\"assistant\",\"timestamp\":\"${PERIOD}T10:00:12Z\",\"sessionId\":\"r4-1\",\"requestId\":\"req_dup_A\",\"message\":{\"id\":\"msg_A\",\"model\":\"claude-opus-4-7\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":500,\"cache_creation_input_tokens\":2000,\"cache_read_input_tokens\":4000}}}"
  # Different request in the same session — must still be counted
  echo "{\"type\":\"assistant\",\"timestamp\":\"${PERIOD}T11:00:00Z\",\"sessionId\":\"r4-1\",\"requestId\":\"req_dup_B\",\"message\":{\"id\":\"msg_B\",\"model\":\"claude-opus-4-7\",\"usage\":{\"input_tokens\":100,\"output_tokens\":50,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
  # Same requestId as A but different session — must NOT be deduped against A
  echo "{\"type\":\"assistant\",\"timestamp\":\"${PERIOD}T12:00:00Z\",\"sessionId\":\"r4-2\",\"requestId\":\"req_dup_A\",\"message\":{\"id\":\"msg_A\",\"model\":\"claude-opus-4-7\",\"usage\":{\"input_tokens\":7,\"output_tokens\":3,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
} > "$TMP/R4/-Users-test-Project-dup/sess-r4.jsonl"

OUT_R4="$(python3 "$PARSER" --period "$PERIOD" --prices "$PRICES" --transcripts-dir "$TMP/R4" 2>/dev/null)"

# Expected: only 3 unique requests counted (A once, B, A-in-session-2).
# input = 1000 + 100 + 7 = 1107; output = 500 + 50 + 3 = 553
echo "$OUT_R4" | jq -e '.input_tokens == 1107' >/dev/null && pass \
    || fail "U4: input_tokens after dedup expected 1107, got $(echo "$OUT_R4" | jq -c .input_tokens)"
echo "$OUT_R4" | jq -e '.output_tokens == 553' >/dev/null && pass \
    || fail "U4: output_tokens after dedup expected 553, got $(echo "$OUT_R4" | jq -c .output_tokens)"
echo "$OUT_R4" | jq -e '.cache_creation_tokens == 2000' >/dev/null && pass \
    || fail "U4: cache_creation_tokens expected 2000, got $(echo "$OUT_R4" | jq -c .cache_creation_tokens)"
echo "$OUT_R4" | jq -e '.cache_read_tokens == 4000' >/dev/null && pass \
    || fail "U4: cache_read_tokens expected 4000, got $(echo "$OUT_R4" | jq -c .cache_read_tokens)"
# duplicate_events warning surfaces with count == 1 (one replay of A)
echo "$OUT_R4" | jq -e '[.warnings[] | select(.type == "duplicate_events")] | length == 1' >/dev/null && pass \
    || fail "U4: duplicate_events warning missing"
echo "$OUT_R4" | jq -e '[.warnings[] | select(.type == "duplicate_events")][0].event_count == 1' >/dev/null && pass \
    || fail "U4: duplicate_events count expected 1, got $(echo "$OUT_R4" | jq -c '[.warnings[]|select(.type=="duplicate_events")][0].event_count')"

# U4b: fallback dedup by message.id when requestId is absent
echo "=== U4b: fallback dedup by message.id when requestId missing ==="
mkdir -p "$TMP/R4b/-Users-test-Project-msgdup"
{
  echo "{\"type\":\"assistant\",\"timestamp\":\"${PERIOD}T10:00:00Z\",\"sessionId\":\"r4b-1\",\"message\":{\"id\":\"msg_dup_X\",\"model\":\"claude-opus-4-7\",\"usage\":{\"input_tokens\":500,\"output_tokens\":250,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
  echo "{\"type\":\"assistant\",\"timestamp\":\"${PERIOD}T10:00:30Z\",\"sessionId\":\"r4b-1\",\"message\":{\"id\":\"msg_dup_X\",\"model\":\"claude-opus-4-7\",\"usage\":{\"input_tokens\":500,\"output_tokens\":250,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0}}}"
} > "$TMP/R4b/-Users-test-Project-msgdup/sess-r4b.jsonl"

OUT_R4b="$(python3 "$PARSER" --period "$PERIOD" --prices "$PRICES" --transcripts-dir "$TMP/R4b" 2>/dev/null)"
echo "$OUT_R4b" | jq -e '.input_tokens == 500' >/dev/null && pass \
    || fail "U4b: message.id fallback dedup failed — expected 500, got $(echo "$OUT_R4b" | jq -c .input_tokens)"

# ─── Result ─────────────────────────────────────────────────────────────────
echo
echo "Sanitization tests: $PASS passed, $FAIL failed"
exit "$FAIL"
