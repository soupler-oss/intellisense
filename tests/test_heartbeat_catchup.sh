#!/usr/bin/env bash
# tests/test_heartbeat_catchup.sh
#
# Repo-level test for the heartbeat APP-LEVEL CATCH-UP loop in
# scripts/intellisense-heartbeat.sh (Gap B).
#
# launchd StartCalendarInterval and systemd Persistent=true both COALESCE
# multiple missed daily intervals into a SINGLE wake fire, so the script must
# backfill every missing UTC daily period itself — one POST per missing day,
# oldest→newest — keyed by reported period (not send date).
#
# Semantics under test:
#   state file (INTELLISENSE_HEARTBEAT_STATE_FILE) holds the last successfully-sent
#   UTC period (YYYY-MM-DD). On each run the script sends every period in
#   (watermark, yesterday] oldest→newest, advancing the watermark on each 2xx.
#
# Strategy: run the REAL intellisense-heartbeat.sh with a fake `curl` (captures each
# POST's idempotency_key, returns 200) and a stubbed `git` (so price-refresh
# is a fast no-op). Empty transcripts dir → parser emits clean empty days.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HB="$REPO_ROOT/scripts/intellisense-heartbeat.sh"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

command -v jq >/dev/null 2>&1 || { echo "jq required for this test"; exit 1; }

# UTC date helper (macOS -v / GNU -d).
ud() { date -u -v"$1" +%Y-%m-%d 2>/dev/null || date -u --date="$2" +%Y-%m-%d; }

YESTERDAY="$(ud -1d 'yesterday')"
D1="$(ud -1d '1 day ago')"
D2="$(ud -2d '2 days ago')"
D3="$(ud -3d '3 days ago')"
D4="$(ud -4d '4 days ago')"
SEED="$(ud -5d '5 days ago')"   # last-sent watermark = 4 days before yesterday

home="$(mktemp -d)"
fakebin="$(mktemp -d)"
capture="$home/posted_keys.log"
: > "$capture"

# ── fake curl: capture inner idempotency_key, return 200 ─────────────────────
cat > "$fakebin/curl" <<EOF
#!/usr/bin/env bash
payload=""; outfile=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --data-binary) payload="\${2#@}"; shift 2 ;;
    -o) outfile="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\$outfile" ]] && echo '{}' > "\$outfile"
if [[ -n "\$payload" && -f "\$payload" ]]; then
  jq -r '.heartbeats[0].idempotency_key // .idempotency_key // empty' "\$payload" >> "$capture"
fi
echo "200"
exit 0
EOF

# ── stub git so hb_refresh_prices fails fast/soft (no network) ───────────────
cat > "$fakebin/git" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

chmod +x "$fakebin"/*

mkdir -p "$home/projects"          # empty transcripts → clean empty-day summaries
mkdir -p "$home/.intellisense"
echo "dummy-token" > "$home/.intellisense/heartbeat-token"
chmod 600 "$home/.intellisense/heartbeat-token"

STATE="$home/state"
echo "$SEED" > "$STATE"

echo "=== Catch-up: 4-day outage → 4 POSTs oldest→newest ==="
(
  export HOME="$home"
  export PATH="$fakebin:$PATH"
  export INTELLISENSE_HEARTBEAT_URL="https://fake.local/intellisense/usage/daily"
  export INTELLISENSE_HEARTBEAT_TOKEN="dummy-token"
  export INTELLISENSE_HEARTBEAT_STATE_FILE="$STATE"
  export INTELLISENSE_HEARTBEAT_QUEUE_DIR="$home/queue"
  export INTELLISENSE_HEARTBEAT_ERROR_LOG="$home/err.log"
  export HB_CLAUDE_PROJECTS_DIR="$home/projects"
  export INTELLISENSE_GH_LOGIN="TESTUSER"
  /bin/bash "$HB"
) >/dev/null 2>&1

# Assert: exactly 4 POSTs, periods D4,D3,D2,D1 in order.
n="$(grep -c . "$capture" 2>/dev/null)"
[[ "$n" -eq 4 ]] && pass "4 POSTs sent (one per missing day)" || fail "expected 4 POSTs, got $n"

keys=(); while IFS= read -r line; do [[ -n "$line" ]] && keys+=("$line"); done < "$capture"
expect=("TESTUSER_$D4" "TESTUSER_$D3" "TESTUSER_$D2" "TESTUSER_$D1")
ok=1
for i in 0 1 2 3; do
  [[ "${keys[$i]:-}" == "${expect[$i]}" ]] || ok=0
done
[[ "$ok" -eq 1 ]] && pass "periods sent oldest→newest with correct idempotency keys" \
  || fail "order/keys wrong: got [${keys[*]:-}] expected [${expect[*]}]"

# Assert: watermark advanced to yesterday.
final="$(cat "$STATE" 2>/dev/null)"
[[ "$final" == "$YESTERDAY" ]] && pass "watermark advanced to yesterday ($YESTERDAY)" \
  || fail "watermark = '$final', expected '$YESTERDAY'"

# ── Second run same day → no new POSTs (idempotent, up-to-date) ──────────────
echo "=== Catch-up: re-run when current → 0 new POSTs ==="
: > "$capture"
(
  export HOME="$home"
  export PATH="$fakebin:$PATH"
  export INTELLISENSE_HEARTBEAT_URL="https://fake.local/intellisense/usage/daily"
  export INTELLISENSE_HEARTBEAT_TOKEN="dummy-token"
  export INTELLISENSE_HEARTBEAT_STATE_FILE="$STATE"
  export INTELLISENSE_HEARTBEAT_QUEUE_DIR="$home/queue"
  export INTELLISENSE_HEARTBEAT_ERROR_LOG="$home/err.log"
  export HB_CLAUDE_PROJECTS_DIR="$home/projects"
  export INTELLISENSE_GH_LOGIN="TESTUSER"
  /bin/bash "$HB"
) >/dev/null 2>&1
n2="$(grep -c . "$capture" 2>/dev/null)"
[[ "$n2" -eq 0 ]] && pass "no duplicate POST when already current" || fail "expected 0 POSTs, got $n2"

# ── Drain a queued day must NOT also be re-sent by the catch-up loop ─────────
# watermark=D-2, a D-1 entry already queued from a prior failure.
# drain delivers D-1 → must advance the watermark so the catch-up loop does not
# send D-1 a SECOND time. Expect exactly ONE POST for D-1.
echo "=== Catch-up: drain + watermark advance → no double-send ==="
home2="$(mktemp -d)"; capture2="$home2/posted_keys.log"; : > "$capture2"
fakebin2="$(mktemp -d)"
cat > "$fakebin2/curl" <<EOF
#!/usr/bin/env bash
payload=""; outfile=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --data-binary) payload="\${2#@}"; shift 2 ;;
    -o) outfile="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\$outfile" ]] && echo '{}' > "\$outfile"
if [[ -n "\$payload" && -f "\$payload" ]]; then
  jq -r '.heartbeats[0].idempotency_key // .idempotency_key // empty' "\$payload" >> "$capture2"
fi
echo "200"; exit 0
EOF
cat > "$fakebin2/git" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$fakebin2"/*
mkdir -p "$home2/projects" "$home2/queue" "$home2/.intellisense"
echo "dummy-token" > "$home2/.intellisense/heartbeat-token"; chmod 600 "$home2/.intellisense/heartbeat-token"
WM2="$(ud -2d '2 days ago')"          # watermark stuck 2 days back
echo "$WM2" > "$home2/state"
# Pre-seed the queue with the D-1 inner heartbeat (prior failed run).
printf '{"idempotency_key":"TESTUSER_%s","usage_summary":{"period":"%s"}}' "$D1" "$D1" \
    > "$home2/queue/00000000T000000__TESTUSER_$D1.json"
(
  export HOME="$home2" PATH="$fakebin2:$PATH"
  export INTELLISENSE_HEARTBEAT_URL="https://fake.local/intellisense/usage/daily"
  export INTELLISENSE_HEARTBEAT_TOKEN="dummy-token"
  export INTELLISENSE_HEARTBEAT_STATE_FILE="$home2/state"
  export INTELLISENSE_HEARTBEAT_QUEUE_DIR="$home2/queue"
  export INTELLISENSE_HEARTBEAT_ERROR_LOG="$home2/err.log"
  export HB_CLAUDE_PROJECTS_DIR="$home2/projects"
  export INTELLISENSE_GH_LOGIN="TESTUSER"
  /bin/bash "$HB"
) >/dev/null 2>&1
d1_posts="$(grep -c "TESTUSER_$D1\$" "$capture2" 2>/dev/null)"
[[ "$d1_posts" -eq 1 ]] && pass "D-1 sent exactly once (drain advanced watermark, no re-send)" \
  || fail "D-1 sent $d1_posts times (expected 1 — drain double-send)"
final2="$(cat "$home2/state" 2>/dev/null)"
[[ "$final2" == "$YESTERDAY" ]] && pass "watermark advanced to yesterday after drain+catchup" \
  || fail "watermark='$final2' expected '$YESTERDAY'"
qn="$(find "$home2/queue" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
[[ "$qn" -eq 0 ]] && pass "queue drained empty" || fail "queue still has $qn entries"
rm -rf "$home2" "$fakebin2"

# ── Watermark current → zero POST AND zero git fetch ───────────
# Under hourly-everywhere, ~23 runs/day have nothing due. Those must be cheap:
# no POST, and the price refresh (git fetch) must be SKIPPED when no period is
# due — otherwise hourly firing = up to 24 git fetch/day/machine.
echo "=== Hourly: watermark current → 0 POST and 0 git fetch ==="
home3="$(mktemp -d)"; capture3="$home3/posted_keys.log"; gitlog="$home3/git_calls.log"
fakebin3="$(mktemp -d)"; : > "$capture3"; : > "$gitlog"
cat > "$fakebin3/curl" <<EOF
#!/usr/bin/env bash
payload=""; outfile=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --data-binary) payload="\${2#@}"; shift 2 ;;
    -o) outfile="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "\$outfile" ]] && echo '{}' > "\$outfile"
[[ -n "\$payload" && -f "\$payload" ]] && jq -r '.heartbeats[0].idempotency_key // empty' "\$payload" >> "$capture3"
echo "200"; exit 0
EOF
# git stub that RECORDS every invocation so we can assert zero fetches.
cat > "$fakebin3/git" <<EOF
#!/usr/bin/env bash
echo "git \$*" >> "$gitlog"
exit 1
EOF
chmod +x "$fakebin3"/*
mkdir -p "$home3/projects" "$home3/queue" "$home3/.intellisense"
echo "dummy-token" > "$home3/.intellisense/heartbeat-token"; chmod 600 "$home3/.intellisense/heartbeat-token"
# Point INTELLISENSE_SETUP_PATH at a throwaway "repo" so hb_refresh_prices does NOT take
# its in-repo skip path — i.e. it WOULD attempt `git fetch` if reached. That's
# what makes the git stub a real guard: refresh must be gated on due periods.
mkdir -p "$home3/tgit/.git"
echo "$YESTERDAY" > "$home3/state"   # already current → nothing due
(
  export HOME="$home3" PATH="$fakebin3:$PATH"
  export INTELLISENSE_HEARTBEAT_URL="https://fake.local/intellisense/usage/daily"
  export INTELLISENSE_HEARTBEAT_TOKEN="dummy-token"
  export INTELLISENSE_SETUP_PATH="$home3/tgit"
  export INTELLISENSE_HEARTBEAT_STATE_FILE="$home3/state"
  export INTELLISENSE_HEARTBEAT_QUEUE_DIR="$home3/queue"
  export INTELLISENSE_HEARTBEAT_ERROR_LOG="$home3/err.log"
  export HB_CLAUDE_PROJECTS_DIR="$home3/projects"
  export INTELLISENSE_GH_LOGIN="TESTUSER"
  /bin/bash "$HB"
) >/dev/null 2>&1
posts3="$(grep -c . "$capture3" 2>/dev/null)"
gitn="$(grep -c . "$gitlog" 2>/dev/null)"
[[ "$posts3" -eq 0 ]] && pass "no POST when watermark current" || fail "expected 0 POSTs, got $posts3"
[[ "$gitn" -eq 0 ]] && pass "no git fetch when nothing due (refresh gated on due periods)" \
  || fail "expected 0 git calls, got $gitn: $(cat "$gitlog")"
rm -rf "$home3" "$fakebin3"

rm -rf "$home" "$fakebin"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
