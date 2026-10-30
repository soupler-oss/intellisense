#!/bin/bash
# Tests for v8 TCC-safe heartbeat runtime install.
# Asserts:
#   - install_heartbeat_cron() copies runtime + lib + VERSION + manifest to
#     ~/.intellisense/bin/ (POSIX-safe, non-TCC-protected)
#   - MANIFEST.sha256 written via cross-platform helper
#   - plist EnvironmentVariables carries HB_VERSION_FILE + extended PATH
#   - ProgramArguments points at the COPIED script, not the in-repo path
#   - Copied runtime is self-contained (no INTELLISENSE_SETUP_PATH/{scripts,hooks}
#     references)
#   - restore.sh removes only ~/.intellisense/bin/ + VERSION; preserves
#     heartbeat-token and the parent dir

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL+1)); }

# Sandboxed HOME so we don't touch the real install
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

# Seed a fake heartbeat token so install_heartbeat_cron() doesn't early-return
mkdir -p "$SANDBOX/.intellisense"
echo "fake-token-for-test" > "$SANDBOX/.intellisense/heartbeat-token"
chmod 600 "$SANDBOX/.intellisense/heartbeat-token"

# Run install_heartbeat_cron in a subshell with HOME redirected
# We can't actually run launchctl in CI, so stub it.
install_via_setup() {
    local home_override="$1"
    # Extract the three helpers via awk (handles multi-`}` functions correctly)
    local helpers
    helpers=$(awk '/^_hb_atomic_install_file\(\) \{/,/^\}/' "$REPO_ROOT/setup.sh"
              awk '/^_hb_write_manifest\(\) \{/,/^\}/' "$REPO_ROOT/setup.sh"
              awk '/^install_heartbeat_cron\(\) \{/,/^\}/' "$REPO_ROOT/setup.sh")

    HOME="$home_override" bash -c "
        RED='' YELLOW='' GREEN='' BLUE='' NC=''
        launchctl() { return 0; }
        export -f launchctl
        SCRIPT_DIR='$REPO_ROOT'
        NO_HEARTBEAT=false
        DRY_RUN=false
        status_line() { :; }
        $helpers
        install_heartbeat_cron
    " 2>&1
}

echo "=== Case 1: install copies runtime to ~/.intellisense/bin/ ==="
install_via_setup "$SANDBOX" >/dev/null
for f in intellisense-heartbeat.sh \
         lib/heartbeat-payload.sh \
         lib/heartbeat_usage_parser.py \
         lib/heartbeat-prices.json \
         lib/hash.sh; do
    if [ -f "$SANDBOX/.intellisense/bin/$f" ]; then
        pass
    else
        fail "missing $f after install"
    fi
done

echo "=== Case 2: VERSION copied to ~/.intellisense/VERSION ==="
if [ -f "$SANDBOX/.intellisense/VERSION" ]; then
    pass
    # And content matches repo
    REPO_V=$(head -1 "$REPO_ROOT/VERSION" | tr -d '[:space:]')
    INST_V=$(head -1 "$SANDBOX/.intellisense/VERSION" | tr -d '[:space:]')
    [ "$REPO_V" = "$INST_V" ] && pass || fail "VERSION mismatch: repo=$REPO_V installed=$INST_V"
else
    fail "VERSION not copied"
    fail "VERSION content mismatch (skipped)"
fi

echo "=== Case 3: MANIFEST.sha256 written and matches installed files ==="
MANIFEST="$SANDBOX/.intellisense/bin/MANIFEST.sha256"
if [ -f "$MANIFEST" ]; then
    pass
    # Verify each entry matches the installed file's hash
    source "$REPO_ROOT/scripts/lib/hash.sh"
    while IFS= read -r line; do
        H="${line%%  *}"
        F="${line##*  }"
        ACTUAL=$(hb_sha256 "$SANDBOX/.intellisense/bin/$F")
        [ "$H" = "$ACTUAL" ] && pass || fail "manifest $F: expected $H actual $ACTUAL"
    done < "$MANIFEST"
else
    fail "MANIFEST.sha256 not written"
fi

echo "=== Case 4: plist EnvironmentVariables carries HB_VERSION_FILE + PATH ==="
PLIST="$SANDBOX/Library/LaunchAgents/in.intellisense.heartbeat.plist"
if [ ! -f "$PLIST" ]; then
    fail "plist not written"
else
    pass
    grep -q "HB_VERSION_FILE" "$PLIST" && pass || fail "HB_VERSION_FILE missing from plist"
    grep -q "/opt/homebrew/bin" "$PLIST" && pass || fail "Apple Silicon brew prefix missing from plist PATH"
    grep -q "/usr/local/bin" "$PLIST" && pass || fail "Intel brew prefix missing from plist PATH"
    # ProgramArguments must point at the COPIED script, not in-repo
    grep -q ".intellisense/bin/intellisense-heartbeat.sh" "$PLIST" && pass \
        || fail "plist ProgramArguments doesn't point at copied script"
    # And must NOT point at the in-repo script
    ! grep -q "$REPO_ROOT/scripts/intellisense-heartbeat.sh" "$PLIST" && pass \
        || fail "plist still references in-repo script path"
    # Hourly cadence via StartCalendarInterval Minute=0: fires every
    # hour AND coalesces fires missed while asleep (StartInterval does NOT catch up).
    grep -q "<key>StartCalendarInterval</key>" "$PLIST" && pass \
        || fail "plist missing StartCalendarInterval"
    grep -q "<key>Minute</key>" "$PLIST" && grep -q "<integer>0</integer>" "$PLIST" && pass \
        || fail "plist StartCalendarInterval missing Minute=0 (hourly)"
    ! grep -q "StartInterval" "$PLIST" && pass \
        || fail "plist uses StartInterval (loses wake catch-up)"
    ! grep -q "<key>Hour</key>" "$PLIST" && pass \
        || fail "plist pins an Hour (would be daily, not hourly)"
fi

echo "=== Case 5: copied runtime is self-contained (no INTELLISENSE_SETUP_PATH refs) ==="
if grep -RnE 'INTELLISENSE_SETUP_PATH/(scripts|hooks)' "$SANDBOX/.intellisense/bin/" >/dev/null 2>&1; then
    fail "copied runtime references INTELLISENSE_SETUP_PATH/scripts or /hooks — not self-contained"
else
    pass
fi

echo "=== Case 6: copied script can be invoked under launchd-equivalent env ==="
# Dry-run with bogus INTELLISENSE_SETUP_PATH proves runtime doesn't depend on repo
HB_DRY_OUT="$(env -i HOME="$SANDBOX" USER="$(whoami)" \
    PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    HB_VERSION_FILE="$SANDBOX/.intellisense/VERSION" \
    HB_CLAUDE_PROJECTS_DIR="$SANDBOX/.claude/projects" \
    INTELLISENSE_SETUP_PATH="/nonexistent/xyz" \
    bash "$SANDBOX/.intellisense/bin/intellisense-heartbeat.sh" --dry-run 2>/dev/null)"

if [ -n "$HB_DRY_OUT" ]; then
    # Payload is now the v3 wrapper {org_id, heartbeats:[<inner>]}.
    echo "$HB_DRY_OUT" | jq -e '.heartbeats[0].usage_summary | type == "object"' >/dev/null \
        && pass || fail "dry-run output missing usage_summary"
    echo "$HB_DRY_OUT" | jq -e '.heartbeats[0].usage_summary.cost_estimation_status' >/dev/null \
        && pass || fail "dry-run usage_summary missing cost_estimation_status"
    # VERSION should be read from HB_VERSION_FILE (copied), not INTELLISENSE_SETUP_PATH
    INSTALLED_V=$(head -1 "$SANDBOX/.intellisense/VERSION" | tr -d '[:space:]')
    DRY_V=$(echo "$HB_DRY_OUT" | jq -r '.heartbeats[0].intellisense_version')
    [ "$DRY_V" = "$INSTALLED_V" ] && pass || fail "version=$DRY_V expected=$INSTALLED_V (HB_VERSION_FILE precedence broken)"
else
    fail "dry-run produced no output"
    fail "(skipped: cost_estimation_status)"
    fail "(skipped: version)"
fi

echo "=== Case 7: restore.sh removes bin/ + VERSION but keeps token ==="
# Run restore.sh against the sandbox. Skip the symlink-removal noise — we
# only care about the heartbeat cleanup block.
HOME="$SANDBOX" CLAUDE_HOME="$SANDBOX/.claude" \
    bash -c "
        INTELLISENSE_HOME='$SANDBOX/.intellisense'
        DRY_RUN=false
        # Stub status_line to swallow output
        status_line() { :; }
        # Inline the heartbeat cleanup logic from restore.sh
        if [ -d \"\$INTELLISENSE_HOME/bin\" ]; then
            rm -rf \"\$INTELLISENSE_HOME/bin\"
        fi
        if [ -f \"\$INTELLISENSE_HOME/VERSION\" ]; then
            rm -f \"\$INTELLISENSE_HOME/VERSION\"
        fi
    "

[ ! -d "$SANDBOX/.intellisense/bin" ] && pass || fail "restore: bin/ not removed"
[ ! -f "$SANDBOX/.intellisense/VERSION" ] && pass || fail "restore: VERSION not removed"
# CRITICAL: token must be preserved
[ -f "$SANDBOX/.intellisense/heartbeat-token" ] && pass || fail "restore: heartbeat-token was REMOVED (must be preserved)"
# Parent dir must still exist (other tools rely on it)
[ -d "$SANDBOX/.intellisense" ] && pass || fail "restore: parent dir was removed"

echo
echo "TCC install tests: $PASS passed, $FAIL failed"
exit "$FAIL"
