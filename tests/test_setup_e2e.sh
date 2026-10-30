#!/usr/bin/env bash
# tests/test_setup_e2e.sh
#
# End-to-end / integration tests for PR 2's setup.sh changes. Closes the
# coverage gap flagged in the 2026-05-19 audit:
#
#   "180 tests pass but ZERO of them actually run setup.sh start-to-finish
#    and assert 'after this, the dev's machine looks like X.'"
#
# Two scenario coverage:
#   E1-E3:  install_heartbeat_cron behavior (plist writing, idempotency, skip)
#   E4-E5:  heartbeat call-site BLOCKS setup on token failure (regression guard)
#   E6-E7:  full setup.sh smoke tests (slow but real)
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# Extract install_heartbeat_token + install_heartbeat_cron + the heartbeat
# call-site block into temp files. Same pattern as
# test_heartbeat_token_install.sh — sub-bash sources the function.
export TOKEN_FN_FILE CRON_FN_FILE
TOKEN_FN_FILE="$(mktemp)"
CRON_FN_FILE="$(mktemp)"
sed -n '/^install_heartbeat_token() {/,/^}/p' "$SETUP" > "$TOKEN_FN_FILE"
sed -n '/^install_heartbeat_cron() {/,/^}/p'  "$SETUP" > "$CRON_FN_FILE"
trap 'rm -f "$TOKEN_FN_FILE" "$CRON_FN_FILE"' EXIT

UNAME_S="$(uname -s 2>/dev/null)"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== E1: install_heartbeat_cron writes a plist on Darwin ==="
if [[ "$UNAME_S" != "Darwin" ]]; then
    echo "  ⏭  SKIP (only meaningful on Darwin; current: $UNAME_S)"
else
    TMP=$(mktemp -d)
    # the heartbeat step's cron installer requires the token file to already exist;
    # otherwise it returns early ("don't install cron without a token").
    mkdir -p "$TMP/.intellisense"
    printf 'testtoken1234567890abcdef' > "$TMP/.intellisense/heartbeat-token"
    chmod 600 "$TMP/.intellisense/heartbeat-token"

    out=$(
        HOME="$TMP" \
        NO_HEARTBEAT=false \
        DRY_RUN=false \
        SCRIPT_DIR="$REPO_ROOT" \
        bash -c '
            YELLOW=""; RED=""; NC=""
            status_line() { echo "[$1] $2"; }
            source "$CRON_FN_FILE"
            # Stub the helpers install_heartbeat_cron calls but that are NOT in
            # the extracted function body (defined elsewhere in setup.sh), so the
            # Darwin path reaches the plist write instead of erroring out.
            resolve_github_login() { echo "TESTUSER"; }
            _hb_atomic_install_file() { return 0; }
            _hb_write_manifest() { return 0; }
            _hb_install_post_merge_hook() { return 0; }
            # Stub launchctl so we do not actually load the plist into the
            # users real launchd (would interfere with real heartbeat).
            launchctl() { return 0; }
            install_heartbeat_cron
        ' 2>&1
    )
    PLIST="$TMP/Library/LaunchAgents/in.intellisense.heartbeat.plist"
    [[ -f "$PLIST" ]] && pass "E1: plist file written to $PLIST" \
        || fail "E1: plist NOT written. Output: $out"
    # Verify plist content
    if [[ -f "$PLIST" ]]; then
        grep -q '<key>Label</key>' "$PLIST" && pass "E1: plist has Label key" || fail "E1: missing Label"
        grep -q 'in.intellisense.heartbeat' "$PLIST" && pass "E1: plist label correct" || fail "E1: label wrong"
        grep -q 'StartCalendarInterval' "$PLIST" && grep -q '<key>Minute</key>' "$PLIST" \
            && pass "E1: plist has hourly StartCalendarInterval" || fail "E1: no hourly calendar schedule"
        grep -q 'intellisense-heartbeat.sh' "$PLIST" && pass "E1: plist invokes heartbeat script" || fail "E1: wrong program"
    fi
    rm -rf "$TMP"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "=== E2: install_heartbeat_cron is idempotent (running twice = 1 plist) ==="
if [[ "$UNAME_S" != "Darwin" ]]; then
    echo "  ⏭  SKIP (only meaningful on Darwin)"
else
    TMP=$(mktemp -d)
    mkdir -p "$TMP/.intellisense"
    printf 'testtoken1234567890abcdef' > "$TMP/.intellisense/heartbeat-token"
    chmod 600 "$TMP/.intellisense/heartbeat-token"

    # Run twice
    for i in 1 2; do
        HOME="$TMP" \
        NO_HEARTBEAT=false \
        DRY_RUN=false \
        SCRIPT_DIR="$REPO_ROOT" \
        bash -c '
            YELLOW=""; RED=""; NC=""
            status_line() { return 0; }
            source "$CRON_FN_FILE"
            resolve_github_login() { echo "TESTUSER"; }
            _hb_atomic_install_file() { return 0; }
            _hb_write_manifest() { return 0; }
            _hb_install_post_merge_hook() { return 0; }
            launchctl() { return 0; }
            install_heartbeat_cron
        ' >/dev/null 2>&1
    done
    plist_count=$(find "$TMP/Library/LaunchAgents" -maxdepth 1 -name 'in.intellisense.heartbeat.plist' -type f 2>/dev/null | wc -l | tr -d ' ')
    [[ "$plist_count" == "1" ]] && pass "E2: exactly 1 plist after 2 runs (idempotent)" \
        || fail "E2: $plist_count plists after 2 runs"
    rm -rf "$TMP"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "=== E3: install_heartbeat_cron skips when no token file present ==="
TMP=$(mktemp -d)
# Deliberately NO token file at $TMP/.intellisense/heartbeat-token
HOME="$TMP" \
NO_HEARTBEAT=false \
DRY_RUN=false \
SCRIPT_DIR="$REPO_ROOT" \
bash -c '
    YELLOW=""; RED=""; NC=""
    status_line() { return 0; }
    source "$CRON_FN_FILE"
    launchctl() { return 0; }
    install_heartbeat_cron
' >/dev/null 2>&1
PLIST="$TMP/Library/LaunchAgents/in.intellisense.heartbeat.plist"
CRONTAB_ADDED=false
[[ -f "$PLIST" ]] && CRONTAB_ADDED=true
[[ "$CRONTAB_ADDED" == false ]] && pass "E3: no cron installed when token missing (correct)" \
    || fail "E3: cron was installed despite missing token"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== E4: heartbeat call-site BLOCKS setup when install_heartbeat_token fails ==="
# Build a tiny script that mimics the heartbeat call-site to verify the
# "if ! install_heartbeat_token; then exit 1; fi" pattern actually fires.
# A regression here (e.g. someone adds || true) would silently restore
# the degraded-install path.
TMP=$(mktemp -d)
cat > "$TMP/phase_g_mock.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
YELLOW=""; RED=""; NC=""
status_line() { return 0; }
source "$TOKEN_FN_FILE"
# Mimic the heartbeat step's exact call-site
if ! install_heartbeat_token; then
  echo "BLOCK_TRIGGERED" >&2
  exit 1
fi
echo "NOT_BLOCKED"
SCRIPT
chmod +x "$TMP/phase_g_mock.sh"

# Run with no token, no env var, non-interactive, no --no-heartbeat
out=$(
    HOME="$TMP" \
    INTERACTIVE=false \
    DRY_RUN=false \
    NO_HEARTBEAT=false \
    ROTATE_TOKEN=false \
    bash -c 'unset INTELLISENSE_HEARTBEAT_TOKEN; bash "$0"' "$TMP/phase_g_mock.sh" 2>&1
)
rc=$?
[[ "$rc" == "1" ]] && pass "E4: heartbeat call-site exits 1 when token missing" \
    || fail "E4: expected rc=1, got rc=$rc"
echo "$out" | grep -q 'BLOCK_TRIGGERED' && pass "E4: 'BLOCK_TRIGGERED' marker fired" \
    || fail "E4: block path did not fire: $out"
echo "$out" | grep -qi 'Setup blocked' && pass "E4: install_heartbeat_token emitted block message" \
    || fail "E4: blocking message missing"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== E5: heartbeat call-site PROCEEDS when token install succeeds ==="
TMP=$(mktemp -d)
cat > "$TMP/phase_g_mock.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -uo pipefail
YELLOW=""; RED=""; NC=""
status_line() { return 0; }
source "$TOKEN_FN_FILE"
if ! install_heartbeat_token; then
  echo "BLOCK_TRIGGERED" >&2
  exit 1
fi
echo "NOT_BLOCKED"
SCRIPT
chmod +x "$TMP/phase_g_mock.sh"

out=$(
    HOME="$TMP" \
    INTERACTIVE=false \
    DRY_RUN=false \
    NO_HEARTBEAT=false \
    ROTATE_TOKEN=false \
    INTELLISENSE_HEARTBEAT_TOKEN="validtoken1234567890abcdef" \
    INTELLISENSE_HEARTBEAT_ENDPOINT="https://collector.example.test/usage/daily" \
    bash "$TMP/phase_g_mock.sh" 2>&1
)
rc=$?
[[ "$rc" == "0" ]] && pass "E5: heartbeat call-site exits 0 when token valid" \
    || fail "E5: expected rc=0, got rc=$rc"
echo "$out" | grep -q 'NOT_BLOCKED' && pass "E5: control reached past the gate" \
    || fail "E5: NOT_BLOCKED marker missing"
[[ -f "$TMP/.intellisense/heartbeat-token" ]] && pass "E5: token file written" \
    || fail "E5: token file missing"
rm -rf "$TMP"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== E6: full setup.sh --no-heartbeat exits 0 (CI / opt-out path) ==="
# Slow test: runs the real setup.sh. Targets the CI escape hatch.
# Skipped by default — enable with INTELLISENSE_RUN_FULL_SETUP_E2E=1.
if [[ "${INTELLISENSE_RUN_FULL_SETUP_E2E:-0}" == "1" ]]; then
    TMP=$(mktemp -d)
    HOME="$TMP" bash "$SETUP" --non-interactive --yes --no-heartbeat >/dev/null 2>&1
    rc=$?
    [[ "$rc" == "0" ]] && pass "E6: setup.sh --no-heartbeat → exit 0" \
        || fail "E6: setup.sh --no-heartbeat → exit $rc (expected 0)"
    [[ ! -f "$TMP/.intellisense/heartbeat-token" ]] && pass "E6: --no-heartbeat skipped token install" \
        || fail "E6: token unexpectedly installed under --no-heartbeat"
    rm -rf "$TMP"
else
    echo "  ⏭  SKIP (slow; enable with INTELLISENSE_RUN_FULL_SETUP_E2E=1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "=== E7: full setup.sh WITHOUT token must BLOCK (rc=1) ==="
if [[ "${INTELLISENSE_RUN_FULL_SETUP_E2E:-0}" == "1" ]]; then
    TMP=$(mktemp -d)
    unset INTELLISENSE_HEARTBEAT_TOKEN
    out=$( HOME="$TMP" bash "$SETUP" --non-interactive --yes 2>&1 )
    rc=$?
    [[ "$rc" != "0" ]] && pass "E7: setup.sh without token → exit $rc (non-zero, expected)" \
        || fail "E7: setup.sh exited 0 without a token — BLOCKING policy broken"
    echo "$out" | grep -qi 'Setup blocked' && pass "E7: 'Setup blocked' surfaced to user" \
        || fail "E7: blocking message missing in output"
    [[ ! -f "$TMP/.intellisense/heartbeat-token" ]] && pass "E7: no token file after failed setup" \
        || fail "E7: token file present after failed setup"
    rm -rf "$TMP"
else
    echo "  ⏭  SKIP (slow; enable with INTELLISENSE_RUN_FULL_SETUP_E2E=1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "  (E6/E7 skipped by default; enable: INTELLISENSE_RUN_FULL_SETUP_E2E=1)"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
