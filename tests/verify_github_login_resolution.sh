#!/usr/bin/env bash
# tests/verify_github_login_resolution.sh
#
# Per-fallback real verification matrix for the github_login resolution chain
# added in setup.sh. No mocks of the resolver itself — each
# scenario forces ONE step of the 5-step chain to win by manipulating real
# conditions (env, git config, SSH, $PWD, TTY) and asserts on the actual
# resolve_github_login output. One end-to-end case wires the resolver into
# install_heartbeat_cron and reads the produced plist via plutil to confirm
# the value reaches the launchd EnvironmentVariables dictionary.
#
# This complements the unit-level guardrails in tests/test_heartbeat_payload.sh
# (Cases 5e/5f) which test hb_github_login in isolation. THIS script tests the
# install → plist → cron-env path that actually broke in production.
#
# Run:    bash tests/verify_github_login_resolution.sh
# Network step (V2 — ssh -T github.com) is gated by INTELLISENSE_VERIFY_NETWORK=1.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"

PASS=0; FAIL=0; SKIP=0
fail()  { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass()  { PASS=$((PASS+1)); echo "✓ PASS: $*"; }
skip()  { SKIP=$((SKIP+1)); echo "⏭  SKIP: $*"; }

# Extract the resolver function on its own — the per-step tests source ONLY this.
RESOLVE_FN="$(mktemp)"
sed -n '/^resolve_github_login() {/,/^}/p' "$SETUP" > "$RESOLVE_FN"
grep -q '^resolve_github_login()' "$RESOLVE_FN" \
  || { echo "FATAL: could not extract resolve_github_login from setup.sh"; exit 2; }

# For the end-to-end plist case we also need install_heartbeat_cron plus its
# private helpers (_hb_atomic_install_file etc.). We stub those instead of
# extracting them — file-copy correctness is covered in test_setup_e2e.sh and
# is not the subject of this verification matrix.
CRON_FN="$(mktemp)"
sed -n '/^install_heartbeat_cron() {/,/^}/p' "$SETUP" > "$CRON_FN"
grep -q '^install_heartbeat_cron()' "$CRON_FN" \
  || { echo "FATAL: could not extract install_heartbeat_cron"; exit 2; }

trap 'rm -f "$RESOLVE_FN" "$CRON_FN"' EXIT

# Convenience: run the resolver under controlled env. Returns the resolver's
# stdout (the resolved login, or empty).
resolve_with() {
  local fake_home="$1"
  local fake_pwd="$2"
  local env_override="$3"      # value for INTELLISENSE_GH_LOGIN, or "" to unset
  local ssh_neutralize="$4"    # "1" to stub ssh, "0" to allow real network
  local git_email="$5"         # value to write to ~/.gitconfig user.email
  local stdin_input="${6:-}"   # piped to the prompt when TTY check is off

  mkdir -p "$fake_home"
  if [[ -n "$git_email" ]]; then
    cat > "$fake_home/.gitconfig" <<EOF
[user]
        email = $git_email
EOF
  else
    rm -f "$fake_home/.gitconfig"
  fi

  local ssh_stub=""
  [[ "$ssh_neutralize" == "1" ]] && ssh_stub='ssh() { return 1; }; export -f ssh;'

  local env_line
  if [[ -n "$env_override" ]]; then
    env_line="export INTELLISENSE_GH_LOGIN='$env_override';"
  else
    env_line="unset INTELLISENSE_GH_LOGIN;"
  fi

  HOME="$fake_home" \
  PWD_INIT="$fake_pwd" \
  bash -c "
    $ssh_stub
    $env_line
    cd \"\$PWD_INIT\"
    source '$RESOLVE_FN'
    resolve_github_login
  " <<<"$stdin_input" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════════════════
echo "=== V1: step 2 — \$PWD origin URL (forked intellisense clone, SSH form) ==="
TMP=$(mktemp -d)
FAKE_REPO="$TMP/fork-clone"
git init -q "$FAKE_REPO"
git -C "$FAKE_REPO" remote add origin git@github.com:test-github-login/intellisense.git
VAL=$(resolve_with "$TMP" "$FAKE_REPO" "" "1" "")
[[ "$VAL" == "test-github-login" ]] \
  && pass "V1: origin URL (SSH form) parsed → '$VAL'" \
  || fail "V1: expected 'test-github-login', got '$VAL'"
rm -rf "$TMP"

echo "=== V1b: step 1 — origin URL HTTPS form ==="
TMP=$(mktemp -d)
FAKE_REPO="$TMP/fork-clone"
git init -q "$FAKE_REPO"
git -C "$FAKE_REPO" remote add origin https://github.com/test-github-login/intellisense.git
VAL=$(resolve_with "$TMP" "$FAKE_REPO" "" "1" "")
[[ "$VAL" == "test-github-login" ]] \
  && pass "V1b: origin URL (HTTPS form) parsed → '$VAL'" \
  || fail "V1b: expected 'test-github-login', got '$VAL'"
rm -rf "$TMP"

echo "=== V1c: step 1 — upstream-org owner filtered (soupler-oss) ==="
TMP=$(mktemp -d)
FAKE_REPO="$TMP/upstream-clone"
git init -q "$FAKE_REPO"
git -C "$FAKE_REPO" remote add origin git@github.com:soupler-oss/intellisense.git
# No SSH (stubbed), no env, no email — example-org must be rejected and chain ends empty
VAL=$(resolve_with "$TMP" "$FAKE_REPO" "" "1" "")
[[ "$VAL" != "example-org" ]] \
  && pass "V1c: 'example-org' upstream owner filtered (got '$VAL', not 'example-org')" \
  || fail "V1c: upstream org 'example-org' slipped through as login"
rm -rf "$TMP"

# ═══════════════════════════════════════════════════════════════════════════
echo "=== V2: step 3 — ssh -T git@github.com (real network, gated) ==="
if [[ "${INTELLISENSE_VERIFY_NETWORK:-0}" != "1" ]]; then
  skip "V2: gated by INTELLISENSE_VERIFY_NETWORK=1 — run manually to verify the SSH-key path against real github.com"
else
  EXPECTED_REAL=$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 git@github.com 2>&1 \
    | sed -nE 's/^Hi ([A-Za-z0-9._-]+)!.*/\1/p')
  if [[ -z "$EXPECTED_REAL" ]]; then
    skip "V2: ssh -T returned no greeting (no GitHub-registered key, or network blocked)"
  else
    TMP=$(mktemp -d)
    FAKE_REPO="$TMP/no-origin"
    mkdir -p "$FAKE_REPO"  # not a git repo → step 1 empty
    # ssh_neutralize=0 — let the real ssh run
    VAL=$(resolve_with "$TMP" "$FAKE_REPO" "" "0" "")
    [[ "$VAL" == "$EXPECTED_REAL" ]] \
      && pass "V2: ssh -T returned '$EXPECTED_REAL', resolver matches" \
      || fail "V2: ssh said '$EXPECTED_REAL' but resolver returned '$VAL'"
    rm -rf "$TMP"
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
echo "=== V3: step 1 — \$INTELLISENSE_GH_LOGIN env override ==="
TMP=$(mktemp -d)
FAKE_REPO="$TMP/no-origin"
mkdir -p "$FAKE_REPO"
VAL=$(resolve_with "$TMP" "$FAKE_REPO" "ci-injected-user" "1" "")
[[ "$VAL" == "ci-injected-user" ]] \
  && pass "V3: env override 'ci-injected-user' returned by resolver" \
  || fail "V3: expected 'ci-injected-user', got '$VAL'"
rm -rf "$TMP"

# ═══════════════════════════════════════════════════════════════════════════
echo "=== V4: step 4 — interactive prompt is skipped when stdin is non-TTY ==="
# We can't easily simulate a real TTY in a unit test, but we CAN assert the
# resolver does NOT block waiting for input when stdin is /dev/null (because
# the [[ -t 0 ]] guard correctly returns false). If the guard were absent,
# the bash subshell would hang on `read`.
TMP=$(mktemp -d)
FAKE_REPO="$TMP/no-origin"
mkdir -p "$FAKE_REPO"
# Empty everything: no origin, no ssh, no env, no email.
# Expected: resolver returns empty without prompting (stdin is heredoc, not TTY).
START_TS=$(date +%s)
VAL=$(resolve_with "$TMP" "$FAKE_REPO" "" "1" "" "")
END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
if [[ -z "$VAL" && $ELAPSED -lt 5 ]]; then
  pass "V4: resolver returned empty in ${ELAPSED}s without hanging on prompt (TTY guard works)"
else
  fail "V4: resolver got '$VAL' in ${ELAPSED}s — TTY guard may be broken or another step matched"
fi
rm -rf "$TMP"

# ═══════════════════════════════════════════════════════════════════════════
echo "=== V5: step 5 — email local-part safety net ==="
TMP=$(mktemp -d)
FAKE_REPO="$TMP/no-origin"
mkdir -p "$FAKE_REPO"  # not a git repo → step 1 empty
VAL=$(resolve_with "$TMP" "$FAKE_REPO" "" "1" "test.user@example.com")
[[ "$VAL" == "test.user" ]] \
  && pass "V5: email local-part 'test.user' used when all prior steps fail" \
  || fail "V5: expected 'test.user' (safety net), got '$VAL'"
rm -rf "$TMP"

# ═══════════════════════════════════════════════════════════════════════════
echo "=== V6: precedence — env override beats email when both present ==="
TMP=$(mktemp -d)
FAKE_REPO="$TMP/no-origin"
mkdir -p "$FAKE_REPO"
VAL=$(resolve_with "$TMP" "$FAKE_REPO" "test-github-login" "1" "test.user@example.com")
[[ "$VAL" == "test-github-login" ]] \
  && pass "V6: env override wins over email (got '$VAL', not 'test.user')" \
  || fail "V6: precedence violated; got '$VAL'"
rm -rf "$TMP"

# ═══════════════════════════════════════════════════════════════════════════
echo "=== V7: precedence — origin URL beats email when both present ==="
TMP=$(mktemp -d)
FAKE_REPO="$TMP/fork-clone"
git init -q "$FAKE_REPO"
git -C "$FAKE_REPO" remote add origin git@github.com:test-github-login/intellisense.git
VAL=$(resolve_with "$TMP" "$FAKE_REPO" "" "1" "test.user@example.com")
[[ "$VAL" == "test-github-login" ]] \
  && pass "V7: origin URL wins over email (got '$VAL')" \
  || fail "V7: expected 'test-github-login', got '$VAL'"
rm -rf "$TMP"

# ═══════════════════════════════════════════════════════════════════════════
# End-to-end: confirm the resolved value lands in the launchd plist
# EnvironmentVariables dict — the actual mechanism by which the cron picks
# up the value at fire time. Stubs the file-copy helpers and launchctl so we
# isolate the plist-write path; resolver is real, plist parsing is real.
echo "=== V8: end-to-end — resolved login lands in launchd plist EnvironmentVariables ==="
if [[ "$(uname -s)" != "Darwin" ]]; then
  skip "V8: Darwin-only path (plutil + launchd); Linux coverage is via crontab in test_setup_e2e.sh"
else
  TMP=$(mktemp -d)
  FAKE_REPO="$TMP/fork-clone"
  git init -q "$FAKE_REPO"
  git -C "$FAKE_REPO" remote add origin git@github.com:test-github-login/intellisense.git
  mkdir -p "$TMP/.intellisense"
  printf 'token-for-test' > "$TMP/.intellisense/heartbeat-token"
  chmod 600 "$TMP/.intellisense/heartbeat-token"

  OUT=$(
    HOME="$TMP" \
    PWD_INIT="$FAKE_REPO" \
    NO_HEARTBEAT=false \
    DRY_RUN=false \
    SCRIPT_DIR="$REPO_ROOT" \
    bash -c "
      YELLOW=''; RED=''; NC=''
      status_line() { echo \"[\$1] \$2\"; }
      ssh() { return 1; }; export -f ssh
      unset INTELLISENSE_GH_LOGIN
      # Stub the file-copy helpers so install_heartbeat_cron focuses on the plist.
      _hb_atomic_install_file() { return 0; }
      _hb_write_manifest()      { return 0; }
      _hb_install_post_merge_hook() { return 0; }
      launchctl() { return 0; }
      cd \"\$PWD_INIT\"
      source '$RESOLVE_FN'
      source '$CRON_FN'
      install_heartbeat_cron
    " 2>&1
  )
  PLIST="$TMP/Library/LaunchAgents/in.intellisense.heartbeat.plist"
  if [[ ! -f "$PLIST" ]]; then
    fail "V8: plist not written. install_heartbeat_cron output:\n$OUT"
  else
    VAL=$(plutil -extract EnvironmentVariables.INTELLISENSE_GH_LOGIN raw -o - "$PLIST" 2>/dev/null || echo "")
    [[ "$VAL" == "test-github-login" ]] \
      && pass "V8: plist EnvironmentVariables.INTELLISENSE_GH_LOGIN='$VAL'" \
      || fail "V8: plist has INTELLISENSE_GH_LOGIN='$VAL' (expected 'test-github-login')"
    # Adjacent keys must survive the injection.
    for k in HB_VERSION_FILE INTELLISENSE_SETUP_PATH PATH; do
      plutil -extract "EnvironmentVariables.$k" raw -o - "$PLIST" >/dev/null 2>&1 \
        && pass "V8: existing key '$k' preserved" \
        || fail "V8: existing key '$k' disappeared after injection"
    done
  fi
  rm -rf "$TMP"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Regression: env override must beat the $PWD origin URL. Before the step-1
# promotion the env check sat at step 3, AFTER origin/ssh, so a
# dev who ran `INTELLISENSE_GH_LOGIN=handle bash setup.sh` from a fork clone had the
# override silently discarded — origin won and the wrong handle was baked.
# V6/V7 only cover env-vs-email and origin-vs-email; neither catches this.
echo "=== V9: precedence — env override beats \$PWD origin URL ==="
TMP=$(mktemp -d)
FAKE_REPO="$TMP/fork-clone"
git init -q "$FAKE_REPO"
git -C "$FAKE_REPO" remote add origin git@github.com:test-github-login/intellisense.git
# env set AND origin present (origin would resolve to test-github-login) → env wins.
VAL=$(resolve_with "$TMP" "$FAKE_REPO" "admin-override" "1" "")
[[ "$VAL" == "admin-override" ]] \
  && pass "V9: env override beats origin URL (got '$VAL', not 'test-github-login')" \
  || fail "V9: env override lost to origin URL — install-time ordering bug reappears; got '$VAL'"
rm -rf "$TMP"

# ═══════════════════════════════════════════════════════════════════════════
# Regression: install_heartbeat_cron must EXPORT the resolved login so the
# post-install "fire once" subshell inherits it. Before the fix
# the value was a local baked only into the plist/cron; the immediate run
# re-resolved via hb_github_login (no origin-URL step) and fell to the email
# local-part on first-time machines without gh. We run the REAL
# install_heartbeat_cron, then read INTELLISENSE_GH_LOGIN from a child subshell — the
# exact mechanism the fire-once at the end of setup.sh relies on.
echo "=== V10: install_heartbeat_cron exports login for the fire-once subshell ==="
TMP=$(mktemp -d)
FAKE_REPO="$TMP/fork-clone"
git init -q "$FAKE_REPO"
git -C "$FAKE_REPO" remote add origin git@github.com:test-github-login/intellisense.git
mkdir -p "$TMP/.intellisense"
printf 'token-for-test' > "$TMP/.intellisense/heartbeat-token"
chmod 600 "$TMP/.intellisense/heartbeat-token"
EXPORTED=$(
  HOME="$TMP" \
  PWD_INIT="$FAKE_REPO" \
  NO_HEARTBEAT=false \
  DRY_RUN=false \
  SCRIPT_DIR="$REPO_ROOT" \
  bash -c "
    YELLOW=''; RED=''; BLUE=''; NC=''
    status_line() { :; }
    ssh() { return 1; }; export -f ssh
    unset INTELLISENSE_GH_LOGIN
    _hb_atomic_install_file()     { return 0; }
    _hb_write_manifest()          { return 0; }
    _hb_install_post_merge_hook() { return 0; }
    launchctl() { return 0; }
    crontab()   { return 0; }
    cd \"\$PWD_INIT\"
    source '$RESOLVE_FN'
    source '$CRON_FN'
    install_heartbeat_cron >/dev/null 2>&1
    # mimic the fire-once: a child subshell must see the inherited value
    ( printf '%s' \"\${INTELLISENSE_GH_LOGIN:-}\" )
  " 2>/dev/null
)
[[ "$EXPORTED" == "test-github-login" ]] \
  && pass "V10: fire-once subshell inherits INTELLISENSE_GH_LOGIN='$EXPORTED' (not email/empty)" \
  || fail "V10: fire-once would not inherit login — first-run email-prefix bug reappears; got '$EXPORTED'"
rm -rf "$TMP"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "═══════════════════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "═══════════════════════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
