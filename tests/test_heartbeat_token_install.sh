#!/usr/bin/env bash
# tests/test_heartbeat_token_install.sh
#
# Tests for the heartbeat token install UX in setup.sh:
#   - INTELLISENSE_HEARTBEAT_TOKEN env var path
#   - --no-heartbeat skip
#   - --rotate-token re-prompt
#   - --print-token-instructions short-circuit
#   - token format validation rejects bad values
#   - 0600 file permissions on the stored token
#   - non-interactive without env var prints warning, exits 0 (degraded install)
#
# We use --print-token-instructions and isolate install_heartbeat_token by
# sourcing setup.sh's flag-parse + functions in a sub-environment that points
# HOME at a tmpdir, so we don't pollute the real ~/.intellisense/.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# Extract install_heartbeat_token ONCE to a temp file. Source it in each test
# (sub-bash quoting + BSD sed don't play nicely with inline sed-eval per-case).
# Exported so bash -c sub-shells can see it.
export FN_FILE
FN_FILE="$(mktemp)"
sed -n '/^install_heartbeat_token() {/,/^}/p' "$SETUP" > "$FN_FILE"
trap 'rm -f "$FN_FILE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 1: --print-token-instructions exits 0 + mentions both required values ==="
out=$(bash "$SETUP" --print-token-instructions 2>&1)
rc=$?
[[ "$rc" == "0" ]] && pass "exit 0" || fail "exit=$rc"
echo "$out" | grep -q 'INTELLISENSE_HEARTBEAT_ENDPOINT' && pass "mentions INTELLISENSE_HEARTBEAT_ENDPOINT" || fail "missing endpoint hint"
echo "$out" | grep -q 'INTELLISENSE_HEARTBEAT_TOKEN' && pass "mentions INTELLISENSE_HEARTBEAT_TOKEN" || fail "missing token hint"
echo "$out" | grep -qi 'rotate-token' && pass "mentions --rotate-token" || fail "missing rotate hint"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 2: INTELLISENSE_HEARTBEAT_TOKEN env var writes 0600 file ==="
# Run install_heartbeat_token in isolation via a sub-bash that sources setup.sh
# up through the function definition but skips the main flow.
TMP=$(mktemp -d)
out=$(
    HOME="$TMP" \
    INTERACTIVE=false \
    DRY_RUN=false \
    NO_HEARTBEAT=false \
    ROTATE_TOKEN=false \
    INTELLISENSE_HEARTBEAT_TOKEN="testtoken1234567890abcdef" \
    INTELLISENSE_HEARTBEAT_ENDPOINT="https://collector.example.test/usage/daily" \
    bash -c '
        # Stub status_line so we don'\''t depend on colors
        status_line() { echo "[$1] $2"; }
        # Source just the function definition out of setup.sh
        source "$FN_FILE"
        install_heartbeat_token
    ' 2>&1
)
TOKEN_FILE="$TMP/.intellisense/heartbeat-token"
if [[ -f "$TOKEN_FILE" ]]; then
    pass "env-var path: token file created"
else
    fail "env-var path: token file NOT created. Output: $out"
fi
if [[ -f "$TOKEN_FILE" ]]; then
    perms=$(stat -c '%a' "$TOKEN_FILE" 2>/dev/null || stat -f '%A' "$TOKEN_FILE" 2>/dev/null)
    [[ "$perms" == "600" ]] && pass "token file perms = 600" || fail "perms=$perms"
    grep -q '^testtoken1234567890abcdef$' "$TOKEN_FILE" && pass "token value matches" || fail "token value wrong"
fi
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 3: --no-heartbeat skips install entirely ==="
TMP=$(mktemp -d)
out=$(
    HOME="$TMP" \
    INTERACTIVE=false \
    DRY_RUN=false \
    NO_HEARTBEAT=true \
    ROTATE_TOKEN=false \
    INTELLISENSE_HEARTBEAT_TOKEN="testtoken1234567890abcdef" \
    bash -c '
        status_line() { echo "[$1] $2"; }
        source "$FN_FILE"
        install_heartbeat_token
    ' 2>&1
)
[[ ! -f "$TMP/.intellisense/heartbeat-token" ]] && pass "no-heartbeat: token file NOT created" \
    || fail "no-heartbeat: token file WAS created"
echo "$out" | grep -qi 'skip' && pass "no-heartbeat: SKIP message emitted" || fail "no SKIP message: $out"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 4: token format validation rejects too-short token ==="
TMP=$(mktemp -d)
out=$(
    HOME="$TMP" \
    INTERACTIVE=false \
    DRY_RUN=false \
    NO_HEARTBEAT=false \
    ROTATE_TOKEN=false \
    INTELLISENSE_HEARTBEAT_TOKEN="x" \
    INTELLISENSE_HEARTBEAT_ENDPOINT="https://collector.example.test/usage/daily" \
    bash -c '
        status_line() { echo "[$1] $2"; }
        source "$FN_FILE"
        install_heartbeat_token
        echo "rc=$?"
    ' 2>&1
)
[[ ! -f "$TMP/.intellisense/heartbeat-token" ]] && pass "too-short token: NOT stored" \
    || fail "too-short token was stored"
echo "$out" | grep -qi 'invalid' && pass "too-short token: error mentions 'invalid'" \
    || fail "too-short error message missing: $out"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 5: token format validation rejects whitespace ==="
TMP=$(mktemp -d)
out=$(
    HOME="$TMP" \
    INTERACTIVE=false \
    DRY_RUN=false \
    NO_HEARTBEAT=false \
    ROTATE_TOKEN=false \
    INTELLISENSE_HEARTBEAT_TOKEN="bad token with spaces in it abc" \
    INTELLISENSE_HEARTBEAT_ENDPOINT="https://collector.example.test/usage/daily" \
    bash -c '
        status_line() { echo "[$1] $2"; }
        source "$FN_FILE"
        install_heartbeat_token
    ' 2>&1
)
[[ ! -f "$TMP/.intellisense/heartbeat-token" ]] && pass "whitespace token: NOT stored" \
    || fail "whitespace token was stored"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 6: token already present + no rotate → leave it alone ==="
TMP=$(mktemp -d)
TOKEN_FILE="$TMP/.intellisense/heartbeat-token"
mkdir -p "$(dirname "$TOKEN_FILE")"
printf 'preexisting-token-keep-me' > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
printf 'https://collector.example.test/usage/daily' > "$TMP/.intellisense/heartbeat-endpoint"
chmod 600 "$TMP/.intellisense/heartbeat-endpoint"

out=$(
    HOME="$TMP" \
    INTERACTIVE=false \
    DRY_RUN=false \
    NO_HEARTBEAT=false \
    ROTATE_TOKEN=false \
    INTELLISENSE_HEARTBEAT_TOKEN="" \
    bash -c '
        status_line() { echo "[$1] $2"; }
        source "$FN_FILE"
        install_heartbeat_token
    ' 2>&1
)
grep -q '^preexisting-token-keep-me$' "$TOKEN_FILE" && pass "existing token preserved" \
    || fail "token was overwritten"
echo "$out" | grep -qi 'present\|already' && pass "PRESENT message emitted" || fail "no PRESENT message: $out"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 7: --rotate-token replaces existing token ==="
TMP=$(mktemp -d)
TOKEN_FILE="$TMP/.intellisense/heartbeat-token"
mkdir -p "$(dirname "$TOKEN_FILE")"
printf 'old-token-should-be-replaced' > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"
printf 'https://collector.example.test/usage/daily' > "$TMP/.intellisense/heartbeat-endpoint"
chmod 600 "$TMP/.intellisense/heartbeat-endpoint"

out=$(
    HOME="$TMP" \
    INTERACTIVE=false \
    DRY_RUN=false \
    NO_HEARTBEAT=false \
    ROTATE_TOKEN=true \
    INTELLISENSE_HEARTBEAT_TOKEN="newrotatedtoken1234567890" \
    bash -c '
        status_line() { echo "[$1] $2"; }
        source "$FN_FILE"
        install_heartbeat_token
    ' 2>&1
)
grep -q '^newrotatedtoken1234567890$' "$TOKEN_FILE" && pass "rotate-token: new value written" \
    || fail "rotate-token: file still has '$(cat "$TOKEN_FILE")'"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 8: non-interactive + no env var + no file → BLOCKING (rc=1) ==="
# Policy change: the heartbeat is REQUIRED. No more degraded
# install. setup.sh must fail when no token is available so analytics
# coverage stays universal. The only escape is --no-heartbeat (Case 3),
# which exists solely for CI/test environments.
TMP=$(mktemp -d)
out=$(
    HOME="$TMP" \
    INTERACTIVE=false \
    DRY_RUN=false \
    NO_HEARTBEAT=false \
    ROTATE_TOKEN=false \
    bash -c '
        unset INTELLISENSE_HEARTBEAT_TOKEN
        YELLOW=""
        RED=""
        NC=""
        status_line() { echo "[$1] $2"; }
        source "$FN_FILE"
        install_heartbeat_token
        echo "rc=$?"
    ' 2>&1
)
[[ ! -f "$TMP/.intellisense/heartbeat-token" ]] && pass "no token: no token file" \
    || fail "no token: file unexpectedly created"
echo "$out" | grep -q 'rc=1' && pass "no token: exit 1 (BLOCKS setup)" \
    || fail "no token: expected rc=1, output: $out"
echo "$out" | grep -qi 'Setup blocked' && pass "no token: 'Setup blocked' message" \
    || fail "no token: blocking message missing: $out"
echo "$out" | grep -qi 'INTELLISENSE_HEARTBEAT_TOKEN' && pass "no token: hint mentions env var" \
    || fail "no env-var hint in error"
echo "$out" | grep -qi 'platform admin' && pass "no token: hint mentions where to ask" \
    || fail "no admin-contact hint in error"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 9: invalid token format → BLOCKING (rc=1), no file written ==="
TMP=$(mktemp -d)
out=$(
    HOME="$TMP" \
    INTERACTIVE=false \
    DRY_RUN=false \
    NO_HEARTBEAT=false \
    ROTATE_TOKEN=false \
    INTELLISENSE_HEARTBEAT_TOKEN="contains spaces invalid" \
    INTELLISENSE_HEARTBEAT_ENDPOINT="https://collector.example.test/usage/daily" \
    bash -c '
        YELLOW=""; RED=""; NC=""
        status_line() { echo "[$1] $2"; }
        source "$FN_FILE"
        install_heartbeat_token
        echo "rc=$?"
    ' 2>&1
)
[[ ! -f "$TMP/.intellisense/heartbeat-token" ]] && pass "invalid token: no file written" \
    || fail "invalid token was stored"
echo "$out" | grep -q 'rc=1' && pass "invalid token: exit 1" \
    || fail "invalid token: expected rc=1"
echo "$out" | grep -qi 'Setup blocked' && pass "invalid token: blocking message" \
    || fail "invalid token: no blocking message: $out"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
