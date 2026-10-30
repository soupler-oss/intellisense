#!/usr/bin/env bash
# tests/test_heartbeat_fire_once_nonblocking.sh
#
# The fire-once heartbeat in setup.sh must never block setup silently. On first
# install the heartbeat can git-fetch prices, parse transcripts, and POST to the
# API; any of that can hang. So the run is bounded (timeout/gtimeout) or
# detached, output goes to ~/.claude-intellisense/heartbeat-setup.log, and the
# installed runtime path under ~/.intellisense/bin/ is preferred.
#
# Strategy: extract the REAL fire-once block from setup.sh (between the
# INTELLISENSE-HEARTBEAT-FIRE-ONCE markers) and run it with a fake heartbeat that
# sleeps far longer than the bound. Assert the block returns well under the
# fake's sleep, so a hanging heartbeat can never block setup.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP="$REPO_ROOT/setup.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }

# --- Extract the real fire-once block verbatim from setup.sh ------------------
BLOCK="$(awk '/# >>> INTELLISENSE-HEARTBEAT-FIRE-ONCE/{f=1;next} /# <<< INTELLISENSE-HEARTBEAT-FIRE-ONCE/{f=0} f' "$SETUP")"
if [[ -z "$BLOCK" ]]; then
  fail "could not extract INTELLISENSE-HEARTBEAT-FIRE-ONCE block from setup.sh (markers missing?)"
  echo "Results: $PASS passed, $FAIL failed"; exit 1
fi

# --- Build a fake environment with a SLOW heartbeat ---------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_HOME="$TMP/home"
BIN="$FAKE_HOME/.intellisense/bin"
mkdir -p "$BIN"
# Fake token so the fire-once guard passes.
: > "$FAKE_HOME/.intellisense/heartbeat-token"
# Fake installed heartbeat that hangs for 60s — far beyond the 30s bound.
cat > "$BIN/intellisense-heartbeat.sh" <<'HB'
#!/usr/bin/env bash
echo "fake heartbeat started"
sleep 60
echo "fake heartbeat finished"
HB
chmod +x "$BIN/intellisense-heartbeat.sh"

# Variables the block references (it is real setup.sh code, run out of context).
export HOME="$FAKE_HOME"
NO_HEARTBEAT=false
DRY_RUN=false
SCRIPT_DIR="$REPO_ROOT"
INTELLISENSE_GH_LOGIN=""

# --- Run the real block and measure wall-clock --------------------------------
# On stock macOS (no timeout/gtimeout) the block detaches the heartbeat, so it
# returns immediately. On Linux/coreutils it bounds at 30s. Either way it must
# return well under the fake's 60s sleep. We allow up to 40s (30s bound + slack).
start=$SECONDS
eval "$BLOCK"
elapsed=$(( SECONDS - start ))

if (( elapsed < 40 )); then
  pass "fire-once returned in ${elapsed}s (< 40s) despite a 60s-hanging heartbeat"
else
  fail "fire-once blocked for ${elapsed}s — a hanging heartbeat froze setup"
fi

# --- Assert output is logged, not discarded -----------------------------------
LOG="$FAKE_HOME/.claude-intellisense/heartbeat-setup.log"
# Detached path needs a moment to write; bounded path has already written.
for _ in 1 2 3 4 5; do
  [[ -s "$LOG" ]] && break
  sleep 1
done
if [[ -s "$LOG" ]] && grep -q "fake heartbeat started" "$LOG"; then
  pass "heartbeat output captured to heartbeat-setup.log (not discarded)"
else
  fail "expected heartbeat output in $LOG"
fi

# --- Assert the installed runtime path is preferred over the source path ------
if grep -q 'intellisense/bin/intellisense-heartbeat.sh' <<<"$BLOCK"; then
  pass "fire-once prefers installed runtime path (~/.intellisense/bin)"
else
  fail "fire-once does not reference the installed runtime path"
fi

echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
