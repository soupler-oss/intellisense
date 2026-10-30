#!/usr/bin/env bash
# tests/test_heartbeat_systemd_timer.sh
#
# Tests for the Linux scheduler selection in setup.sh install_heartbeat_cron()
# Linux now prefers a systemd --user timer with Persistent=true
# so a run missed while the laptop is off/asleep at 09:00 catches up on next
# boot/resume; it falls back to crontab when systemd --user is unavailable.
#
# Strategy: extract install_heartbeat_cron() from setup.sh, stub its heavy
# dependencies (runtime copy, manifest, github login, status_line) and the
# external scheduler commands (systemctl/loginctl/crontab) onto a fake PATH,
# point HOME at a tmpdir, force uname=Linux, then assert which scheduler path
# is taken. The systemd-vs-fallback decision hinges on whether
# `systemctl --user show-environment` succeeds — the same signal that
# distinguishes a real laptop from a headless CI box.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# Extract the function under test once.
FN_FILE="$(mktemp)"
sed -n '/^install_heartbeat_cron() {/,/^}/p' "$SETUP" > "$FN_FILE"
trap 'rm -f "$FN_FILE"' EXIT
[[ -s "$FN_FILE" ]] || { echo "could not extract install_heartbeat_cron"; exit 1; }

# ── Shared driver: runs the function in an isolated env with a fake PATH ──────
# $1 = mode: "systemd_ok" | "no_user_systemd" | "enable_disabled"
# Echoes the temp HOME so the caller can assert on the filesystem result.
run_case() {
  local mode="$1"
  local home fakebin calls
  home="$(mktemp -d)"
  fakebin="$(mktemp -d)"
  calls="$home/calls.log"

  # token precondition (install bails early without it)
  mkdir -p "$home/.intellisense"
  echo "dummy-token" > "$home/.intellisense/heartbeat-token"

  # ── fake uname → always Linux ──
  cat > "$fakebin/uname" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "-s" ]] && { echo Linux; exit 0; }
echo Linux
EOF

  # ── fake systemctl ──
  if [[ "$mode" == "systemd_ok" ]]; then
    # Healthy box: user instance present, enable + is-enabled + list-timers all
    # report a live, enabled timer with a future trigger.
    cat > "$fakebin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$calls"
case "\$*" in
  "--user show-environment") exit 0 ;;
  "--user is-enabled intellisense-heartbeat.timer") echo "enabled"; exit 0 ;;
  "--user list-timers"*) echo "Mon 2026-06-15 09:00:00 UTC  12h left  intellisense-heartbeat.timer intellisense-heartbeat.service"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
    cat > "$fakebin/loginctl" <<EOF
#!/usr/bin/env bash
echo "loginctl \$*" >> "$calls"
exit 0
EOF
  elif [[ "$mode" == "enable_disabled" ]]; then
    # The real-world bug: user instance present, enable --now
    # returns success, but the unit is NOT actually enabled (no XDG_RUNTIME_DIR
    # bus / enable symlink never written). Verification must catch this and the
    # installer must fall back to cron.
    cat > "$fakebin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$calls"
case "\$*" in
  "--user show-environment") exit 0 ;;
  "--user is-enabled intellisense-heartbeat.timer") echo "disabled"; exit 1 ;;
  "--user list-timers"*) echo "0 timers listed."; exit 0 ;;
  *) exit 0 ;;
esac
EOF
    cat > "$fakebin/loginctl" <<EOF
#!/usr/bin/env bash
echo "loginctl \$*" >> "$calls"
exit 0
EOF
  else
    # systemctl exists but has no usable user instance → show-environment fails
    cat > "$fakebin/systemctl" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >> "$calls"
case "\$*" in
  "--user show-environment") exit 1 ;;
  *) exit 0 ;;
esac
EOF
  fi

  # ── fake crontab: record install target contents ──
  cat > "$fakebin/crontab" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-l" ]]; then exit 0; fi          # empty existing crontab
if [[ "\$1" == "-" ]]; then cat > "$home/crontab.installed"; echo "crontab -" >> "$calls"; exit 0; fi
cat "\$1" > "$home/crontab.installed"; echo "crontab file" >> "$calls"; exit 0
EOF

  chmod +x "$fakebin"/*

  (
    export HOME="$home"
    export PATH="$fakebin:$PATH"
    export SCRIPT_DIR="$REPO_ROOT"
    export NO_HEARTBEAT=false DRY_RUN=false
    export RED='' YELLOW='' GREEN='' NC='' BLUE='' DIM=''
    # Optional anacron dir override so the crontab-vs-anacron
    # ordering is testable without a root-owned /etc/anacrontab.d.
    [[ -n "${TEST_ANACRON_DIR:-}" ]] && export INTELLISENSE_ANACRON_DIR="$TEST_ANACRON_DIR"
    # stub heavy deps
    status_line() { :; }
    resolve_github_login() { echo "TESTUSER"; }
    _hb_atomic_install_file() { :; }
    _hb_write_manifest() { :; }
    _hb_install_post_merge_hook() { :; }
    # shellcheck disable=SC1090
    source "$FN_FILE"
    install_heartbeat_cron
  ) >/dev/null 2>&1

  echo "$home"
}

# ── Case 1: systemd --user available → timer install ─────────────────────────
echo "=== Case 1: systemd --user available → Persistent timer installed ==="
H1="$(run_case systemd_ok)"
UD="$H1/.config/systemd/user"
[[ -f "$UD/intellisense-heartbeat.timer" ]]   && pass "timer unit written"   || fail "timer unit missing"
[[ -f "$UD/intellisense-heartbeat.service" ]] && pass "service unit written" || fail "service unit missing"
grep -q 'Persistent=true' "$UD/intellisense-heartbeat.timer" 2>/dev/null \
  && pass "timer has Persistent=true" || fail "Persistent=true missing"
grep -q 'OnCalendar=hourly' "$UD/intellisense-heartbeat.timer" 2>/dev/null \
  && pass "timer fires hourly" || fail "OnCalendar=hourly missing"
grep -q 'enable --now intellisense-heartbeat.timer' "$H1/calls.log" 2>/dev/null \
  && pass "timer enabled+started" || fail "enable --now not called"
grep -q 'loginctl enable-linger' "$H1/calls.log" 2>/dev/null \
  && pass "linger enabled" || fail "enable-linger not called"
# The timer path runs `crontab -` to STRIP any stale intellisense-heartbeat line, so an
# (empty) crontab file may be written — assert the heartbeat cron line is NOT in it.
if [[ -f "$H1/crontab.installed" ]] && grep -q 'intellisense-heartbeat' "$H1/crontab.installed"; then
  fail "heartbeat cron line installed on timer path (should be stripped)"
else
  pass "no heartbeat cron line on timer path (stale line stripped)"
fi
rm -rf "$H1"

# ── Case 2: no usable user systemd → crontab fallback ────────────────────────
echo "=== Case 2: no user systemd → crontab fallback ==="
H2="$(run_case no_user_systemd)"
[[ ! -d "$H2/.config/systemd/user" ]] || [[ ! -f "$H2/.config/systemd/user/intellisense-heartbeat.timer" ]] \
  && pass "no systemd timer written" || fail "timer written despite no user systemd"
if [[ -f "$H2/crontab.installed" ]] && grep -q '0 9 \* \* \* .*intellisense-heartbeat' "$H2/crontab.installed"; then
  pass "crontab fallback installed daily 09:00 line"
else
  fail "crontab fallback line missing"
fi
grep -q '@reboot .*intellisense-heartbeat' "$H2/crontab.installed" 2>/dev/null \
  && pass "crontab fallback includes @reboot catch-up line" || fail "@reboot line missing"
grep -q '0 \* \* \* \* .*intellisense-heartbeat' "$H2/crontab.installed" 2>/dev/null \
  && pass "crontab fallback includes hourly catch-up probe" || fail "hourly probe line missing"
rm -rf "$H2"

# ── Case 3: enable returns OK but timer stays disabled ─────────
# Verification must detect is-enabled=disabled and fall back to cron.
echo "=== Case 3: systemd enable 'succeeds' but timer disabled → cron fallback ==="
H3="$(run_case enable_disabled)"
grep -q 'is-enabled intellisense-heartbeat.timer' "$H3/calls.log" 2>/dev/null \
  && pass "installer verified is-enabled" || fail "is-enabled never checked"
if [[ -f "$H3/crontab.installed" ]] && grep -q '0 9 \* \* \* .*intellisense-heartbeat' "$H3/crontab.installed"; then
  pass "fell back to crontab daily 09:00 when timer disabled"
else
  fail "no crontab fallback when timer verification failed"
fi
grep -q '@reboot .*intellisense-heartbeat' "$H3/crontab.installed" 2>/dev/null \
  && pass "fallback includes @reboot line" || fail "@reboot line missing on disabled-timer fallback"
grep -q '0 \* \* \* \* .*intellisense-heartbeat' "$H3/crontab.installed" 2>/dev/null \
  && pass "fallback includes hourly probe" || fail "hourly probe missing on disabled-timer fallback"
rm -rf "$H3"

# ── Case 4: anacron present + crontab present → crontab wins ───
# anacron has no sub-daily granularity; with hourly-everywhere we must prefer
# the hourly crontab.
echo "=== Case 4: anacron dir present but crontab preferred (hourly) ==="
ANADIR="$(mktemp -d)"
H4="$(TEST_ANACRON_DIR="$ANADIR" run_case no_user_systemd)"
if [[ -f "$H4/crontab.installed" ]] && grep -q '0 \* \* \* \* .*intellisense-heartbeat' "$H4/crontab.installed"; then
  pass "chose hourly crontab over anacron @daily"
else
  fail "did not prefer crontab when anacron dir present"
fi
! find "$ANADIR" -maxdepth 1 -name 'intellisense-heartbeat' | grep -q . \
  && pass "no anacron @daily job written when crontab available" \
  || fail "anacron job written despite crontab availability"
rm -rf "$H4" "$ANADIR"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
