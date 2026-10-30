#!/usr/bin/env bash
ENGINE="${INTELLISENSE_BIN:-$(command -v intellisense)}"   # contracts are Markdown; the engine reads/sets their front matter
# tests/test_realflow_approval_binding.sh — Real-flow regression for the
# approval-prompt task-binding bug.
#
# Reproduces the user-reported flow:
#   1. classify account task             → Tier 2/full_feature, classification_id A
#   2. create draft contract            bound to A
#   3. classify "proceed"               → MUST preserve A (overwriting it with B would break R7)
#   4. contract state advances to approved (classifier side effect)
#   5. PreToolUse Edit of declared account file in enforced mode → MUST ALLOW
#   6. classify a genuinely different task → A becomes stale relative to new B
#   7. Edit under enforced mode now WARNS/BLOCKS via R7 (correct behavior)
#
# Closes a missed case: prompt-hash cache
# invalidation must NOT churn the active task identity on approval prompts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLASSIFIER="$REPO_ROOT/scripts/userPromptSubmit-classifier.sh"
GATE="$REPO_ROOT/scripts/preToolUse-contract-gate.sh"
VALIDATOR="$REPO_ROOT/scripts/validate-contract-schema.sh"

PASS=0; FAIL=0
pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1: $2"; FAIL=$((FAIL+1)); }

# ─── Fixture setup ────────────────────────────────────────────────────────────
FIX=$(mktemp -d)
trap 'rm -rf "$FIX" 2>/dev/null' EXIT

git -C "$FIX" init -q
git -C "$FIX" config user.email "test@intellisense.local"
git -C "$FIX" config user.name "intellisense Test"
mkdir -p "$FIX/account"
echo "package account" > "$FIX/account/balance.go"
git -C "$FIX" add account/balance.go
git -C "$FIX" commit -q -m "init"
git -C "$FIX" checkout -q -b feat/account-fix
mkdir -p "$FIX/.intellisense/session"

SETTINGS=$(mktemp)
cat >"$SETTINGS" <<'EOF'
{ "intellisense": { "gate_mode": "enforced", "graph_enforcement": "warn" } }
EOF

SID="rf-$(date +%s)-$$"

run_classify() {
    local prompt="$1"
    printf '{"prompt":%s,"session_id":"%s","cwd":"%s"}' \
        "$(jq -nc --arg p "$prompt" '$p')" "$SID" "$FIX" \
        | INTELLISENSE_CLASSIFIER_LOG=off bash "$CLASSIFIER" >/dev/null 2>&1 || true
}

run_gate() {
    local file="$1"
    local out
    out=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"},"session_id":"%s","cwd":"%s"}' \
        "$file" "$SID" "$FIX" \
        | INTELLISENSE_SETTINGS_FILE="$SETTINGS" \
          INTELLISENSE_VALIDATOR="$VALIDATOR" \
          bash "$GATE" 2>&1)
    local rc=$?
    LAST_GATE_OUT="$out"
    return $rc
}

# ─── Step 1: classify account task ─────────────────────────────────────────────
echo "Step 1: classify account bug-fix task"
run_classify "Fix account balance deduction bug in payment flow"
CLF="$FIX/.intellisense/session/${SID}.classification.json"
[ -f "$CLF" ] || { fail "classification.json not produced" "missing"; exit 1; }
TASK_A_ID=$(jq -r '.classification_id' "$CLF")
TASK_A_HASH=$(jq -r '.prompt_hash' "$CLF")
TASK_A_TIER=$(jq -r '.tier' "$CLF")
TASK_A_MODE=$(jq -r '.mode' "$CLF")
[ -n "$TASK_A_ID" ] && [ "$TASK_A_ID" != "null" ] && pass "task A classification_id captured: $TASK_A_ID" \
    || fail "task A classification_id missing" "$TASK_A_ID"
[ "$TASK_A_TIER" = "2" ] && pass "account task classified as Tier 2" \
    || fail "account task should be Tier 2" "got tier=$TASK_A_TIER"

# ─── Step 2: write a draft contract bound to task A ───────────────────────────
echo "Step 2: write draft contract bound to task A"
CONTRACT="$FIX/.intellisense/contracts/feat__account-fix.md"
mkdir -p "$(dirname "$CONTRACT")"; { echo ---; cat <<JSON
{
  "branch": "feat/account-fix",
  "mode": "full_feature",
  "requirement": "Fix account balance deduction bug",
  "files_affected": ["account/balance.go"],
  "estimated_lines": 50,
  "confidence_score": 0.85,
  "risk_level": "medium",
  "financial_impact": true,
  "high_risk_files_touched": ["account/balance.go"],
  "protected_files_touched": [],
  "rollback_strategy": "revert commit",
  "test_strategy": "regression test on account journal",
  "session_id": "$SID",
  "prompt_hash": "$TASK_A_HASH",
  "classification_id": "$TASK_A_ID",
  "state": "draft"
}
JSON
echo ---; } >"$CONTRACT"
# Run validator from inside the fixture so its `git symbolic-ref` sees the
# fixture's branch (feat/account-fix), not the outer test runner's branch.
(cd "$FIX" && bash "$VALIDATOR" "$CONTRACT" >/dev/null 2>&1); rc=$?
# Schema valid + state=draft → R6 returns exit 2 (policy). That's CORRECT here.
[ "$rc" -eq 2 ] && pass "draft contract is schema-valid but R6 (policy) gates it" \
    || fail "draft contract should fail R6 (exit 2)" "got exit=$rc"

# ─── Step 3: classify "proceed" — MUST preserve task A ───────────────────────
echo "Step 3: classify 'proceed' (approval prompt — must preserve task A)"
run_classify "proceed"
PRESERVED_ID=$(jq -r '.classification_id' "$CLF")
PRESERVED_HASH=$(jq -r '.prompt_hash' "$CLF")
PRESERVED_EVENT=$(jq -r '.last_prompt_event // empty' "$CLF")
PRESERVED_LAST_HASH=$(jq -r '.last_prompt_hash // empty' "$CLF")

[ "$PRESERVED_ID" = "$TASK_A_ID" ] && pass "classification_id preserved (still $TASK_A_ID)" \
    || fail "classification_id changed on approval prompt" "$TASK_A_ID -> $PRESERVED_ID"
[ "$PRESERVED_HASH" = "$TASK_A_HASH" ] && pass "task-origin prompt_hash preserved" \
    || fail "task-origin prompt_hash changed on approval" "$TASK_A_HASH -> $PRESERVED_HASH"
[ "$PRESERVED_EVENT" = "approval" ] && pass "last_prompt_event recorded as 'approval'" \
    || fail "last_prompt_event should be 'approval'" "got '$PRESERVED_EVENT'"
[ -n "$PRESERVED_LAST_HASH" ] && [ "$PRESERVED_LAST_HASH" != "$TASK_A_HASH" ] \
    && pass "last_prompt_hash captures the approval event ($PRESERVED_LAST_HASH != task-origin)" \
    || fail "last_prompt_hash should differ from task-origin hash" "$PRESERVED_LAST_HASH vs $TASK_A_HASH"

# ─── Step 4: contract state should have advanced to approved ──────────────────
echo "Step 4: contract state advances draft -> approved on approval prompt"
NEW_STATE=$("$ENGINE" contract show "$CONTRACT" | jq -r '.state')
[ "$NEW_STATE" = "approved" ] && pass "contract state advanced to approved" \
    || fail "contract state should be 'approved'" "got '$NEW_STATE'"

# ─── Step 5: enforced Edit of declared account file MUST allow ────────────────
echo "Step 5: enforced Edit of account/balance.go after approval — MUST allow"
run_gate "$FIX/account/balance.go"; rc=$?
[ "$rc" -eq 0 ] && pass "Edit allowed under enforced mode after approval (exit 0)" \
    || fail "Edit should allow after approval" "got exit=$rc, out=$LAST_GATE_OUT"

# Auto-transition should have moved approved -> active too.
ACTIVE_STATE=$("$ENGINE" contract show "$CONTRACT" | jq -r '.state')
[ "$ACTIVE_STATE" = "active" ] && pass "first edit auto-transitions approved -> active" \
    || fail "first edit should set state=active" "got '$ACTIVE_STATE'"

# ─── Step 6: classify a genuinely different task — should re-classify ────────
echo "Step 6: classify 'refactor logging utilities' (different task)"
run_classify "refactor logging utilities to use structured logger"
TASK_B_ID=$(jq -r '.classification_id' "$CLF")
TASK_B_EVENT=$(jq -r '.last_prompt_event' "$CLF")
[ "$TASK_B_ID" != "$TASK_A_ID" ] && [ "$TASK_B_EVENT" = "task" ] \
    && pass "genuinely new task → new classification_id (was $TASK_A_ID, now $TASK_B_ID)" \
    || fail "new task should produce new classification_id with event=task" "id=$TASK_B_ID event=$TASK_B_EVENT"

# ─── Step 7: enforced Edit of account under stale task — MUST block via R7 ────
echo "Step 7: enforced Edit of account/balance.go under stale task — MUST block (R7)"
run_gate "$FIX/account/balance.go"; rc=$?
[ "$rc" -eq 2 ] && pass "enforced mode blocks edit when contract is bound to stale task" \
    || fail "should block under enforced (R7 mismatch)" "got exit=$rc"
if echo "$LAST_GATE_OUT" | grep -q "R7\\|classification_id"; then
    pass "block reason cites R7 / classification_id mismatch"
else
    fail "block reason should cite R7" "$LAST_GATE_OUT"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO B: action-verb prompts must RE-CLASSIFY, not slip through as approval
#
# Flow:
#   1. "Review this PR"    → Tier 0 / design_review_only, classification A
#   2. "implement"         → MUST mint a new classification
#   3. otherwise, an enforced Edit to app/driver.go would silently pass under A
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Scenario B: 'Review this PR' -> 'implement' must NOT be treated as approval"
SID_B="rfB-$(date +%s)-$$"
run_classify_sid() {
    local prompt="$1" sid="$2"
    printf '{"prompt":%s,"session_id":"%s","cwd":"%s"}' \
        "$(jq -nc --arg p "$prompt" '$p')" "$sid" "$FIX" \
        | INTELLISENSE_CLASSIFIER_LOG=off bash "$CLASSIFIER" >/dev/null 2>&1 || true
}

run_classify_sid "Review this PR" "$SID_B"
CLF_B="$FIX/.intellisense/session/${SID_B}.classification.json"
B_REVIEW_ID=$(jq -r '.classification_id' "$CLF_B")
B_REVIEW_MODE=$(jq -r '.mode' "$CLF_B")
[ "$B_REVIEW_MODE" = "pr_review" ] || [ "$B_REVIEW_MODE" = "design_review_only" ] \
    && pass "review prompt classifies as read-only mode ($B_REVIEW_MODE)" \
    || fail "review prompt should be read-only mode" "got '$B_REVIEW_MODE'"

run_classify_sid "implement" "$SID_B"
B_IMPL_ID=$(jq -r '.classification_id' "$CLF_B")
B_IMPL_EVENT=$(jq -r '.last_prompt_event' "$CLF_B")
B_IMPL_MODE=$(jq -r '.mode' "$CLF_B")

[ "$B_IMPL_ID" != "$B_REVIEW_ID" ] \
    && pass "'implement' minted a NEW classification_id (was $B_REVIEW_ID, now $B_IMPL_ID)" \
    || fail "'implement' must re-classify, not preserve" "id stayed $B_REVIEW_ID"

[ "$B_IMPL_EVENT" = "task" ] \
    && pass "last_prompt_event recorded as 'task' (NOT 'approval')" \
    || fail "'implement' event should be 'task'" "got '$B_IMPL_EVENT'"

[ "$B_IMPL_MODE" = "full_feature" ] \
    && pass "'implement' triggers full_feature mode (per mode_signals)" \
    || fail "'implement' should land in full_feature" "got '$B_IMPL_MODE'"

# NOTE: 'implement' alone has no Tier 1/2 keyword, so the new classification
# lands at Tier 0 full_feature. Enforced edits on unmarked code paths still
# pass through because PreToolUse has no catch-all-to-Tier-1 rule (pre-push
# does, but that asymmetry is a pre-existing gap tracked separately as a
# follow-up — NOT in scope for this PR). The fix this test
# is guarding is the CLASSIFIER step: 'implement' must re-classify rather
# than silently preserve a prior 'design_review_only' identity. The 4 ✓
# above prove that.

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO C: non-financial Tier 1 approval-binding flow (.github/workflows/)
#
# Mirrors Scenario A's account flow but with a non-financial path so we have
# permanent coverage that the approval / R7 path is not money-specific.
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Scenario C: non-financial Tier 1 approval flow (.github/workflows/deploy.yml)"
mkdir -p "$FIX/.github/workflows"
cat > "$FIX/.github/workflows/deploy.yml" <<'YAML'
name: deploy
on: { push: { branches: [main] } }
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps: [ { uses: actions/checkout@v4 } ]
YAML
git -C "$FIX" add .github/workflows/deploy.yml
git -C "$FIX" commit -q -m "add deploy workflow"
git -C "$FIX" checkout -q -b feat/deploy-fix

SID_C="rfC-$(date +%s)-$$"
run_classify_sid "fix bug in github action workflow file for deploy" "$SID_C"
CLF_C="$FIX/.intellisense/session/${SID_C}.classification.json"
C_TASK_ID=$(jq -r '.classification_id' "$CLF_C")
C_TASK_HASH=$(jq -r '.prompt_hash' "$CLF_C")
C_TIER=$(jq -r '.tier' "$CLF_C")
C_MODE=$(jq -r '.mode' "$CLF_C")
[ "$C_TIER" = "1" ] \
    && pass "deploy workflow task classified as Tier 1 (got tier=$C_TIER, mode=$C_MODE)" \
    || fail "deploy task should be Tier 1" "got tier=$C_TIER mode=$C_MODE"

CONTRACT_C="$FIX/.intellisense/contracts/feat__deploy-fix.md"
mkdir -p "$(dirname "$CONTRACT_C")"; { echo ---; cat <<JSON
{
  "branch": "feat/deploy-fix",
  "mode": "$C_MODE",
  "requirement": "Fix bug in deploy CI workflow",
  "files_affected": [".github/workflows/deploy.yml"],
  "estimated_lines": 20,
  "confidence_score": 0.85,
  "risk_level": "low",
  "financial_impact": false,
  "high_risk_files_touched": [],
  "protected_files_touched": [],
  "rollback_strategy": "revert the workflow commit",
  "test_strategy": "manual: trigger the workflow on a PR; ensure deploy succeeds",
  "session_id": "$SID_C",
  "prompt_hash": "$C_TASK_HASH",
  "classification_id": "$C_TASK_ID",
  "state": "draft"
}
JSON
echo ---; } >"$CONTRACT_C"

# Approval prompt advances draft -> approved
run_classify_sid "proceed" "$SID_C"
C_PRESERVED_ID=$(jq -r '.classification_id' "$CLF_C")
C_STATE=$("$ENGINE" contract show "$CONTRACT_C" | jq -r '.state')
[ "$C_PRESERVED_ID" = "$C_TASK_ID" ] \
    && pass "non-financial: approval preserves classification_id" \
    || fail "non-financial: approval changed classification_id" "$C_TASK_ID -> $C_PRESERVED_ID"
[ "$C_STATE" = "approved" ] \
    && pass "non-financial: contract advanced draft -> approved" \
    || fail "non-financial: contract should be approved" "got '$C_STATE'"

# Enforced Edit of the declared deploy.yml must allow
SETTINGS_C=$(mktemp)
cat >"$SETTINGS_C" <<'EOF'
{ "intellisense": { "gate_mode": "enforced", "graph_enforcement": "warn" } }
EOF
C_GATE_OUT=$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"},"session_id":"%s","cwd":"%s"}' \
    "$FIX/.github/workflows/deploy.yml" "$SID_C" "$FIX" \
    | INTELLISENSE_SETTINGS_FILE="$SETTINGS_C" INTELLISENSE_VALIDATOR="$VALIDATOR" \
      bash "$GATE" 2>&1)
C_GATE_RC=$?
[ "$C_GATE_RC" -eq 0 ] \
    && pass "non-financial: enforced Edit of .github/workflows/deploy.yml allowed after approval" \
    || fail "non-financial: enforced Edit should pass" "exit=$C_GATE_RC out=$C_GATE_OUT"

C_FINAL_STATE=$("$ENGINE" contract show "$CONTRACT_C" | jq -r '.state')
[ "$C_FINAL_STATE" = "active" ] \
    && pass "non-financial: contract auto-transitioned approved -> active on first edit" \
    || fail "non-financial: state should be active" "got '$C_FINAL_STATE'"
rm -f "$SETTINGS_C"

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO D: "do it" after "Review this PR" must re-classify, not preserve
#
# Closes the third-iteration hole: 'do it' is still in approval_prompts as a
# pure approval phrase, but only IF an active contract for the current task
# exists. Without a contract (Tier 0 review case), 'do it' is conversationally
# a task transition, not an approval. The fast-path's classification_id-match
# guard must refuse to fire.
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Scenario D: 'Review this PR' -> 'do it' must NOT preserve as approval"
SID_D="rfD-$(date +%s)-$$"
# Use a clean branch with no contract on disk (mirrors the real Tier 0 case).
git -C "$FIX" checkout -q -b feat/review-noop
run_classify_sid "Review this PR" "$SID_D"
CLF_D="$FIX/.intellisense/session/${SID_D}.classification.json"
D_REVIEW_ID=$(jq -r '.classification_id' "$CLF_D")

run_classify_sid "do it" "$SID_D"
D_DOIT_ID=$(jq -r '.classification_id' "$CLF_D")
D_DOIT_EVENT=$(jq -r '.last_prompt_event' "$CLF_D")

[ "$D_DOIT_ID" != "$D_REVIEW_ID" ] \
    && pass "'do it' with no active contract minted NEW classification_id (was $D_REVIEW_ID, now $D_DOIT_ID)" \
    || fail "'do it' must re-classify when no contract binds to current task" "stayed at $D_REVIEW_ID"

[ "$D_DOIT_EVENT" = "task" ] \
    && pass "'do it' recorded as last_prompt_event='task' (NOT 'approval')" \
    || fail "'do it' event should be 'task' without matching contract" "got '$D_DOIT_EVENT'"

# Sanity: when a CONTRACT DOES exist for the current task, the same 'do it'
# phrase SHOULD still work as approval (this proves we didn't over-fix).
git -C "$FIX" checkout -q -b feat/doit-happy
SID_D2="rfD2-$(date +%s)-$$"
run_classify_sid "Fix account balance bug second flow" "$SID_D2"
CLF_D2="$FIX/.intellisense/session/${SID_D2}.classification.json"
D2_ID=$(jq -r '.classification_id' "$CLF_D2")
D2_HASH=$(jq -r '.prompt_hash' "$CLF_D2")
CONTRACT_D2="$FIX/.intellisense/contracts/feat__doit-happy.md"
mkdir -p "$(dirname "$CONTRACT_D2")"; { echo ---; cat <<JSON
{
  "branch": "feat/doit-happy",
  "mode": "full_feature",
  "requirement": "Fix account balance second flow",
  "files_affected": ["account/balance.go"],
  "estimated_lines": 30,
  "confidence_score": 0.85,
  "risk_level": "medium",
  "financial_impact": true,
  "high_risk_files_touched": ["account/balance.go"],
  "protected_files_touched": [],
  "rollback_strategy": "revert",
  "test_strategy": "regression",
  "session_id": "$SID_D2",
  "prompt_hash": "$D2_HASH",
  "classification_id": "$D2_ID",
  "state": "draft"
}
JSON
echo ---; } >"$CONTRACT_D2"
run_classify_sid "do it" "$SID_D2"
D2_AFTER_ID=$(jq -r '.classification_id' "$CLF_D2")
D2_AFTER_STATE=$("$ENGINE" contract show "$CONTRACT_D2" | jq -r '.state')
[ "$D2_AFTER_ID" = "$D2_ID" ] && [ "$D2_AFTER_STATE" = "approved" ] \
    && pass "'do it' WITH matching contract preserves classification_id + advances state (happy path)" \
    || fail "'do it' happy path broke" "id $D2_ID -> $D2_AFTER_ID, state -> $D2_AFTER_STATE"

# ═══════════════════════════════════════════════════════════════════════════════
# SCENARIO E: approval after task drift must NOT mutate stale contract state
#
# Repro: draft contract for task A, classify task B, then "proceed".
# Before fix: old A-contract advanced draft -> approved (corrupt lifecycle).
# After fix: A-contract state stays 'draft'; the approval prompt re-classifies
# as a fresh task (since no contract binds to B's classification).
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "─── Scenario E: approval after task drift must NOT mutate stale contract"
git -C "$FIX" checkout -q -b feat/drift-test
SID_E="rfE-$(date +%s)-$$"

# Step 1: classify task A and write a draft contract for A.
run_classify_sid "Fix account journal inconsistency for refunds" "$SID_E"
CLF_E="$FIX/.intellisense/session/${SID_E}.classification.json"
E_TASK_A_ID=$(jq -r '.classification_id' "$CLF_E")
E_TASK_A_HASH=$(jq -r '.prompt_hash' "$CLF_E")
CONTRACT_E="$FIX/.intellisense/contracts/feat__drift-test.md"
mkdir -p "$(dirname "$CONTRACT_E")"; { echo ---; cat <<JSON
{
  "branch": "feat/drift-test",
  "mode": "full_feature",
  "requirement": "Fix account journal refund inconsistency",
  "files_affected": ["account/journal.go"],
  "estimated_lines": 40,
  "confidence_score": 0.85,
  "risk_level": "medium",
  "financial_impact": true,
  "high_risk_files_touched": ["account/journal.go"],
  "protected_files_touched": [],
  "rollback_strategy": "revert",
  "test_strategy": "regression",
  "session_id": "$SID_E",
  "prompt_hash": "$E_TASK_A_HASH",
  "classification_id": "$E_TASK_A_ID",
  "state": "draft"
}
JSON
echo ---; } >"$CONTRACT_E"

# Step 2: reclassify to task B (different task) — drift event.
run_classify_sid "refactor account logging helpers to use structured logger" "$SID_E"
E_TASK_B_ID=$(jq -r '.classification_id' "$CLF_E")
[ "$E_TASK_B_ID" != "$E_TASK_A_ID" ] \
    && pass "drift: task B has new classification_id ($E_TASK_A_ID -> $E_TASK_B_ID)" \
    || fail "drift: classification_id should have changed" "stayed $E_TASK_A_ID"

# Step 3: user types "proceed" — must NOT advance the stale A contract.
run_classify_sid "proceed" "$SID_E"
E_CONTRACT_STATE_AFTER=$("$ENGINE" contract show "$CONTRACT_E" | jq -r '.state')
E_AFTER_EVENT=$(jq -r '.last_prompt_event' "$CLF_E")
E_AFTER_CID=$(jq -r '.classification_id' "$CLF_E")

[ "$E_CONTRACT_STATE_AFTER" = "draft" ] \
    && pass "stale contract state preserved as 'draft' (not corrupted to approved)" \
    || fail "stale contract was mutated" "state -> '$E_CONTRACT_STATE_AFTER'"

[ "$E_AFTER_EVENT" = "task" ] \
    && pass "approval-after-drift recorded as 'task' (NOT 'approval')" \
    || fail "approval-after-drift event should be 'task'" "got '$E_AFTER_EVENT'"

[ "$E_AFTER_CID" != "$E_TASK_A_ID" ] \
    && pass "approval-after-drift re-classified (cid != stale A's id)" \
    || fail "approval should have re-classified" "cid stayed $E_AFTER_CID"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "─────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────────────"

rm -f "$SETTINGS" 2>/dev/null
[ "$FAIL" -eq 0 ]
