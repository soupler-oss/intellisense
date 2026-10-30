#!/usr/bin/env bash
# test_contract_layer1.sh — Layer 1 contract artifact tests
#
# Surface tested:
#   1. scripts/validate-contract-schema.sh — schema + policy (cases 1–9)
#   2. hooks/pre-push integration — visibility rule + scope checks (cases 10–17)
#
# Out of scope (Layer 2+):
#   - PreToolUse hook tests for Edit/Write/MultiEdit
#   - Compression of development-workflow.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLISENSE_SETUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VALIDATOR="$INTELLISENSE_SETUP_DIR/scripts/validate-contract-schema.sh"
PRE_PUSH="$INTELLISENSE_SETUP_DIR/hooks/pre-push"

source "$SCRIPT_DIR/helpers.sh" 2>/dev/null || true

# Minimal local helpers if helpers.sh did not export the functions we need.
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
TESTS_RUN=${TESTS_RUN:-0}
TESTS_PASSED=${TESTS_PASSED:-0}
TESTS_FAILED=${TESTS_FAILED:-0}

if ! type assert_exit >/dev/null 2>&1; then
    assert_exit() {
        local expected="$1" actual="$2" msg="${3:-exit $expected}"
        ((++TESTS_RUN))
        if [ "$expected" = "$actual" ]; then
            echo -e "  ${GREEN}✓${NC} $msg"
            ((++TESTS_PASSED))
        else
            echo -e "  ${RED}✗${NC} $msg (expected $expected, got $actual)"
            ((++TESTS_FAILED))
        fi
    }
fi

if ! type assert_contains >/dev/null 2>&1; then
    assert_contains() {
        local needle="$1" haystack="$2" msg="${3:-output should contain '$needle'}"
        ((++TESTS_RUN))
        if echo "$haystack" | grep -qF "$needle"; then
            echo -e "  ${GREEN}✓${NC} $msg"
            ((++TESTS_PASSED))
        else
            echo -e "  ${RED}✗${NC} $msg"
            echo -e "      needle: $needle"
            echo -e "      first 200 chars: ${haystack:0:200}"
            ((++TESTS_FAILED))
        fi
    }
fi

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

# Establish a non-git working directory so the validator's branch-staleness
# check is automatically skipped (cases 1–9 are content-only, not git-context).
cd "$WORKDIR"

write_valid_contract() {
    local out="$1"
    cat > "$out" <<'JSON'
{
  "branch": "fixture-branch",
  "mode": "full_feature",
  "requirement": "Layer 1 fixture contract",
  "files_affected": ["a.go", "b.go", "c.go"],
  "estimated_lines": 120,
  "confidence_score": 0.85,
  "risk_level": "low",
  "financial_impact": false,
  "high_risk_files_touched": [],
  "protected_files_touched": [],
  "rollback_strategy": "revert commit",
  "test_strategy": "unit tests",
  "session_id": "fixture-session",
  "prompt_hash": "deadbeef",
  "classification_id": "cls_fixture_deadbeef",
  "state": "approved",
  "impact_analysis": "fixture — populated to suppress Impact Discovery warn-only message",
  "impact_analysis_dismissed_suggestions": ""
}
JSON
}

# ---------------------------------------------------------------------------
# Case 1: valid contract → exit 0
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 1: valid contract"
write_valid_contract "$WORKDIR/c1.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c1.json" 2>&1); rc=$?
assert_exit 0 $rc "valid contract exits 0"
assert_contains "contract valid" "$out" "valid output mentions 'contract valid'"

# ---------------------------------------------------------------------------
# Case 2: missing required field → exit 1
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 2: missing required field (drop 'risk_level')"
write_valid_contract "$WORKDIR/c2.json"
jq 'del(.risk_level)' "$WORKDIR/c2.json" > "$WORKDIR/c2.tmp" && mv "$WORKDIR/c2.tmp" "$WORKDIR/c2.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c2.json" 2>&1); rc=$?
assert_exit 1 $rc "missing field exits 1"
assert_contains "missing required field: risk_level" "$out" "stderr names the missing field"

# ---------------------------------------------------------------------------
# Case 3: R1 — high_risk + risk_level=low → exit 2
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 3: R1 violation (high_risk non-empty, risk_level=low)"
write_valid_contract "$WORKDIR/c3.json"
jq '.high_risk_files_touched = ["hooks/pre-push"] | .risk_level = "low"' \
    "$WORKDIR/c3.json" > "$WORKDIR/c3.tmp" && mv "$WORKDIR/c3.tmp" "$WORKDIR/c3.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c3.json" 2>&1); rc=$?
assert_exit 2 $rc "R1 violation exits 2"
assert_contains "R1:" "$out" "stderr cites R1"

# ---------------------------------------------------------------------------
# Case 4: R2 — protected_files non-empty + no approval_received_at → exit 2
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 4: R2 violation (protected_files non-empty, no approval)"
write_valid_contract "$WORKDIR/c4.json"
jq '.protected_files_touched = ["migrations/001.sql"]' \
    "$WORKDIR/c4.json" > "$WORKDIR/c4.tmp" && mv "$WORKDIR/c4.tmp" "$WORKDIR/c4.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c4.json" 2>&1); rc=$?
assert_exit 2 $rc "R2 violation exits 2"
assert_contains "R2:" "$out" "stderr cites R2"

# ---------------------------------------------------------------------------
# Case 5: R3 — confidence_score < 0.75 → exit 2
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 5: R3 violation (confidence_score=0.6)"
write_valid_contract "$WORKDIR/c5.json"
jq '.confidence_score = 0.6' "$WORKDIR/c5.json" > "$WORKDIR/c5.tmp" && mv "$WORKDIR/c5.tmp" "$WORKDIR/c5.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c5.json" 2>&1); rc=$?
assert_exit 2 $rc "R3 violation exits 2"
assert_contains "R3:" "$out" "stderr cites R3"

# ---------------------------------------------------------------------------
# Case 6: R4 — mode=bug_fix + 4 files → exit 2
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 6: R4 violation (bug_fix + 4 files)"
write_valid_contract "$WORKDIR/c6.json"
jq '.mode = "bug_fix" | .files_affected = ["a.go","b.go","c.go","d.go"]' \
    "$WORKDIR/c6.json" > "$WORKDIR/c6.tmp" && mv "$WORKDIR/c6.tmp" "$WORKDIR/c6.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c6.json" 2>&1); rc=$?
assert_exit 2 $rc "R4 violation exits 2"
assert_contains "R4:" "$out" "stderr cites R4"

# ---------------------------------------------------------------------------
# Case 7: R5 — financial_impact=true + mode=bug_fix → exit 2
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 7: R5 violation (financial=true, mode=bug_fix)"
write_valid_contract "$WORKDIR/c7.json"
jq '.financial_impact = true | .mode = "bug_fix" | .files_affected = ["account.go"]' \
    "$WORKDIR/c7.json" > "$WORKDIR/c7.tmp" && mv "$WORKDIR/c7.tmp" "$WORKDIR/c7.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c7.json" 2>&1); rc=$?
assert_exit 2 $rc "R5 violation exits 2"
assert_contains "R5:" "$out" "stderr cites R5"

# ---------------------------------------------------------------------------
# Case 8: stale contract — branch field mismatches current git branch → exit 1
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 8: stale contract (branch mismatch)"
STALE_REPO=$(mktemp -d)
git -C "$STALE_REPO" init -q
git -C "$STALE_REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$STALE_REPO" checkout -q -b real-branch
write_valid_contract "$STALE_REPO/contract.json"
# JSON has branch="fixture-branch", current branch is "real-branch" → mismatch
out=$(cd "$STALE_REPO" && bash "$VALIDATOR" "$STALE_REPO/contract.json" 2>&1); rc=$?
assert_exit 1 $rc "branch mismatch exits 1"
assert_contains "stale contract" "$out" "stderr says 'stale contract'"
rm -rf "$STALE_REPO"

# ---------------------------------------------------------------------------
# Case 9: file outside scope → exit 2
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 9: file outside declared scope"
write_valid_contract "$WORKDIR/c9.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c9.json" --changed-files="a.go,b.go,intruder.go" 2>&1); rc=$?
assert_exit 2 $rc "scope drift exits 2"
assert_contains "scope drift" "$out" "stderr says 'scope drift'"
assert_contains "intruder.go" "$out" "stderr names the out-of-scope file"

# ---------------------------------------------------------------------------
# Case 9b/9c: filenames with spaces — the
# old cf_trim="${cf// /}" deleted INTERIOR spaces, so a declared
# "docs/foo bar.md" was compared as "docs/foobar.md" and false-blocked.
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 9b: declared filename WITH spaces passes scope check"
jq '.files_affected = ["a.go", "docs/foo bar.md"]' "$WORKDIR/c9.json" > "$WORKDIR/c9b.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c9b.json" --changed-files="a.go,docs/foo bar.md" 2>&1); rc=$?
assert_exit 0 $rc "spaced filename declared in contract validates clean"

echo ""
echo "─── Case 9c: UNdeclared spaced filename still drifts, reported intact"
out=$(bash "$VALIDATOR" "$WORKDIR/c9b.json" --changed-files="docs/other doc.md" 2>&1); rc=$?
assert_exit 2 $rc "undeclared spaced filename still exits 2"
assert_contains "docs/other doc.md" "$out" "stderr names the spaced file UNmangled"

# ---------------------------------------------------------------------------
# Case 9a: Impact Discovery — warn-only fires when impact_analysis empty
# for full_feature mode. Must NOT change exit code.
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 9a: Impact Discovery — impact_analysis empty triggers warning (full_feature)"
write_valid_contract "$WORKDIR/c9a.json"
jq '.impact_analysis = ""' "$WORKDIR/c9a.json" > "$WORKDIR/c9a.tmp" && mv "$WORKDIR/c9a.tmp" "$WORKDIR/c9a.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c9a.json" 2>&1); rc=$?
assert_exit 0 $rc "warn-only does NOT change exit code (still 0)"
assert_contains "[impact-discovery]" "$out" "stderr carries impact-discovery warning tag"
assert_contains "impact_analysis is empty" "$out" "warning explains the cause"
assert_contains "contract valid" "$out" "validator still reports valid"

# ---------------------------------------------------------------------------
# Case 9b: Impact Discovery — warning does NOT fire when impact_analysis populated
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 9b: Impact Discovery — populated impact_analysis suppresses warning"
write_valid_contract "$WORKDIR/c9b.json"
# Fixture already populates impact_analysis; just confirm no warning fires
out=$(bash "$VALIDATOR" "$WORKDIR/c9b.json" 2>&1); rc=$?
assert_exit 0 $rc "valid contract with impact_analysis exits 0"
((++TESTS_RUN))
if ! echo "$out" | grep -qF "[impact-discovery]"; then
    echo -e "  ${GREEN}✓${NC} no impact-discovery warning when impact_analysis is populated"
    ((++TESTS_PASSED))
else
    echo -e "  ${RED}✗${NC} warning unexpectedly fired when impact_analysis was populated"
    ((++TESTS_FAILED))
fi

# ---------------------------------------------------------------------------
# Case 9c: Impact Discovery — warning does NOT fire for design_review_only mode
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 9c: Impact Discovery — design_review_only mode skips warning even with empty field"
write_valid_contract "$WORKDIR/c9c.json"
jq '.mode = "design_review_only" | .impact_analysis = ""' "$WORKDIR/c9c.json" > "$WORKDIR/c9c.tmp" && mv "$WORKDIR/c9c.tmp" "$WORKDIR/c9c.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c9c.json" 2>&1); rc=$?
assert_exit 0 $rc "design_review_only with empty impact_analysis still exits 0"
((++TESTS_RUN))
if ! echo "$out" | grep -qF "[impact-discovery]"; then
    echo -e "  ${GREEN}✓${NC} no warning for design_review_only mode (correct — doesn't ship code)"
    ((++TESTS_PASSED))
else
    echo -e "  ${RED}✗${NC} warning fired for design_review_only mode (incorrect)"
    ((++TESTS_FAILED))
fi

# ---------------------------------------------------------------------------
# Case 9d: Impact Discovery — "n/a — graph unavailable" suppresses warning
# (counts as populated; explicit escape value)
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 9d: Impact Discovery — 'n/a — <reason>' escape suppresses warning"
write_valid_contract "$WORKDIR/c9d.json"
jq '.impact_analysis = "n/a — graph unavailable"' "$WORKDIR/c9d.json" > "$WORKDIR/c9d.tmp" && mv "$WORKDIR/c9d.tmp" "$WORKDIR/c9d.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c9d.json" 2>&1); rc=$?
assert_exit 0 $rc "n/a escape value exits 0"
((++TESTS_RUN))
if ! echo "$out" | grep -qF "[impact-discovery]"; then
    echo -e "  ${GREEN}✓${NC} 'n/a — graph unavailable' is treated as populated"
    ((++TESTS_PASSED))
else
    echo -e "  ${RED}✗${NC} warning fired despite explicit n/a escape"
    ((++TESTS_FAILED))
fi

# ---------------------------------------------------------------------------
# Case 9e: Impact Discovery — wrong type (array) does NOT silently bypass
# impact_analysis: [] must trigger BOTH a type warning
# AND the empty warning (jq // "" alone treats only null/missing as "empty").
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 9e: Impact Discovery — wrong-type impact_analysis triggers type+empty warnings"
write_valid_contract "$WORKDIR/c9e.json"
jq '.impact_analysis = []' "$WORKDIR/c9e.json" > "$WORKDIR/c9e.tmp" && mv "$WORKDIR/c9e.tmp" "$WORKDIR/c9e.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c9e.json" 2>&1); rc=$?
assert_exit 0 $rc "wrong type stays warn-only (exit 0)"
assert_contains "type=array (expected string" "$out" "type-mismatch warning fires"
assert_contains "impact_analysis is empty" "$out" "emptiness warning still fires for wrong type"

# ---------------------------------------------------------------------------
# Case 13 (validator portion): malformed JSON / missing jq → exit 3
# (Pre-push integration of this case lives below as case 13-INT.)
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 13: malformed JSON → exit 3 (internal error)"
echo "{ this is not json" > "$WORKDIR/c13.json"
out=$(bash "$VALIDATOR" "$WORKDIR/c13.json" 2>&1); rc=$?
assert_exit 3 $rc "malformed JSON exits 3"
assert_contains "malformed JSON" "$out" "stderr says 'malformed JSON'"

# ---------------------------------------------------------------------------
# Pre-push integration cases (10, 11, 12, 13-INT, 14, 15, 17)
#
# These spin up a throwaway git repo with origin set to a bare repo so the
# pre-push hook can run end-to-end. .intellisense/session/ is the developer-local
# fixture for the contract artifact.
# ---------------------------------------------------------------------------

setup_throwaway_repo() {
    local stack="${1:-go}"
    local repo
    repo=$(mktemp -d)
    git -C "$repo" init -q -b master
    git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    BARE=$(mktemp -d)
    git -C "$BARE" init --bare -q -b master
    git -C "$repo" remote add origin "$BARE"
    # Push master to bare so origin/master exists — pre-push diffs against it.
    git -C "$repo" push -q origin master
    # NOTE: deliberately do NOT add 'upstream' remote — pre-push Block 2 trips
    # when origin URL equals upstream URL. Tests focus on Tier logic, not fork
    # enforcement (which has its own dedicated test_validate_fork_setup.sh).
    git -C "$repo" checkout -q -b feature/contract-test  # contains slash → encoding test
    # Mark intellisense-managed
    mkdir -p "$repo/.intellisense"
    touch "$repo/.intellisense/MANAGED"
    # Minimal manifest so graph_warn does not error
    echo '{"stack":"'"$stack"'"}' > "$repo/.intellisense/manifest.json"
    # Make the validator discoverable via the in-tree resolution path.
    # The pre-push hook's _contract_resolve_validator() checks
    # $repo_root/scripts/validate-contract-schema.sh first.
    mkdir -p "$repo/scripts"
    cp "$VALIDATOR" "$repo/scripts/validate-contract-schema.sh"
    chmod +x "$repo/scripts/validate-contract-schema.sh"
    echo "$repo:$BARE"
}

run_hook() {
    # Run the hook with the stdin format git uses: <local_ref> <local_sha> <remote_ref> <remote_sha>
    local repo="$1" remote="$2"
    local sha
    sha=$(git -C "$repo" rev-parse HEAD)
    (cd "$repo" && echo "refs/heads/feature/contract-test $sha refs/heads/feature/contract-test 0000000000000000000000000000000000000000" \
        | DEFAULT_BRANCH=master bash "$PRE_PUSH" origin "$remote" 2>&1)
}

# Encoding helper — same scheme as the hook + skill use
safe_branch() { echo "${1//\//__}"; }

write_session_contract() {
    local repo="$1" branch="$2"; shift 2
    local file="$repo/.intellisense/contracts/$(safe_branch "$branch").md"
    mkdir -p "$(dirname "$file")"
    # The fields (JSON is valid YAML) become the contract's front matter.
    { echo ---; cat; echo ---; } > "$file"
    echo "$file"
}

# ---------------------------------------------------------------------------
# Case 10: Tier 0 doc-only, no contract → push succeeds (regression)
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 10: Tier 0 doc-only push, no contract → succeeds"
IFS=':' read -r REPO BARE <<<"$(setup_throwaway_repo go)"
echo "# doc" > "$REPO/some-doc.md"
git -C "$REPO" add some-doc.md
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "docs: harmless"
out=$(run_hook "$REPO" "$BARE"); rc=$?
assert_exit 0 $rc "Tier 0 doc-only push exits 0"
rm -rf "$REPO" "$BARE"

# ---------------------------------------------------------------------------
# Case 11: Tier 1 + task trailer + Change Contract: + valid contract file → succeeds
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 11: Tier 1 + visible artifacts + valid contract file → succeeds"
IFS=':' read -r REPO BARE <<<"$(setup_throwaway_repo go)"
mkdir -p "$REPO/src"
echo "rule" > "$REPO/src/marker.go"   # rules-ish path → Tier 1 by classifier
git -C "$REPO" add src/marker.go
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "feat: add rule

Task: PROJ-1
Change Contract: scope=add rule, files_affected=1, confidence=0.9, risk=low"
write_session_contract "$REPO" "feature/contract-test" <<JSON >/dev/null
{
  "branch": "feature/contract-test",
  "mode": "full_feature",
  "requirement": "Add rule",
  "files_affected": ["src/marker.go"],
  "estimated_lines": 1,
  "confidence_score": 0.9,
  "risk_level": "low",
  "financial_impact": false,
  "high_risk_files_touched": [],
  "protected_files_touched": [],
  "rollback_strategy": "revert",
  "test_strategy": "manual",
  "session_id": "fixture-sid",
  "prompt_hash": "deadbeef",
  "classification_id": "cls_fixture_deadbeef",
  "state": "approved"
}
JSON
out=$(run_hook "$REPO" "$BARE"); rc=$?
assert_exit 0 $rc "Tier 1 + visible + valid contract → exit 0"
assert_contains "contract validated" "$out" "hook reports contract validated"
rm -rf "$REPO" "$BARE"

# ---------------------------------------------------------------------------
# Case 12: Tier 1 + visible artifacts + INVALID contract file (out-of-scope) → BLOCKED
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 12: Tier 1 + visible + invalid contract (file out of scope) → BLOCKED"
IFS=':' read -r REPO BARE <<<"$(setup_throwaway_repo go)"
mkdir -p "$REPO/src" "$REPO/agents"
echo "rule" > "$REPO/src/marker.go"
echo "extra" > "$REPO/agents/extra.md"
git -C "$REPO" add src/marker.go agents/extra.md
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "feat: scope drift

Task: PROJ-1
Change Contract: scope=add rule, risk=low, confidence=0.9"
write_session_contract "$REPO" "feature/contract-test" <<JSON >/dev/null
{
  "branch": "feature/contract-test",
  "mode": "full_feature",
  "requirement": "Add rule",
  "files_affected": ["src/marker.go"],
  "estimated_lines": 1,
  "confidence_score": 0.9,
  "risk_level": "low",
  "financial_impact": false,
  "high_risk_files_touched": [],
  "protected_files_touched": [],
  "rollback_strategy": "revert",
  "test_strategy": "manual",
  "session_id": "fixture-sid",
  "prompt_hash": "deadbeef",
  "classification_id": "cls_fixture_deadbeef",
  "state": "approved"
}
JSON
out=$(run_hook "$REPO" "$BARE"); rc=$?
assert_exit 1 $rc "invalid contract → exit 1 (blocked)"
assert_contains "scope drift" "$out" "hook surfaces scope drift"
rm -rf "$REPO" "$BARE"

# ---------------------------------------------------------------------------
# Case 13-INT: malformed contract file → validator exit 3 → hook WARN + fall through
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 13-INT: malformed contract file → WARN + fall through"
IFS=':' read -r REPO BARE <<<"$(setup_throwaway_repo go)"
mkdir -p "$REPO/src"
echo "rule" > "$REPO/src/marker.go"
git -C "$REPO" add src/marker.go
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "feat: with broken contract

Task: PROJ-1
Change Contract: scope=add rule, risk=low, confidence=0.9"
mkdir -p "$REPO/.intellisense/session"
mkdir -p "$REPO/.intellisense/contracts"
echo "{ broken json" > "$REPO/.intellisense/contracts/feature__contract-test.md"
out=$(run_hook "$REPO" "$BARE"); rc=$?
assert_exit 0 $rc "malformed contract → push proceeds on visible artifacts"
assert_contains "validator internal error" "$out" "hook surfaces validator internal error"
rm -rf "$REPO" "$BARE"

# ---------------------------------------------------------------------------
# Case 14: Tier 1 + NO task trailer + valid contract file → BLOCKED (visibility witness)
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 14: Tier 1 + valid contract but NO task trailer in commit → BLOCKED"
IFS=':' read -r REPO BARE <<<"$(setup_throwaway_repo go)"
mkdir -p "$REPO/src"
echo "rule" > "$REPO/src/marker.go"
git -C "$REPO" add src/marker.go
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "feat: no visible artifacts"
write_session_contract "$REPO" "feature/contract-test" <<JSON >/dev/null
{
  "branch": "feature/contract-test",
  "mode": "full_feature",
  "requirement": "Add rule",
  "files_affected": ["src/marker.go"],
  "estimated_lines": 1,
  "confidence_score": 0.9,
  "risk_level": "low",
  "financial_impact": false,
  "high_risk_files_touched": [],
  "protected_files_touched": [],
  "rollback_strategy": "revert",
  "test_strategy": "manual",
  "session_id": "fixture-sid",
  "prompt_hash": "deadbeef",
  "classification_id": "cls_fixture_deadbeef",
  "state": "approved"
}
JSON
out=$(run_hook "$REPO" "$BARE"); rc=$?
assert_exit 1 $rc "VISIBILITY RULE: a contract never replaces the task trailer → BLOCKED"
# Stable semantics — assert what the failure MEANS, not a specific message string.
assert_contains "BLOCKED" "$out" "hook still emits a BLOCKED signal"
assert_contains "task trailer" "$out" "block message names the task-trailer requirement"
assert_contains "has no task trailer" "$out" "block message is per-commit, not branch-wide"
rm -rf "$REPO" "$BARE"

# ---------------------------------------------------------------------------
# Case 15: Tier 1 + no visible + no contract → BLOCKED (existing behavior)
# ---------------------------------------------------------------------------
echo ""
echo "─── Case 15: Tier 1 + no visible + no contract → BLOCKED (regression)"
IFS=':' read -r REPO BARE <<<"$(setup_throwaway_repo go)"
mkdir -p "$REPO/src"
echo "rule" > "$REPO/src/marker.go"
git -C "$REPO" add src/marker.go
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "feat: bare"
out=$(run_hook "$REPO" "$BARE"); rc=$?
assert_exit 1 $rc "Tier 1 with nothing → blocked (existing behavior)"
# Same stable-semantics pattern as Case 14.
assert_contains "BLOCKED" "$out" "hook emits a BLOCKED signal"
assert_contains "task trailer" "$out" "block message names the task-trailer requirement"
assert_contains "has no task trailer" "$out" "block message is per-commit, not branch-wide"
rm -rf "$REPO" "$BARE"

# Case 17 (orphaned-contract pruning) is gone: contracts are committed with their change
# (.intellisense/contracts/<branch>.md), so they are records, not session scratch to prune.

# ===========================================================================
# Cases Nx–Nq: validator --context={edit|evidence} + R2 evidence
# interaction + pre-push call-shape compatibility + retroactive visible warning
# ===========================================================================

# Helper: write a contract with a custom state, holding all other required
# fields valid. Used by the Nx-N* cases below.
write_contract_with_state() {
    local out="$1"
    local state="$2"
    write_valid_contract "$out"
    jq --arg s "$state" '.state = $s' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
}

# ─── Case Nx: --context=edit + state=retroactive → exit 2 (PreToolUse semantics)
echo ""
echo "─── Case Nx: --context=edit + state=retroactive → exit 2"
write_contract_with_state "$WORKDIR/nx.json" "retroactive"
out=$(bash "$VALIDATOR" "$WORKDIR/nx.json" --context=edit 2>&1); rc=$?
assert_exit 2 "$rc" "edit-context rejects retroactive"
assert_contains "reviewer-evidence" "$out" "R6 message names evidence-only semantic"

# ─── Case Ny: --context=edit + state=evidence_only → exit 2
echo ""
echo "─── Case Ny: --context=edit + state=evidence_only → exit 2"
write_contract_with_state "$WORKDIR/ny.json" "evidence_only"
out=$(bash "$VALIDATOR" "$WORKDIR/ny.json" --context=edit 2>&1); rc=$?
assert_exit 2 "$rc" "edit-context rejects evidence_only"

# ─── Case Nz: --context=evidence + state=retroactive → exit 0 (pre-push semantics)
echo ""
echo "─── Case Nz: --context=evidence + state=retroactive → exit 0"
write_contract_with_state "$WORKDIR/nz.json" "retroactive"
out=$(bash "$VALIDATOR" "$WORKDIR/nz.json" --context=evidence 2>&1); rc=$?
assert_exit 0 "$rc" "evidence-context accepts retroactive"

# ─── Case Nw: --context=evidence + state=evidence_only → exit 0
echo ""
echo "─── Case Nw: --context=evidence + state=evidence_only → exit 0"
write_contract_with_state "$WORKDIR/nw.json" "evidence_only"
out=$(bash "$VALIDATOR" "$WORKDIR/nw.json" --context=evidence 2>&1); rc=$?
assert_exit 0 "$rc" "evidence-context accepts evidence_only"

# ─── Case Nv: --context=evidence + state=draft → exit 2 (incomplete-lifecycle)
echo ""
echo "─── Case Nv: --context=evidence + state=draft → exit 2 (still rejects incomplete)"
write_contract_with_state "$WORKDIR/nv.json" "draft"
out=$(bash "$VALIDATOR" "$WORKDIR/nv.json" --context=evidence 2>&1); rc=$?
assert_exit 2 "$rc" "evidence-context still rejects draft"
assert_contains "incomplete approval" "$out" "R6 evidence message explains why draft fails"

# ─── Case Nu: --context=evidence + state=approved → exit 0 (unchanged)
echo ""
echo "─── Case Nu: --context=evidence + state=approved → exit 0"
write_contract_with_state "$WORKDIR/nu.json" "approved"
out=$(bash "$VALIDATOR" "$WORKDIR/nu.json" --context=evidence 2>&1); rc=$?
assert_exit 0 "$rc" "evidence-context accepts approved (unchanged)"

# ─── Case Nt: invalid --context value → exit 3
echo ""
echo "─── Case Nt: --context=garbage → exit 3 (input validation)"
write_valid_contract "$WORKDIR/nt.json"
out=$(bash "$VALIDATOR" "$WORKDIR/nt.json" --context=garbage 2>&1); rc=$?
assert_exit 3 "$rc" "invalid --context rejected"
assert_contains "invalid --context" "$out" "error names the bad flag value"

# ─── Case Ns: R2 still fires under evidence context
echo ""
echo "─── Case Ns: --context=evidence + protected files + no approval_received_at → exit 2 (R2)"
write_contract_with_state "$WORKDIR/ns.json" "retroactive"
jq '.protected_files_touched = ["migrations/0001.sql"] | .approval_received_at = ""' \
   "$WORKDIR/ns.json" > "$WORKDIR/ns.tmp" && mv "$WORKDIR/ns.tmp" "$WORKDIR/ns.json"
out=$(bash "$VALIDATOR" "$WORKDIR/ns.json" --context=evidence 2>&1); rc=$?
assert_exit 2 "$rc" "evidence context relaxes only R6; R2 still fires"
assert_contains "R2" "$out" "R2 protected-files rule still enforced under evidence context"

# ─── Case Nr: pre-push call shape (--changed-files + --context=evidence coexist)
echo ""
echo "─── Case Nr: validator handles --changed-files AND --context=evidence (pre-push shape)"
write_contract_with_state "$WORKDIR/nr.json" "retroactive"
# files_affected from write_valid_contract is ["a.go","b.go","c.go"]. Pass two
# of those as the changed-files CSV to confirm scope-drift detection still runs.
out=$(bash "$VALIDATOR" "$WORKDIR/nr.json" --changed-files="a.go,b.go" --context=evidence 2>&1); rc=$?
assert_exit 0 "$rc" "validator accepts both flags simultaneously (pre-push exact call shape)"

# ─── Case Nq: pre-push prints visible warning for retroactive/evidence_only ───
# Mirrors Case 11's pre-push integration pattern using the existing
# setup_throwaway_repo + run_hook helpers so origin/master is correctly
# configured and pre-push reaches the Layer 1 contract-validation block.
echo ""
echo "─── Case Nq: pre-push retroactive contract → visible reviewer-evidence warning"
IFS=':' read -r NQ_REPO NQ_BARE <<<"$(setup_throwaway_repo go)"
mkdir -p "$NQ_REPO/src"
echo "x" > "$NQ_REPO/src/marker.go"
git -C "$NQ_REPO" add src/marker.go
git -C "$NQ_REPO" -c user.email=t@t -c user.name=t commit -q -m "feat(nq): retroactive evidence demo

Task: PROJ-2
Change Contract: scope=retroactive evidence demo (details in the session contract), risk=low"
write_session_contract "$NQ_REPO" "feature/contract-test" <<JSON >/dev/null
{
  "branch": "feature/contract-test",
  "mode": "full_feature",
  "requirement": "retroactive evidence fixture",
  "files_affected": ["src/marker.go"],
  "estimated_lines": 1,
  "confidence_score": 0.9,
  "risk_level": "low",
  "financial_impact": false,
  "high_risk_files_touched": [],
  "protected_files_touched": [],
  "rollback_strategy": "revert",
  "test_strategy": "manual",
  "session_id": "nq-session",
  "prompt_hash": "feedbeef",
  "classification_id": "cls_nq_feedbeef",
  "state": "retroactive",
  "impact_analysis": "fixture — retroactive evidence demo"
}
JSON
nq_out=$(run_hook "$NQ_REPO" "$NQ_BARE")
((++TESTS_RUN))
if echo "$nq_out" | grep -qF 'retroactive/evidence_only contract is reviewer evidence ONLY'; then
    echo -e "  ${GREEN}✓${NC} pre-push emitted reviewer-evidence visible warning"
    ((++TESTS_PASSED))
else
    echo -e "  ${RED}✗${NC} expected 'reviewer evidence ONLY' warning in pre-push output"
    echo "    first 500 chars: ${nq_out:0:500}"
    ((++TESTS_FAILED))
fi
rm -rf "$NQ_REPO" "$NQ_BARE"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "─── Summary"
echo "  Run: $TESTS_RUN  Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"

if [ "$TESTS_FAILED" -gt 0 ]; then
    exit 1
fi
exit 0
