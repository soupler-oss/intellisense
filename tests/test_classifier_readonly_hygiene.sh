#!/usr/bin/env bash
# Proves the 5 read-only-hygiene fixes.
# Each assertion drives scripts/userPromptSubmit-classifier.sh with a crafted
# prompt (unique session_id => no cache) and inspects the emitted
# additionalContext. NO source behaviour beyond the classifier is exercised.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CLS="$REPO/scripts/userPromptSubmit-classifier.sh"
PASS=0; FAIL=0
TMPCWD="$(mktemp -d)"; mkdir -p "$TMPCWD/.intellisense/session"
trap 'rm -rf "$TMPCWD"' EXIT

# run_classify <prompt> <session_id>  -> echoes additionalContext
run_classify() {
  local prompt="$1" sid="$2"
  jq -nc --arg p "$prompt" --arg s "$sid" --arg c "$TMPCWD" \
     '{prompt:$p, session_id:$s, cwd:$c}' \
   | bash "$CLS" 2>/dev/null \
   | jq -r '.hookSpecificOutput.additionalContext // empty'
}
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "== Test 1: audit/analyze/investigate route to design_review_only =="
for verb in "audit the authentication module design" \
            "analyze how the payout flow works" \
            "investigate the login session handling design"; do
  ctx="$(run_classify "$verb" "s1-$RANDOM-$verb")"
  if echo "$ctx" | grep -q 'mode=design_review_only'; then ok "'$verb' -> design_review_only"
  else no "'$verb' -> $(echo "$ctx" | grep -oE 'mode=[a-z_]+' | head -1)"; fi
done

echo "== Test 2: 'analyze and fix' still routes to a CODING mode =="
ctx="$(run_classify "analyze and fix the login token validation bug" "s2-$RANDOM")"
if echo "$ctx" | grep -qE 'mode=(bug_fix|full_feature)'; then ok "stayed coding ($(echo "$ctx"|grep -oE 'mode=[a-z_]+'|head -1))"
else no "expected coding mode, got $(echo "$ctx"|grep -oE 'mode=[a-z_]+'|head -1)"; fi

echo "== Test 3: Tier-2 EDIT path keeps full enforcement content (tier2.md) =="
ctx="$(run_classify "fix the account balance deduction bug in the payment service" "s3-$RANDOM")"
if echo "$ctx" | grep -q 'Tier=2' && echo "$ctx" | grep -qiE 'before any Edit/Write|Required artifacts'; then
  ok "Tier=2 edit prompt still gets tier2.md ceremony"
else no "Tier-2 edit enforcement content missing (tier=$(echo "$ctx"|grep -oE 'Tier=[0-9]'|head -1))"; fi
# and: a Tier-2 READ-ONLY prompt gets read-only.md, NOT tier2 ceremony
ctx="$(run_classify "audit the authentication module design" "s3b-$RANDOM")"
if echo "$ctx" | grep -q 'Tier=2' && echo "$ctx" | grep -qi 'Read-only / analysis request' \
   && ! echo "$ctx" | grep -qi 'before any Edit/Write'; then
  ok "Tier-2 read-only prompt -> read-only.md, tier preserved, no edit-ceremony"
else no "Tier-2 read-only routing wrong"; fi

echo "== Test 4: confidence reflects the signal count (not a fixed 0.9) =="
# 2-signal Tier-1 coding prompt reports 0.8.
ctx="$(run_classify "fix the config setup bug" "s4-$RANDOM")"
conf="$(echo "$ctx" | grep -oE 'confidence=[0-9.]+' | head -1 | cut -d= -f2)"
if [ "$conf" != "0.9" ]; then ok "2-signal Tier-1 coding prompt -> confidence=$conf"
else no "confidence still 0.9 on 2-signal prompt"; fi

echo "== Test 5: stale-settings banner appears ONCE per session, not every prompt =="
export TMPDIR="$TMPCWD"            # isolate the per-session marker
export INTELLISENSE_SETUP_PATH="$REPO"    # real (newer) template
OLD_SETTINGS="$TMPCWD/old-settings.json"; echo '{}' > "$OLD_SETTINGS"
touch -t 200001010000 "$OLD_SETTINGS"   # force older-than-template
export INTELLISENSE_SETTINGS_FILE="$OLD_SETTINGS"
rm -f "$TMPDIR/intellisense-stale-warned-staleSID"
c1="$(run_classify "explain the pre-push hook" "staleSID")"
c2="$(run_classify "explain the setup script" "staleSID")"   # different prompt => cache-miss again
if echo "$c1" | grep -q '\[intellisense NOTICE\]' && ! echo "$c2" | grep -q '\[intellisense NOTICE\]'; then
  ok "banner on 1st cache-miss, suppressed on 2nd (marker dedup)"
else no "stale banner not deduped (c1 has=$(echo "$c1"|grep -c NOTICE) c2 has=$(echo "$c2"|grep -c NOTICE))"; fi
unset INTELLISENSE_SETTINGS_FILE INTELLISENSE_SETUP_PATH

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
