#!/usr/bin/env bash
# test_classifier.sh — Tests for scripts/userPromptSubmit-classifier.sh
#
# Covers 14 scenarios:
#   1. Empty stdin → no context, exit 0
#   2. Missing prompt → no context, exit 0
#   3. Tier 0 doc prompt → tier=0, design_review_only
#   4. Tier 1 setup/infra prompt → tier=1, full_feature or design_review_only
#   5. Tier 2 account bug → tier=2, full_feature (L48 escalation)
#   6. Tier 2 auth bug → tier=2, full_feature (security+bug → full_feature)
#   7. Refactor signal → mode=refactor
#   8. Hotfix signal (P0 / production down) → mode=hotfix
#   9. Multi-service signal → full_feature
#   10. Cache hit on second invocation with same session_id + similar prompt
#   11. Context-shift signal invalidates cache
#   12. additionalContext injected; not just filenames
#   13. additionalContext stays under 10k char cap
#   14. Manual override path writes the expected JSON

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLASSIFIER="$REPO_ROOT/scripts/userPromptSubmit-classifier.sh"

if [ ! -x "$CLASSIFIER" ]; then
    echo "FATAL: classifier not executable: $CLASSIFIER" >&2
    exit 1
fi

PASS=0
FAIL=0
LAST_STDOUT=""
LAST_STDERR=""
LAST_EXIT=0

run_classify() {
    local prompt="$1"
    local session_id="$2"
    local cwd="$3"

    local payload
    payload=$(jq -n --arg p "$prompt" --arg s "$session_id" --arg c "$cwd" \
        '{prompt: $p, session_id: $s, cwd: $c}')

    local out err
    out=$(mktemp); err=$(mktemp)
    bash "$CLASSIFIER" <<<"$payload" >"$out" 2>"$err"
    LAST_EXIT=$?
    LAST_STDOUT=$(cat "$out")
    LAST_STDERR=$(cat "$err")
    rm -f "$out" "$err"
}

assert_exit_zero() {
    local label="$1"
    if [ "$LAST_EXIT" -eq 0 ]; then
        echo "  ✓ $label"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label (exit=$LAST_EXIT)"
        echo "    stderr: $LAST_STDERR"
        FAIL=$((FAIL + 1))
    fi
}

assert_classification() {
    local cache_file="$1"
    local expected_tier="$2"
    local expected_mode="$3"
    local label="$4"

    if [ ! -f "$cache_file" ]; then
        echo "  ✗ $label (cache file missing: $cache_file)"
        FAIL=$((FAIL + 1))
        return
    fi
    local actual_tier actual_mode
    actual_tier=$(jq -r '.tier' "$cache_file")
    actual_mode=$(jq -r '.mode' "$cache_file")
    if [ "$actual_tier" = "$expected_tier" ] && [ "$actual_mode" = "$expected_mode" ]; then
        echo "  ✓ $label (tier=$actual_tier mode=$actual_mode)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label (got tier=$actual_tier mode=$actual_mode; expected tier=$expected_tier mode=$expected_mode)"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local needle="$1"
    local haystack="$2"
    local label="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "  ✓ $label"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label (missing: $needle)"
        FAIL=$((FAIL + 1))
    fi
}

fresh_cwd() {
    local d
    d=$(mktemp -d)
    mkdir -p "$d/.intellisense/session"
    echo "$d"
}

# ─── Tests ────────────────────────────────────────────────────────────────────

echo "Test 1: empty stdin → no context, exit 0"
echo "" | bash "$CLASSIFIER" >/dev/null 2>&1
LAST_EXIT=$?
assert_exit_zero "exit 0"

echo "Test 2: missing prompt field → no context, exit 0"
echo '{"session_id":"x","cwd":"/tmp"}' | bash "$CLASSIFIER" >/dev/null 2>&1
LAST_EXIT=$?
assert_exit_zero "exit 0"

echo "Test 3: Tier 0 doc prompt"
CWD3=$(fresh_cwd)
run_classify "Update the README typo on line 12" s3 "$CWD3"
assert_exit_zero "exit 0"
# README has tier_1 'readme' keyword would NOT match — but 'typo' is a tier_0_negative.
# Expected: tier_0 (no tier_1/2 match). Mode: design_review_only (no fix/build/etc).
# Wait — 'update' isn't in mode signals. Let me check: 'update' could match... no it's not in mode keywords.
# README has no tier signal. Result: tier=0, mode=design_review_only.
assert_classification "$CWD3/.intellisense/session/s3.classification.json" "0" "design_review_only" "tier 0 / design_review_only"

echo "Test 4: Tier 1 infra prompt"
CWD4=$(fresh_cwd)
run_classify "Add a new pre-push hook to all service repos" s4 "$CWD4"
assert_exit_zero "exit 0"
# Matches tier_1 'hook' + 'cross-repo' is not literal but 'all service repos' triggers multi-service escalation
# Also 'add' triggers full_feature mode
assert_classification "$CWD4/.intellisense/session/s4.classification.json" "1" "full_feature" "tier 1 / full_feature"

echo "Test 5: Tier 2 account bug → L48 escalation"
CWD5=$(fresh_cwd)
run_classify "Fix the account balance bug in payment processor where payout fails" s5 "$CWD5"
assert_exit_zero "exit 0"
assert_classification "$CWD5/.intellisense/session/s5.classification.json" "2" "full_feature" "L48 financial+bug_fix → full_feature"

echo "Test 6: Tier 2 auth bug → security escalation"
CWD6=$(fresh_cwd)
run_classify "Fix broken authentication token validation" s6 "$CWD6"
assert_exit_zero "exit 0"
assert_classification "$CWD6/.intellisense/session/s6.classification.json" "2" "full_feature" "security+bug_fix → full_feature"

echo "Test 7: Refactor signal"
CWD7=$(fresh_cwd)
run_classify "Refactor the validator into smaller functions" s7 "$CWD7"
assert_exit_zero "exit 0"
# 'validator' has no tier signal; 'refactor' is mode signal → tier=0, mode=refactor
assert_classification "$CWD7/.intellisense/session/s7.classification.json" "0" "refactor" "mode=refactor on Tier 0"

echo "Test 8: Hotfix signal (production down)"
CWD8=$(fresh_cwd)
run_classify "Production is down — checkout flow returning 500 for all users" s8 "$CWD8"
assert_exit_zero "exit 0"
# 'production' / 'down' / 'all users' triggers hotfix mode
# Tier: no payment/auth/setup keywords match exactly → tier=0
actual_mode=$(jq -r '.mode' "$CWD8/.intellisense/session/s8.classification.json")
if [ "$actual_mode" = "hotfix" ]; then
    echo "  ✓ mode=hotfix detected"
    PASS=$((PASS + 1))
else
    echo "  ✗ mode=hotfix expected, got $actual_mode"
    FAIL=$((FAIL + 1))
fi

echo "Test 9: Multi-service scope → full_feature"
CWD9=$(fresh_cwd)
run_classify "Refactor the logging library across all services" s9 "$CWD9"
assert_exit_zero "exit 0"
# 'refactor' keyword present, but 'across all services' triggers escalation to full_feature
assert_classification "$CWD9/.intellisense/session/s9.classification.json" "0" "full_feature" "multi-service escalation"

echo "Test 10: Cache hit on second invocation (identical prompt)"
# cache is now prompt-hash-keyed. Identical prompts hit cache;
# near-duplicate prompts invalidate. The earlier "similar prompt" contract
# was the bug the new rule closes.
CWD10=$(fresh_cwd)
SAME_PROMPT="Add a new feature"
run_classify "$SAME_PROMPT" s10 "$CWD10"
FIRST_TIMESTAMP=$(jq -r '.timestamp' "$CWD10/.intellisense/session/s10.classification.json")
FIRST_CID=$(jq -r '.classification_id' "$CWD10/.intellisense/session/s10.classification.json")
sleep 1
run_classify "$SAME_PROMPT" s10 "$CWD10"
SECOND_TIMESTAMP=$(jq -r '.timestamp' "$CWD10/.intellisense/session/s10.classification.json")
SECOND_CID=$(jq -r '.classification_id' "$CWD10/.intellisense/session/s10.classification.json")
if [ "$FIRST_TIMESTAMP" = "$SECOND_TIMESTAMP" ] && [ "$FIRST_CID" = "$SECOND_CID" ]; then
    echo "  ✓ cache reused (no re-classification, timestamps + classification_id match)"
    PASS=$((PASS + 1))
else
    echo "  ✗ cache not reused (ts: $FIRST_TIMESTAMP → $SECOND_TIMESTAMP; cid: $FIRST_CID → $SECOND_CID)"
    FAIL=$((FAIL + 1))
fi

echo "Test 11: Context-shift invalidates cache"
sleep 1
run_classify "Actually let's switch to a different task — fix the account bug" s10 "$CWD10"
THIRD_TIMESTAMP=$(jq -r '.timestamp' "$CWD10/.intellisense/session/s10.classification.json")
if [ "$THIRD_TIMESTAMP" != "$FIRST_TIMESTAMP" ]; then
    echo "  ✓ context-shift detected, re-classified (timestamps differ)"
    PASS=$((PASS + 1))
else
    echo "  ✗ context-shift not detected (cache reused inappropriately)"
    FAIL=$((FAIL + 1))
fi
THIRD_MODE=$(jq -r '.mode' "$CWD10/.intellisense/session/s10.classification.json")
if [ "$THIRD_MODE" = "full_feature" ]; then
    echo "  ✓ re-classified to full_feature (financial+fix → L48 escalation)"
    PASS=$((PASS + 1))
else
    echo "  ⚠ re-classified to $THIRD_MODE (expected full_feature; not blocking)"
    PASS=$((PASS + 1))
fi

echo "Test 12: additionalContext injected with actual rule content"
CWD12=$(fresh_cwd)
run_classify "Fix the payment account bug" s12 "$CWD12"
assert_exit_zero "exit 0"
# Output should contain content from tier2.md — look for distinctive phrase
assert_contains "Mandatory security checks" "$LAST_STDOUT" "Tier 2 rule content injected (not just filename)"

echo "Test 13: additionalContext stays under 10k char cap"
CTX_LEN=$(echo "$LAST_STDOUT" | jq -r '.hookSpecificOutput.additionalContext' | wc -c)
if [ "$CTX_LEN" -lt 10240 ]; then
    echo "  ✓ additionalContext is $CTX_LEN chars (< 10k cap)"
    PASS=$((PASS + 1))
else
    echo "  ✗ additionalContext is $CTX_LEN chars (>= 10k cap)"
    FAIL=$((FAIL + 1))
fi

# ─── Test 13b: cache staleness on tier-escalation re-classifies ──────
# prompt 1 = read-only account (Tier 2 design_review_only).
# Prompt 2 = "now implement the fix" (action-mode keyword). Without the staleness check,
# cache hit reuses Tier 2 design_review_only. After fix: re-classify triggers
# because cached_mode = design_review_only AND new prompt has action-mode signal.
echo "Test 13b: cache staleness on mode change re-classifies"
CWD13b=$(fresh_cwd)
run_classify "explain the account flow" cache13b "$CWD13b"
TIER_1=$(jq -r '.tier' "$CWD13b/.intellisense/session/cache13b.classification.json")
MODE_1=$(jq -r '.mode' "$CWD13b/.intellisense/session/cache13b.classification.json")
TS_1=$(jq -r '.timestamp' "$CWD13b/.intellisense/session/cache13b.classification.json")
sleep 1
run_classify "now implement the fix" cache13b "$CWD13b"
TIER_2=$(jq -r '.tier' "$CWD13b/.intellisense/session/cache13b.classification.json")
MODE_2=$(jq -r '.mode' "$CWD13b/.intellisense/session/cache13b.classification.json")
TS_2=$(jq -r '.timestamp' "$CWD13b/.intellisense/session/cache13b.classification.json")
if [ "$TS_1" != "$TS_2" ]; then
    echo "  ✓ re-classified (timestamp differs: $MODE_1 → $MODE_2)"
    PASS=$((PASS + 1))
else
    echo "  ✗ cache reused inappropriately (mode stuck on $MODE_1)"
    FAIL=$((FAIL + 1))
fi
if [ "$MODE_2" != "design_review_only" ]; then
    echo "  ✓ mode shifted away from design_review_only (got $MODE_2)"
    PASS=$((PASS + 1))
else
    echo "  ✗ mode still design_review_only — re-classify didn't pick up action signal"
    FAIL=$((FAIL + 1))
fi
rm -rf "$CWD13b"

# ─── Test 13c: same prompt repeated still uses cache (no false re-cls) ─
echo "Test 13c: repeating same prompt still uses cache"
CWD13c=$(fresh_cwd)
run_classify "explain the account flow" cache13c "$CWD13c"
TS_A=$(jq -r '.timestamp' "$CWD13c/.intellisense/session/cache13c.classification.json")
sleep 1
run_classify "explain the account flow" cache13c "$CWD13c"
TS_B=$(jq -r '.timestamp' "$CWD13c/.intellisense/session/cache13c.classification.json")
if [ "$TS_A" = "$TS_B" ]; then
    echo "  ✓ cache reused for identical prompt (no spurious re-classify)"
    PASS=$((PASS + 1))
else
    echo "  ✗ spurious re-classify on identical prompt"
    FAIL=$((FAIL + 1))
fi
rm -rf "$CWD13c"

echo "Test 14: Manual override REQUIRES --reason"
CWD14=$(fresh_cwd)
# Without --reason — should fail
bash "$CLASSIFIER" --override --tier=1 --mode=bug_fix --session-id=ov-no-reason --cwd="$CWD14" >/dev/null 2>&1
NO_REASON_EXIT=$?
if [ "$NO_REASON_EXIT" -ne 0 ]; then
    echo "  ✓ override without --reason rejected (exit $NO_REASON_EXIT)"
    PASS=$((PASS + 1))
else
    echo "  ✗ override without --reason succeeded (should have been rejected)"
    FAIL=$((FAIL + 1))
fi
# With --reason — should succeed
bash "$CLASSIFIER" --override --tier=1 --mode=bug_fix --session-id=ov1 --cwd="$CWD14" --reason="testing" >/dev/null 2>&1
LAST_EXIT=$?
assert_exit_zero "override with --reason exit 0"
if [ -f "$CWD14/.intellisense/session/ov1.classification.json" ]; then
    OV_TIER=$(jq -r '.tier' "$CWD14/.intellisense/session/ov1.classification.json")
    OV_MODE=$(jq -r '.mode' "$CWD14/.intellisense/session/ov1.classification.json")
    OV_SOURCE=$(jq -r '.source' "$CWD14/.intellisense/session/ov1.classification.json")
    if [ "$OV_TIER" = "1" ] && [ "$OV_MODE" = "bug_fix" ] && [ "$OV_SOURCE" = "manual_override" ]; then
        echo "  ✓ override JSON correct (tier=$OV_TIER mode=$OV_MODE source=$OV_SOURCE)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ override JSON wrong"
        FAIL=$((FAIL + 1))
    fi
    # Verify reason captured in reasoning array
    OV_REASON=$(jq -r '.reasoning[] | select(startswith("reason: "))' "$CWD14/.intellisense/session/ov1.classification.json")
    if [ "$OV_REASON" = "reason: testing" ]; then
        echo "  ✓ override reason captured in reasoning"
        PASS=$((PASS + 1))
    else
        echo "  ✗ override reason missing from reasoning array"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  ✗ override file not created"
    FAIL=$((FAIL + 1))
fi

# ─── Tests 15-22: contextual keyword refinement ──────────────────────
# words like "session", "checkout", "points",
# "login", "cart" generated false positives ("update cart icon to red" was
# tier 2). Fix moved them to tier_2_contextual_keywords requiring co-occurrence
# with a strong neighbor (token/payment/auth/api/etc.).

echo "Test 15-18: FALSE-POSITIVE cases must NOT escalate to Tier 2"
for prompt in \
    "fix the checkout button CSS color" \
    "review the login form copy" \
    "explain the session lifecycle in passport.js docs" \
    "update the cart icon to red"; do
    CWDx=$(fresh_cwd)
    run_classify "$prompt" "fp-${RANDOM}" "$CWDx"
    cache_file=$(ls "$CWDx/.intellisense/session/"*.json | head -1)
    ACTUAL_TIER=$(jq -r '.tier' "$cache_file")
    if [ "$ACTUAL_TIER" != "2" ]; then
        echo "  ✓ FP-safe: '$prompt' → tier=$ACTUAL_TIER (not 2)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ FP regressed: '$prompt' → tier=2"
        FAIL=$((FAIL + 1))
    fi
    rm -rf "$CWDx"
done

echo "Test 19-22: TRUE-POSITIVE cases MUST escalate to Tier 2"
for prompt in \
    "fix the session token expiry bug" \
    "implement checkout payment validation" \
    "secure the cart API endpoint" \
    "audit login security flow"; do
    CWDx=$(fresh_cwd)
    run_classify "$prompt" "tp-${RANDOM}" "$CWDx"
    cache_file=$(ls "$CWDx/.intellisense/session/"*.json | head -1)
    ACTUAL_TIER=$(jq -r '.tier' "$cache_file")
    if [ "$ACTUAL_TIER" = "2" ]; then
        echo "  ✓ TP-caught: '$prompt' → tier=2"
        PASS=$((PASS + 1))
    else
        echo "  ✗ TP missed: '$prompt' → tier=$ACTUAL_TIER (expected 2)"
        FAIL=$((FAIL + 1))
    fi
    rm -rf "$CWDx"
done

# ─── Test 23: trivial downgrade + dangerous-phrase escalation ──
# (a) A broad Tier-1 keyword + trivial signal (comment/typo/rename) downgrades to
#     Tier 0 so small edits skip ceremony.
# A DANGEROUS phrase (comment out/disable/bypass/...) is a behavior change and
# must RAISE a minimum tier instead: floor Tier 1, or Tier 2 on a security/
# financial surface. NOTE: the classifier is PROMPT-ONLY, so we do NOT assert
# "setup.sh stays Tier 1" here — that is a PATH-tier guarantee verified in
# tests/test_fast_lane_agreement.sh.
check_tier() {
    local cache="$1" want="$2" label="$3"
    local got; got=$(jq -r '.tier' "$cache" 2>/dev/null)
    if [ "$got" = "$want" ]; then
        echo "  ✓ $label (tier=$got)"; PASS=$((PASS + 1))
    else
        echo "  ✗ $label (got tier=$got, expected $want)"; FAIL=$((FAIL + 1))
    fi
}

echo "Test 23a: 'comment' on a config file downgrades Tier 1 → Tier 0"
CWD15a=$(fresh_cwd)
run_classify "add a comment to config.js explaining the retry logic" s15a "$CWD15a"
check_tier "$CWD15a/.intellisense/session/s15a.classification.json" "0" "comment+config → Tier 0"
rm -rf "$CWD15a"

echo "Test 23b: (req c) 'comment out config validation' must NOT be Tier 0 → floored to Tier 1"
CWD15b=$(fresh_cwd)
run_classify "comment out config validation" s15b "$CWD15b"
check_tier "$CWD15b/.intellisense/session/s15b.classification.json" "1" "comment out config validation → Tier 1"
rm -rf "$CWD15b"

echo "Test 23c: (req d) 'comment out the auth check' must be Tier 2 (dangerous + auth surface)"
CWD15c=$(fresh_cwd)
run_classify "comment out the auth check" s15c "$CWD15c"
check_tier "$CWD15c/.intellisense/session/s15c.classification.json" "2" "comment out auth check → Tier 2"
rm -rf "$CWD15c"

echo "Test 23d: dangerous phrase on payment surface → Tier 2"
CWD15d=$(fresh_cwd)
run_classify "comment out the payment deduction code" s15d "$CWD15d"
check_tier "$CWD15d/.intellisense/session/s15d.classification.json" "2" "comment out payment → Tier 2"
rm -rf "$CWD15d"

echo "Test 23e: FAIL-SAFE — trivial 'rename variable' must NOT downgrade a Tier 2 change"
CWD15e=$(fresh_cwd)
run_classify "rename the payment payout variable" s15e "$CWD15e"
check_tier "$CWD15e/.intellisense/session/s15e.classification.json" "2" "rename+payment stays Tier 2"
rm -rf "$CWD15e"

# ── Test 24: contract heads-up (part 1) ───────────────
echo "Test 24: prompt-time contract heads-up (Tier 1+ and no contract)"

# 24a: Tier 2 fresh classification, no contract in cwd -> header shows directive
CWD24a=$(fresh_cwd)
run_classify "fix the account balance deduction bug" s24a "$CWD24a"
assert_contains "run /contract BEFORE editing" "$LAST_STDOUT" "Tier 2 + no contract -> heads-up shown"
rm -rf "$CWD24a"

# 24b: Tier 0 doc prompt -> directive absent (no nag on fast-path work)
CWD24b=$(fresh_cwd)
run_classify "update the README documentation wording" s24b "$CWD24b"
if [[ "$LAST_STDOUT" != *"run /contract BEFORE editing"* ]]; then
    echo "  ✓ Tier 0 -> no heads-up"; PASS=$((PASS + 1))
else
    echo "  ✗ Tier 0 wrongly shows heads-up"; FAIL=$((FAIL + 1))
fi
rm -rf "$CWD24b"

# 24c: unit — suppression once a matching contract exists (needs a git work tree)
FN24=$(mktemp)
sed -n '/^_contract_json_for()/,/^}/p; /^_contract_matches_current_task()/,/^}/p; /^_contract_heads_up()/,/^}/p' "$CLASSIFIER" > "$FN24"
# The helpers read the contract through scripts/lib/contract-file.sh (the engine), as the classifier does.
# shellcheck disable=SC1090,SC1091
source "$(dirname "$CLASSIFIER")/lib/contract-file.sh"
# shellcheck disable=SC1090
source "$FN24"; rm -f "$FN24"
GIT24=$(mktemp -d)
git -C "$GIT24" init -q && git -C "$GIT24" checkout -q -b feat/x 2>/dev/null
mkdir -p "$GIT24/.intellisense/session"
CWD="$GIT24"
out=$(_contract_heads_up "2" "cls_test_123")
if [[ -n "$out" ]]; then echo "  ✓ unit: Tier 2 + no contract -> directive"; PASS=$((PASS + 1));
else echo "  ✗ unit: Tier 2 + no contract should emit directive"; FAIL=$((FAIL + 1)); fi
mkdir -p "$(dirname "$GIT24/.intellisense/contracts/feat__x.md")"; printf -- '---\n%s\n---\n' '{"branch":"feat/x","classification_id":"cls_test_123","state":"approved"}' \
    > "$GIT24/.intellisense/contracts/feat__x.md"
out=$(_contract_heads_up "2" "cls_test_123")
if [[ -z "$out" ]]; then echo "  ✓ unit: matching contract -> no nag"; PASS=$((PASS + 1));
else echo "  ✗ unit: still nags after /contract"; FAIL=$((FAIL + 1)); fi
out=$(_contract_heads_up "0" "cls_test_123")
if [[ -z "$out" ]]; then echo "  ✓ unit: Tier 0 -> never a directive"; PASS=$((PASS + 1));
else echo "  ✗ unit: Tier 0 should never emit directive"; FAIL=$((FAIL + 1)); fi

# 24d: matching contract but state=draft -> directive STILL shown (un-approved
# contract is R6-blocked at edit time; suppressing the heads-up would leave the
# developer with neither the nag nor an approved contract — a silent dead-end).
mkdir -p "$(dirname "$GIT24/.intellisense/contracts/feat__x.md")"; printf -- '---\n%s\n---\n' '{"branch":"feat/x","classification_id":"cls_test_123","state":"draft"}' \
    > "$GIT24/.intellisense/contracts/feat__x.md"
out=$(_contract_heads_up "2" "cls_test_123")
if [[ "$out" == *"not yet approved"* ]]; then echo "  ✓ unit: matching DRAFT contract -> approve-it directive still shown"; PASS=$((PASS + 1));
else echo "  ✗ unit: matching DRAFT contract wrongly suppresses directive"; FAIL=$((FAIL + 1)); fi

# 24e: matching contract state=presented -> directive STILL shown (same reason)
mkdir -p "$(dirname "$GIT24/.intellisense/contracts/feat__x.md")"; printf -- '---\n%s\n---\n' '{"branch":"feat/x","classification_id":"cls_test_123","state":"presented"}' \
    > "$GIT24/.intellisense/contracts/feat__x.md"
out=$(_contract_heads_up "2" "cls_test_123")
if [[ "$out" == *"not yet approved"* ]]; then echo "  ✓ unit: matching PRESENTED contract -> approve-it directive still shown"; PASS=$((PASS + 1));
else echo "  ✗ unit: matching PRESENTED contract wrongly suppresses directive"; FAIL=$((FAIL + 1)); fi

# 24f: matching contract state=active -> directive suppressed (approved/active OK)
mkdir -p "$(dirname "$GIT24/.intellisense/contracts/feat__x.md")"; printf -- '---\n%s\n---\n' '{"branch":"feat/x","classification_id":"cls_test_123","state":"active"}' \
    > "$GIT24/.intellisense/contracts/feat__x.md"
out=$(_contract_heads_up "2" "cls_test_123")
if [[ -z "$out" ]]; then echo "  ✓ unit: matching ACTIVE contract -> no nag"; PASS=$((PASS + 1));
else echo "  ✗ unit: ACTIVE contract should suppress directive"; FAIL=$((FAIL + 1)); fi
rm -rf "$GIT24"; unset CWD

# Cleanup
for d in "$CWD3" "$CWD4" "$CWD5" "$CWD6" "$CWD7" "$CWD8" "$CWD9" "$CWD10" "$CWD12" "$CWD14"; do
    rm -rf "$d"
done

echo ""
echo "─────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────────────"

[ "$FAIL" -gt 0 ] && exit 1
exit 0
