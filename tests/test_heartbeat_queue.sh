#!/usr/bin/env bash
# tests/test_heartbeat_queue.sh
#
# Tests for the heartbeat queue + retry path. We use a mock POST endpoint
# (a local netcat would be ideal but isn't portable; instead we override
# INTELLISENSE_HEARTBEAT_URL to a controllable mock-server fixture).
#
# Strategy: run intellisense-heartbeat.sh with INTELLISENSE_HEARTBEAT_URL pointed at a file://
# OR override `curl` via PATH. We choose the PATH-override approach — simpler
# and works on macOS/Linux without netcat.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HEARTBEAT="$REPO_ROOT/scripts/intellisense-heartbeat.sh"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# Build a fake curl that we can control via env var INTELLISENSE_TEST_FAKE_STATUS.
# Writes the requested URL + headers + body to INTELLISENSE_TEST_LOG.
make_fake_curl() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/curl" <<'CURL'
#!/usr/bin/env bash
# Fake curl that echoes a status code to stdout (mimicking -w "%{http_code}")
# and logs invocations to INTELLISENSE_TEST_LOG.
{
    echo "INVOKE $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for arg in "$@"; do echo "ARG $arg"; done
    # If --data-binary @<file> was passed, capture the file contents
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --data-binary)
                if [[ "${2:-}" =~ ^@ ]]; then
                    echo "BODY $(cat "${2#@}" 2>/dev/null | jq -c '{schema, event_type, idempotency_key}' 2>/dev/null || cat "${2#@}")"
                fi
                ;;
        esac
        shift
    done
} >> "${INTELLISENSE_TEST_LOG:-/dev/null}"

# Mimic curl's -o behavior: if -o was passed, write something to that file
out_file=""
for ((i=1; i<=$#; i++)); do
    if [[ "${!i:-}" == "-o" ]]; then
        j=$((i+1))
        out_file="${!j:-}"
    fi
done
[[ -n "$out_file" ]] && echo "{}" > "$out_file"

# Print the configured status (mimics -w "%{http_code}")
echo -n "${INTELLISENSE_TEST_FAKE_STATUS:-200}"
CURL
    chmod +x "$bin_dir/curl"
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 1: dry-run prints payload, NO POST attempted ==="
TMP=$(mktemp -d)
LOG="$TMP/test.log"
BIN="$TMP/bin"
make_fake_curl "$BIN"
INTELLISENSE_TEST_LOG="$LOG" INTELLISENSE_TEST_FAKE_STATUS="200" \
    PATH="$BIN:$PATH" \
    INTELLISENSE_HEARTBEAT_TOKEN="test-token" \
    INTELLISENSE_HEARTBEAT_URL="https://fake.test/usage/daily" \
    INTELLISENSE_HEARTBEAT_QUEUE_DIR="$TMP/queue" \
    INTELLISENSE_HEARTBEAT_STATE_FILE="$TMP/state" \
    bash "$HEARTBEAT" --dry-run > "$TMP/payload.json" 2>&1

if jq -e '.heartbeats[0].event_type' "$TMP/payload.json" >/dev/null 2>&1; then
    pass "dry-run produces valid JSON payload (v3 wrapper)"
else
    fail "dry-run output is not JSON: $(head -3 "$TMP/payload.json")"
fi
# Critical: no curl invocation in dry-run mode
if [[ ! -s "$LOG" ]] || ! grep -q INVOKE "$LOG"; then
    pass "dry-run did NOT call curl"
else
    fail "dry-run called curl: $(cat "$LOG")"
fi
# And no queue entries were created
queue_count=$(find "$TMP/queue" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$queue_count" == "0" ]] && pass "dry-run did NOT enqueue" || fail "dry-run enqueued $queue_count files"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 2: 200 OK → no queue entry left ==="
TMP=$(mktemp -d)
LOG="$TMP/test.log"
BIN="$TMP/bin"
make_fake_curl "$BIN"
INTELLISENSE_TEST_LOG="$LOG" INTELLISENSE_TEST_FAKE_STATUS="200" \
    PATH="$BIN:$PATH" \
    INTELLISENSE_HEARTBEAT_TOKEN="test-token" \
    INTELLISENSE_HEARTBEAT_URL="https://fake.test/usage/daily" \
    INTELLISENSE_HEARTBEAT_QUEUE_DIR="$TMP/queue" \
    INTELLISENSE_HEARTBEAT_STATE_FILE="$TMP/state" \
    bash "$HEARTBEAT" >/dev/null 2>&1
queue_count=$(find "$TMP/queue" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$queue_count" == "0" ]] && pass "200 OK: queue empty" || fail "200 OK left $queue_count queue entries"
grep -q INVOKE "$LOG" && pass "200 OK: curl was actually invoked" || fail "200 OK: curl not invoked"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
# the collector returns 202 (async-accept) on success, not 200.
# Confirmed via live POST 2026-05-19 → {"accepted_rows":1}.
echo "=== Case 2b (v3 contract): 202 Accepted → no queue entry left ==="
TMP=$(mktemp -d)
LOG="$TMP/test.log"
BIN="$TMP/bin"
make_fake_curl "$BIN"
INTELLISENSE_TEST_LOG="$LOG" INTELLISENSE_TEST_FAKE_STATUS="202" \
    PATH="$BIN:$PATH" \
    INTELLISENSE_HEARTBEAT_TOKEN="test-token" \
    INTELLISENSE_HEARTBEAT_URL="https://fake.test/usage/daily" \
    INTELLISENSE_HEARTBEAT_QUEUE_DIR="$TMP/queue" \
    INTELLISENSE_HEARTBEAT_STATE_FILE="$TMP/state" \
    bash "$HEARTBEAT" >/dev/null 2>&1
queue_count=$(find "$TMP/queue" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$queue_count" == "0" ]] && pass "202 Accepted: queue empty (matches API behavior)" || fail "202 left $queue_count queue entries — should treat 2xx as success"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 3: 503 (server error) → payload enqueued for retry ==="
TMP=$(mktemp -d)
LOG="$TMP/test.log"
BIN="$TMP/bin"
make_fake_curl "$BIN"
INTELLISENSE_TEST_LOG="$LOG" INTELLISENSE_TEST_FAKE_STATUS="503" \
    PATH="$BIN:$PATH" \
    INTELLISENSE_HEARTBEAT_TOKEN="test-token" \
    INTELLISENSE_HEARTBEAT_URL="https://fake.test/usage/daily" \
    INTELLISENSE_HEARTBEAT_QUEUE_DIR="$TMP/queue" \
    INTELLISENSE_HEARTBEAT_STATE_FILE="$TMP/state" \
    bash "$HEARTBEAT" >/dev/null 2>&1
queue_count=$(find "$TMP/queue" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$queue_count" == "1" ]] && pass "503: payload queued (count=$queue_count)" || fail "503: queue count=$queue_count expected 1"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 4: 429 (rate-limit) → drop silently, NO queue entry ==="
TMP=$(mktemp -d)
LOG="$TMP/test.log"
BIN="$TMP/bin"
make_fake_curl "$BIN"
INTELLISENSE_TEST_LOG="$LOG" INTELLISENSE_TEST_FAKE_STATUS="429" \
    PATH="$BIN:$PATH" \
    INTELLISENSE_HEARTBEAT_TOKEN="test-token" \
    INTELLISENSE_HEARTBEAT_URL="https://fake.test/usage/daily" \
    INTELLISENSE_HEARTBEAT_QUEUE_DIR="$TMP/queue" \
    INTELLISENSE_HEARTBEAT_STATE_FILE="$TMP/state" \
    bash "$HEARTBEAT" >/dev/null 2>&1
queue_count=$(find "$TMP/queue" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$queue_count" == "0" ]] && pass "429: dropped (no queue)" || fail "429: $queue_count queued"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 5: 401 (bad token) → error logged, NO queue entry ==="
TMP=$(mktemp -d)
LOG="$TMP/test.log"
BIN="$TMP/bin"
make_fake_curl "$BIN"
INTELLISENSE_TEST_LOG="$LOG" INTELLISENSE_TEST_FAKE_STATUS="401" \
    PATH="$BIN:$PATH" \
    INTELLISENSE_HEARTBEAT_TOKEN="test-token" \
    INTELLISENSE_HEARTBEAT_URL="https://fake.test/usage/daily" \
    INTELLISENSE_HEARTBEAT_QUEUE_DIR="$TMP/queue" \
    INTELLISENSE_HEARTBEAT_STATE_FILE="$TMP/state" \
    INTELLISENSE_HEARTBEAT_ERROR_LOG="$TMP/err.log" \
    bash "$HEARTBEAT" >/dev/null 2>&1
queue_count=$(find "$TMP/queue" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$queue_count" == "0" ]] && pass "401: not queued" || fail "401: queued"
[[ -s "$TMP/err.log" ]] && grep -q "http=401" "$TMP/err.log" && pass "401: error logged" \
    || fail "401: error log empty or missing http=401: $(cat "$TMP/err.log" 2>/dev/null)"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 6: no token → queue, no curl call ==="
TMP=$(mktemp -d)
LOG="$TMP/test.log"
BIN="$TMP/bin"
make_fake_curl "$BIN"
# Deliberately omit INTELLISENSE_HEARTBEAT_TOKEN
INTELLISENSE_TEST_LOG="$LOG" INTELLISENSE_TEST_FAKE_STATUS="200" \
    PATH="$BIN:$PATH" \
    INTELLISENSE_HEARTBEAT_TOKEN_FILE="$TMP/no-such-token" \
    INTELLISENSE_HEARTBEAT_URL="https://fake.test/usage/daily" \
    INTELLISENSE_HEARTBEAT_QUEUE_DIR="$TMP/queue" \
    INTELLISENSE_HEARTBEAT_STATE_FILE="$TMP/state" \
    bash "$HEARTBEAT" >/dev/null 2>&1
queue_count=$(find "$TMP/queue" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$queue_count" == "1" ]] && pass "no-token: payload queued for later" \
    || fail "no-token: queue count=$queue_count expected 1"
# curl IS invoked (the script tries) but our fake curl detects no token through
# load_token returning empty, so post_payload sets HTTP_STATUS=000 — log shows
# INVOKE only if curl was actually called. Since load_token failed we return
# early. Verify no INVOKE.
if ! grep -q INVOKE "$LOG" 2>/dev/null; then
    pass "no-token: curl NOT invoked (load_token shortcut)"
else
    fail "no-token: curl was invoked anyway: $(grep INVOKE "$LOG")"
fi
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 7: --drain-only with empty queue → exit 0, no curl call ==="
TMP=$(mktemp -d)
LOG="$TMP/test.log"
BIN="$TMP/bin"
make_fake_curl "$BIN"
INTELLISENSE_TEST_LOG="$LOG" INTELLISENSE_TEST_FAKE_STATUS="200" \
    PATH="$BIN:$PATH" \
    INTELLISENSE_HEARTBEAT_TOKEN="test-token" \
    INTELLISENSE_HEARTBEAT_URL="https://fake.test/usage/daily" \
    INTELLISENSE_HEARTBEAT_QUEUE_DIR="$TMP/queue" \
    INTELLISENSE_HEARTBEAT_STATE_FILE="$TMP/state" \
    bash "$HEARTBEAT" --drain-only
rc=$?
[[ "$rc" == "0" ]] && pass "--drain-only empty queue: exit 0" || fail "--drain-only exit=$rc"
! grep -q INVOKE "$LOG" 2>/dev/null && pass "--drain-only empty queue: no curl call" \
    || fail "--drain-only with empty queue called curl"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 8: --drain-only with 1 queued + 200 OK → queue empty, curl 1x ==="
TMP=$(mktemp -d)
LOG="$TMP/test.log"
BIN="$TMP/bin"
make_fake_curl "$BIN"
mkdir -p "$TMP/queue"
echo '{"event_type":"developer_heartbeat","idempotency_key":"x_2026-05-19"}' \
    > "$TMP/queue/20260519T080000__x_2026-05-19.json"
INTELLISENSE_TEST_LOG="$LOG" INTELLISENSE_TEST_FAKE_STATUS="200" \
    PATH="$BIN:$PATH" \
    INTELLISENSE_HEARTBEAT_TOKEN="test-token" \
    INTELLISENSE_HEARTBEAT_URL="https://fake.test/usage/daily" \
    INTELLISENSE_HEARTBEAT_QUEUE_DIR="$TMP/queue" \
    INTELLISENSE_HEARTBEAT_STATE_FILE="$TMP/state" \
    bash "$HEARTBEAT" --drain-only
queue_count=$(find "$TMP/queue" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$queue_count" == "0" ]] && pass "--drain-only: queue drained" || fail "--drain-only: queue still has $queue_count entries"
invoke_count=$(grep -c INVOKE "$LOG" 2>/dev/null || echo 0)
invoke_count="${invoke_count//[!0-9]/}"
[[ "${invoke_count:-0}" == "1" ]] && pass "--drain-only: curl invoked once" || fail "--drain-only: curl invoked $invoke_count times"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 9: http:// URL refused without --allow-http ==="
TMP=$(mktemp -d)
out=$( INTELLISENSE_HEARTBEAT_URL="http://localhost:9696/intellisense/usage/daily" \
       INTELLISENSE_HEARTBEAT_TOKEN="test-token" \
       INTELLISENSE_HEARTBEAT_QUEUE_DIR="$TMP/queue" \
    INTELLISENSE_HEARTBEAT_STATE_FILE="$TMP/state" \
       bash "$HEARTBEAT" 2>&1 )
rc=$?
[[ "$rc" -ne 0 ]] && pass "http URL without --allow-http: non-zero exit" || fail "http URL accepted (exit 0)"
echo "$out" | grep -qi 'http:// but --allow-http' && pass "http URL: clear refusal message" \
    || fail "http URL: error message missing: '$out'"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 9: queue-full trim drops oldest + logs queue_full_trim ==="
TMP=$(mktemp -d)
LOG="$TMP/test.log"
BIN="$TMP/bin"
make_fake_curl "$BIN"
mkdir -p "$TMP/queue"
# Pre-seed two OLDER queued inner-heartbeat files (sort = chronological by name).
printf '{"idempotency_key":"QUSER_2026-05-01","usage_summary":{"period":"2026-05-01"}}' \
    > "$TMP/queue/20260501T000000__QUSER_2026-05-01.json"
printf '{"idempotency_key":"QUSER_2026-05-02","usage_summary":{"period":"2026-05-02"}}' \
    > "$TMP/queue/20260502T000000__QUSER_2026-05-02.json"
# Cap=2, run one failing heartbeat for a NEW period (fake curl 000 = unreachable)
# so the fresh enqueue trips the trim and drops the oldest.
INTELLISENSE_TEST_LOG="$LOG" INTELLISENSE_TEST_FAKE_STATUS="000" \
    PATH="$BIN:$PATH" \
    INTELLISENSE_HEARTBEAT_TOKEN="test-token" \
    INTELLISENSE_HEARTBEAT_URL="https://fake.test/usage/daily" \
    INTELLISENSE_HEARTBEAT_QUEUE_DIR="$TMP/queue" \
    INTELLISENSE_HEARTBEAT_STATE_FILE="$TMP/state" \
    INTELLISENSE_HEARTBEAT_ERROR_LOG="$TMP/err.log" \
    INTELLISENSE_HEARTBEAT_QUEUE_MAX="2" \
    bash "$HEARTBEAT" >/dev/null 2>&1
queue_count=$(find "$TMP/queue" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$queue_count" == "2" ]] && pass "queue held at cap=2 after trim" || fail "queue count=$queue_count expected 2"
{ [[ -s "$TMP/err.log" ]] && grep -q 'queue_full_trim' "$TMP/err.log" && grep -q 'QUSER_2026-05-01' "$TMP/err.log"; } \
    && pass "queue_full_trim logged the dropped key (QUSER_2026-05-01)" \
    || fail "queue_full_trim/dropped-key not in err log: $(cat "$TMP/err.log" 2>/dev/null)"
! [[ -f "$TMP/queue/20260501T000000__QUSER_2026-05-01.json" ]] \
    && pass "oldest entry actually removed" || fail "oldest entry still present"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 10: non-numeric INTELLISENSE_HEARTBEAT_QUEUE_MAX falls back to 30 ==="
TMP=$(mktemp -d)
LOG="$TMP/test.log"
BIN="$TMP/bin"
make_fake_curl "$BIN"
mkdir -p "$TMP/queue"
# 3 pre-seeded entries; garbage cap must NOT trim them (default 30 applies).
for d in 01 02 03; do
    printf '{"idempotency_key":"QUSER_2026-05-%s"}' "$d" \
        > "$TMP/queue/202605${d}T000000__QUSER_2026-05-${d}.json"
done
INTELLISENSE_TEST_LOG="$LOG" INTELLISENSE_TEST_FAKE_STATUS="000" \
    PATH="$BIN:$PATH" \
    INTELLISENSE_HEARTBEAT_TOKEN="test-token" \
    INTELLISENSE_HEARTBEAT_URL="https://fake.test/usage/daily" \
    INTELLISENSE_HEARTBEAT_QUEUE_DIR="$TMP/queue" \
    INTELLISENSE_HEARTBEAT_STATE_FILE="$TMP/state" \
    INTELLISENSE_HEARTBEAT_ERROR_LOG="$TMP/err.log" \
    INTELLISENSE_HEARTBEAT_QUEUE_MAX="not-a-number" \
    bash "$HEARTBEAT" >/dev/null 2>&1
# 3 preseeded + 1 new (failing) period = 4, none trimmed under default 30.
queue_count=$(find "$TMP/queue" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$queue_count" -ge 3 ]] && pass "garbage QUEUE_MAX → fell back to 30 (no spurious trim, count=$queue_count)" \
    || fail "garbage QUEUE_MAX trimmed unexpectedly: count=$queue_count"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
