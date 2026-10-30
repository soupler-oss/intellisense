#!/bin/bash
# tests/test_crg_brew_bootstrap.sh — Regression harness.
#
# Verifies _crg_bootstrap_runner_via_brew exhibits the right behavior for
# every PATH/brew combination that matters in production. Hermetic: never
# runs `brew install` for real — `command -v` and `brew` are overridden via
# shell function shadows so we control which tools "exist".
#
# Cases:
#   T1 uv present                     → no-op (return 0, no echo, no install)
#   T2 pipx present                   → no-op (return 0)
#   T3 neither present, brew absent   → no-op (return 0)
#   T4 neither + brew, install OK     → bootstrap runs, pipx becomes "present", returns 0
#   T5 neither + brew, install FAILS  → bootstrap runs, returns 1 (caller falls through)
#   T6 idempotency: T1 path twice     → second call still no-op

set -u
INTELLISENSE_SETUP="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

case_pass() { echo "  ✓ $1"; echo "P" >> "$RESULTS"; }
case_fail() { echo "  ✗ $1: $2"; echo "F" >> "$RESULTS"; }

# Pull the helper out of setup.sh without sourcing the entire file (which
# would run the user-detection / git-fork enforcement / etc.).
extract_func() {
  local file="$1" name="$2"
  awk -v fn="$name" '
    !in_fn && $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" {
      in_fn = 1
      depth = gsub(/\{/, "{") - gsub(/\}/, "}")
      print
      next
    }
    in_fn {
      print
      depth += gsub(/\{/, "{") - gsub(/\}/, "}")
      if (depth <= 0) exit
    }
  ' "$file"
}

eval "$(extract_func "$INTELLISENSE_SETUP/setup.sh" _crg_bootstrap_runner_via_brew)"

# File-based mock state. The helper invokes `brew install pipx | tail -3`
# which runs in a subshell — variable mutations don't propagate back. So we
# persist "which tools are present" and "should brew succeed?" in temp files
# that survive subshell boundaries.
MOCK_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/crg-brew-test.XXXXXX")"
PRESENT_TOOLS_FILE="$MOCK_STATE_DIR/present-tools"
BREW_FLAGS_FILE="$MOCK_STATE_DIR/brew-flags"
trap 'rm -f "$RESULTS"; rm -rf "$MOCK_STATE_DIR"' EXIT

reset_mocks() {
  : > "$PRESENT_TOOLS_FILE"
  printf 'BREW_INSTALL_RESULT=0\nPIPX_GETS_INSTALLED=false\n' > "$BREW_FLAGS_FILE"
  # Default brew prefix → /opt/homebrew (macOS Apple Silicon). Per-test
  # overrides via set_brew_prefix.
  set_brew_prefix "$MOCK_STATE_DIR/opt/homebrew"
}

# Mock `command -v` against the persisted PRESENT_TOOLS_FILE (one tool per line).
command() {
  if [ "$1" = "-v" ]; then
    if grep -qx "$2" "$PRESENT_TOOLS_FILE" 2>/dev/null; then
      echo "/mock/path/$2"
      return 0
    fi
    return 1
  fi
  builtin command "$@"
}

# Mock `brew` against the persisted state files. Supports two subcommands:
#   brew --prefix    → echoes contents of $MOCK_STATE_DIR/brew-prefix
#                       (empty/missing simulates `brew --prefix` failure)
#   brew install <p> → consults BREW_FLAGS_FILE; on success appends pkg to
#                       PRESENT_TOOLS_FILE so subsequent `command -v` finds it
brew() {
  if [ "$1" = "--prefix" ]; then
    if [ -s "$MOCK_STATE_DIR/brew-prefix" ]; then
      cat "$MOCK_STATE_DIR/brew-prefix"
      return 0
    fi
    return 1
  fi
  if [ "$1" = "install" ] && [ "$2" = "pipx" ]; then
    # shellcheck disable=SC1090
    . "$BREW_FLAGS_FILE"
    if [ "$BREW_INSTALL_RESULT" = "0" ] && [ "$PIPX_GETS_INSTALLED" = "true" ]; then
      echo "pipx" >> "$PRESENT_TOOLS_FILE"
      echo "==> Installing pipx (mocked)"
      return 0
    fi
    echo "Error: brew install pipx failed (mocked)"
    return "$BREW_INSTALL_RESULT"
  fi
  return 0
}

# Helper to set the mocked brew --prefix output. Empty arg → simulate
# `brew --prefix` failure (corrupted install).
set_brew_prefix() {
  if [ -z "${1:-}" ]; then
    : > "$MOCK_STATE_DIR/brew-prefix"
  else
    # Create the directory too — helper checks `[ -d "$brew_prefix" ]`.
    mkdir -p "$1"
    echo "$1" > "$MOCK_STATE_DIR/brew-prefix"
  fi
}

# Mock pipx ensurepath as a no-op so the helper doesn't try to run real pipx.
pipx() {
  if [ "$1" = "ensurepath" ]; then return 0; fi
  return 0
}

export -f command brew pipx

set_present() {
  : > "$PRESENT_TOOLS_FILE"
  for t in "$@"; do echo "$t" >> "$PRESENT_TOOLS_FILE"; done
}

# ─── T1: uv present → no-op ─────────────────────────────────────────────────
echo "T1 uv present → no-op"
reset_mocks
set_present uv
output="$(_crg_bootstrap_runner_via_brew 2>&1)"
rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  case_pass "T1 returns 0 silently when uv already present"
else
  case_fail "T1 uv-present no-op" "rc=$rc, output=$output"
fi

# ─── T2: pipx present → no-op ───────────────────────────────────────────────
echo "T2 pipx present → no-op"
reset_mocks
set_present pipx
output="$(_crg_bootstrap_runner_via_brew 2>&1)"
rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  case_pass "T2 returns 0 silently when pipx already present"
else
  case_fail "T2 pipx-present no-op" "rc=$rc, output=$output"
fi

# ─── T3: neither present, brew absent → no-op ───────────────────────────────
echo "T3 no runner + no brew → no-op"
reset_mocks
set_present
output="$(_crg_bootstrap_runner_via_brew 2>&1)"
rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  case_pass "T3 returns 0 silently when brew is unavailable (cannot bootstrap)"
else
  case_fail "T3 no-brew no-op" "rc=$rc, output=$output"
fi

# ─── T4: neither + brew + install succeeds → bootstrap → returns 0 ──────────
echo "T4 brew available + install succeeds → bootstrap"
reset_mocks
set_present brew
printf 'BREW_INSTALL_RESULT=0\nPIPX_GETS_INSTALLED=true\n' > "$BREW_FLAGS_FILE"
output="$(_crg_bootstrap_runner_via_brew 2>&1)"
rc=$?
if [ "$rc" = "0" ] \
   && echo "$output" | grep -qF "Bootstrapping pipx via Homebrew" \
   && echo "$output" | grep -qF "✓ pipx installed via Homebrew"; then
  case_pass "T4 brew-bootstrap runs, pipx now present, returns 0"
else
  case_fail "T4 brew-bootstrap success" "rc=$rc, output=$output"
fi

# ─── T5: neither + brew + install fails → bootstrap attempted → returns 1 ──
echo "T5 brew available + install fails → soft fail"
reset_mocks
set_present brew
printf 'BREW_INSTALL_RESULT=1\nPIPX_GETS_INSTALLED=false\n' > "$BREW_FLAGS_FILE"
output="$(_crg_bootstrap_runner_via_brew 2>&1)"
rc=$?
if [ "$rc" = "1" ] \
   && echo "$output" | grep -qF "Bootstrapping pipx via Homebrew" \
   && echo "$output" | grep -qF "Falling through"; then
  case_pass "T5 brew install failure → returns 1, falls through with warning"
else
  case_fail "T5 brew-bootstrap failure" "rc=$rc, output=$output"
fi

# ─── T6: idempotency — uv present, two calls both no-op ────────────────────
echo "T6 idempotency"
reset_mocks
set_present uv
_crg_bootstrap_runner_via_brew >/dev/null 2>&1
rc1=$?
_crg_bootstrap_runner_via_brew >/dev/null 2>&1
rc2=$?
if [ "$rc1" = "0" ] && [ "$rc2" = "0" ]; then
  case_pass "T6 two consecutive calls both no-op when runner already present"
else
  case_fail "T6 idempotency" "rc1=$rc1, rc2=$rc2"
fi

# ─── T7: regression — bootstrap is NOT triggered when uv is present even if
#        brew is also present (prefer existing runner over installing pipx) ──
echo "T7 prefer existing runner over brew install"
reset_mocks
set_present uv brew
output="$(_crg_bootstrap_runner_via_brew 2>&1)"
rc=$?
if [ "$rc" = "0" ] && [ -z "$output" ]; then
  case_pass "T7 uv-present + brew-present → no bootstrap (regression guard)"
else
  case_fail "T7 prefer existing runner" "rc=$rc, output=$output"
fi

# ─── T10: macOS Apple Silicon prefix (/opt/homebrew) ────────────────────────
echo "T10 macOS Apple Silicon brew prefix"
reset_mocks
set_present brew
set_brew_prefix "$MOCK_STATE_DIR/opt/homebrew"
printf 'BREW_INSTALL_RESULT=0\nPIPX_GETS_INSTALLED=true\n' > "$BREW_FLAGS_FILE"
output="$(_crg_bootstrap_runner_via_brew 2>&1)"
rc=$?
if [ "$rc" = "0" ] && echo "$output" | grep -qF "$MOCK_STATE_DIR/opt/homebrew"; then
  case_pass "T10 resolves and reports /opt/homebrew prefix in success message"
else
  case_fail "T10 macOS Apple Silicon prefix" "rc=$rc, output=$output"
fi

# ─── T11: Linuxbrew prefix (/home/linuxbrew/.linuxbrew) ─────────────────────
echo "T11 Linuxbrew prefix"
reset_mocks
set_present brew
set_brew_prefix "$MOCK_STATE_DIR/home/linuxbrew/.linuxbrew"
printf 'BREW_INSTALL_RESULT=0\nPIPX_GETS_INSTALLED=true\n' > "$BREW_FLAGS_FILE"
output="$(_crg_bootstrap_runner_via_brew 2>&1)"
rc=$?
if [ "$rc" = "0" ] && echo "$output" | grep -qF "$MOCK_STATE_DIR/home/linuxbrew/.linuxbrew"; then
  case_pass "T11 resolves Linuxbrew prefix correctly (Linux compat)"
else
  case_fail "T11 Linuxbrew prefix" "rc=$rc, output=$output"
fi

# ─── T12: macOS Intel prefix (/usr/local) ───────────────────────────────────
echo "T12 macOS Intel brew prefix"
reset_mocks
set_present brew
set_brew_prefix "$MOCK_STATE_DIR/usr/local"
printf 'BREW_INSTALL_RESULT=0\nPIPX_GETS_INSTALLED=true\n' > "$BREW_FLAGS_FILE"
output="$(_crg_bootstrap_runner_via_brew 2>&1)"
rc=$?
if [ "$rc" = "0" ] && echo "$output" | grep -qF "$MOCK_STATE_DIR/usr/local"; then
  case_pass "T12 resolves /usr/local prefix (macOS Intel)"
else
  case_fail "T12 macOS Intel prefix" "rc=$rc, output=$output"
fi

# ─── T13: brew --prefix returns empty (corrupted install) → soft fail ───────
echo "T13 brew --prefix returns empty"
reset_mocks
set_present brew
set_brew_prefix ""
output="$(_crg_bootstrap_runner_via_brew 2>&1)"
rc=$?
if [ "$rc" = "1" ] \
   && echo "$output" | grep -qF "brew --prefix' did not return a usable directory"; then
  case_pass "T13 brew --prefix failure → returns 1 with clear warning, no install attempted"
else
  case_fail "T13 brew --prefix failure" "rc=$rc, output=$output"
fi

# ─── T14: brew --prefix points to nonexistent dir → soft fail ──────────────
echo "T14 brew --prefix returns invalid path"
reset_mocks
set_present brew
# Write a path that doesn't exist on disk to brew-prefix file.
echo "/nonexistent/brew/prefix-$$" > "$MOCK_STATE_DIR/brew-prefix"
output="$(_crg_bootstrap_runner_via_brew 2>&1)"
rc=$?
if [ "$rc" = "1" ] \
   && echo "$output" | grep -qF "did not return a usable directory"; then
  case_pass "T14 brew --prefix returns invalid path → returns 1 (defense against broken brew)"
else
  case_fail "T14 invalid prefix" "rc=$rc, output=$output"
fi

# ─── T15: PATH includes the resolved brew prefix bin after success ─────────
echo "T15 PATH augmented with resolved brew prefix bin after install"
reset_mocks
set_present brew
set_brew_prefix "$MOCK_STATE_DIR/test-prefix"
printf 'BREW_INSTALL_RESULT=0\nPIPX_GETS_INSTALLED=true\n' > "$BREW_FLAGS_FILE"
# Capture PATH inside a subshell where the helper runs.
captured_path="$(_crg_bootstrap_runner_via_brew >/dev/null 2>&1 && echo "$PATH")"
if echo "$captured_path" | grep -qF "$MOCK_STATE_DIR/test-prefix/bin"; then
  case_pass "T15 PATH includes \$brew_prefix/bin after successful bootstrap"
else
  case_fail "T15 PATH augmentation" "PATH did not include resolved prefix: $captured_path"
fi

# ─── Remediation block update verification ──────────────────────────────────
echo "T8 remediation block mentions brew-bootstrap option"
if grep -A30 '_crg_print_remediation' "$INTELLISENSE_SETUP/setup.sh" \
     | grep -qF "Brew-bootstrap"; then
  case_pass "T8 remediation block now lists brew-bootstrap as install option 4"
else
  case_fail "T8 remediation block" "no Brew-bootstrap option found"
fi

# ─── Wiring verification: helper called from detect_or_install_code_review_graph ──
echo "T9 helper invoked between Step 1 and Step 2 of detect_or_install_code_review_graph"
if awk '/^detect_or_install_code_review_graph\(\)/{f=1} f' "$INTELLISENSE_SETUP/setup.sh" \
     | awk '/Step 2:/{exit} 1' \
     | grep -qF "_crg_bootstrap_runner_via_brew"; then
  case_pass "T9 _crg_bootstrap_runner_via_brew called before Step 2 (uv tool install)"
else
  case_fail "T9 helper wiring" "_crg_bootstrap_runner_via_brew not invoked before Step 2"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "─── Summary ───"
total="$(wc -l < "$RESULTS" | tr -d ' ')"
passed="$(grep -c '^P$' "$RESULTS" || true)"
failed="$(grep -c '^F$' "$RESULTS" || true)"
echo "  Total:  $total"
echo "  Passed: $passed"
echo "  Failed: $failed"
[ "$failed" = "0" ] || exit 1
exit 0
