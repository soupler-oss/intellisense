#!/usr/bin/env bash
# Runs the whole test suite: Go (the agent-neutral CLI) and Bash (Live mode).
#
# Each Bash test gets a throwaway HOME, so nothing touches the real ~/.claude or ~/.intellisense. Tests that
# install system services or packages (launchd/systemd timers, Homebrew, the full setup.sh install) only
# run with --all, on a disposable machine.
#
# Usage: bash scripts/ci/test.sh [--all] [--bash-only|--go-only]
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR" || exit 1

ALL=0 RUN_GO=1 RUN_BASH=1
for arg in "$@"; do
  case "$arg" in
    --all) ALL=1 ;;
    --bash-only) RUN_GO=0 ;;
    --go-only) RUN_BASH=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

MACHINE_TESTS='test_crg_brew_bootstrap|test_heartbeat_tcc_install|test_heartbeat_systemd_timer|test_setup_beads|test_setup_e2e|test_setup\.sh|test_restore|test_setup_repos_heartbeat|test_heartbeat_payload|verify_github_login_resolution|test_repos\.sh|test_verify'

status=0

if [ "$RUN_GO" = 1 ]; then
  echo "== go test"
  go test -count=1 ./... || status=1
fi

if [ "$RUN_BASH" = 1 ]; then
  # Live mode's Bash hooks ask the Go engine for every tier, so the Bash tests get a binary built from this
  # source (INTELLISENSE_BIN wins over ~/.intellisense/bin and PATH).
  engine_dir=$(mktemp -d)
  if ! go build -o "$engine_dir/intellisense" ./cmd/intellisense; then
    echo "cannot build the intellisense engine for the bash tests" >&2
    exit 1
  fi
  export INTELLISENSE_BIN="$engine_dir/intellisense"
  # Tests run with a throwaway HOME; keep using the real Go module cache (no downloads, nothing read-only left
  # behind in the temporary home).
  export GOMODCACHE="${GOMODCACHE:-$(go env GOMODCACHE)}" GOCACHE="${GOCACHE:-$(go env GOCACHE)}"
  echo "== bash tests"
  pass=0 fail=0 skip=0 failed=()
  for t in tests/test_*.sh tests/test-intellisense-scripts.sh; do
    name=$(basename "$t")
    if [ "$ALL" = 0 ] && echo "$name" | grep -Eq "$MACHINE_TESTS"; then
      skip=$((skip + 1)); continue
    fi
    home=$(mktemp -d)
    HOME="$home" git config --global user.name test
    HOME="$home" git config --global user.email test@example.com
    HOME="$home" git config --global init.defaultBranch main
    HOME="$home" bash "$t" >"$home/out.log" 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
      pass=$((pass + 1)); echo "  pass $name"
    elif [ "$rc" -eq 77 ]; then
      # 77: the test needs an optional tool that is not installed (see tests/helpers.sh).
      skip=$((skip + 1)); echo "  skip $name ($(grep -m1 '^SKIP' "$home/out.log" | sed 's/^SKIP: //'))"
    else
      fail=$((fail + 1)); failed+=("$name"); echo "  FAIL $name"
      sed 's/^/      /' "$home/out.log" | grep -iE 'fail|error|✗' | head -5
    fi
    rm -rf "$home"
  done
  rm -rf "$engine_dir"
  echo "bash tests: $pass passed, $fail failed, $skip skipped (machine-level: run with --all on a disposable machine; optional tools: install them)"
  [ "$fail" -eq 0 ] || status=1
fi

exit $status
