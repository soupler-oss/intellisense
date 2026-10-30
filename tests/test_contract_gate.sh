#!/usr/bin/env bash
ENGINE="${INTELLISENSE_BIN:-$(command -v intellisense)}"   # contracts are Markdown; the engine reads/sets their front matter
# test_contract_gate.sh — Tests for scripts/preToolUse-contract-gate.sh
#
# Covers 11 scenarios:
#   1. Read-only bash passes through
#   2. .intellisense/session/** path allowlisted (Edit)
#   3. .intellisense/session/** path allowlisted (Bash redirect)
#   4. Pilot mode + missing classification → allow + stderr warn
#   5. Enforced mode + missing classification → block (exit 2)
#   6. Tier 0 classification → allow regardless of contract
#   7. Tier 1 + missing contract → block (exit 2)
#   8. Tier 1 + invalid contract (validator exit 1) → block (exit 2)
#   9. Tier 1 + valid contract → allow
#   10. Bash sed -i triggers mutation classifier
#   11. Bash mutation in /tmp (non-allowlist) on Tier 1 + no contract → block

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$REPO_ROOT/scripts/preToolUse-contract-gate.sh"
VALIDATOR="$REPO_ROOT/scripts/validate-contract-schema.sh"

# Disable the branch-freshness sync gate by default. Several tests
# below run the gate with cwd=$REPO_ROOT to exercise real path-tier patterns,
# which would otherwise trigger a network `git fetch` of this repo's real
# origin. The freshness-specific tests at the end re-enable it explicitly via
# `INTELLISENSE_SKIP_SYNC_CHECK=0`.
export INTELLISENSE_SKIP_SYNC_CHECK=1
export INTELLISENSE_SYNC_REF_LIB="$REPO_ROOT/scripts/lib/sync-ref.sh"

if [ ! -x "$GATE" ]; then
    echo "FATAL: gate script not executable: $GATE" >&2
    exit 1
fi

# Per-test fixture directory
FIXTURE_ROOT=$(mktemp -d)
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

PASS=0
FAIL=0

# ─── Test helpers ─────────────────────────────────────────────────────────────

# run_gate <stdin_json> <gate_mode> <settings_file_path> [classification_json] [contract_json]
# Returns exit code of the gate; stdout/stderr captured into globals.
LAST_STDOUT=""
LAST_STDERR=""
LAST_EXIT=0

run_gate() {
    local payload="$1"
    local settings_file="${2:-}"
    local out err

    out=$(mktemp); err=$(mktemp)
    INTELLISENSE_SETTINGS_FILE="$settings_file" \
        bash "$GATE" <<<"$payload" >"$out" 2>"$err"
    LAST_EXIT=$?
    LAST_STDOUT=$(cat "$out")
    LAST_STDERR=$(cat "$err")
    rm -f "$out" "$err"
}

assert_exit() {
    local expected="$1"
    local label="$2"
    if [ "$LAST_EXIT" -eq "$expected" ]; then
        echo "  ✓ $label (exit=$LAST_EXIT)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label (expected exit $expected, got $LAST_EXIT)"
        echo "    stdout: $LAST_STDOUT"
        echo "    stderr: $LAST_STDERR"
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
        echo "  ✗ $label"
        echo "    expected to contain: $needle"
        echo "    actual: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

setup_fixture() {
    local fixture_dir="$1"
    local gate_mode="$2"
    mkdir -p "$fixture_dir/.intellisense/session"
    git -C "$fixture_dir" init -q -b feat/test 2>/dev/null
    git -C "$fixture_dir" config user.email test@test 2>/dev/null
    git -C "$fixture_dir" config user.name test 2>/dev/null

    local settings="$fixture_dir/settings.json"
    cat >"$settings" <<EOF
{ "intellisense": { "gate_mode": "$gate_mode" } }
EOF
    echo "$settings"
}

write_classification() {
    local fixture_dir="$1"
    local session_id="$2"
    local tier="$3"
    cat >"$fixture_dir/.intellisense/session/${session_id}.classification.json" <<EOF
{ "tier": "$tier", "mode": "bug_fix", "confidence": 0.9 }
EOF
}

write_classification_with_cid() {
    # Like write_classification, but with an explicit classification_id so we
    # can exercise R7 task-binding mismatch from the gate's perspective.
    local fixture_dir="$1"
    local session_id="$2"
    local tier="$3"
    local cid="$4"
    cat >"$fixture_dir/.intellisense/session/${session_id}.classification.json" <<EOF
{ "tier": "$tier", "mode": "bug_fix", "confidence": 0.9, "classification_id": "$cid" }
EOF
}

write_valid_contract() {
    local fixture_dir="$1"
    local branch="$2"
    # Match production convention: slash → double-underscore (see _contract_safe_branch in hooks/pre-push)
    local safe_branch="${branch//\//__}"
    local current_branch
    current_branch=$(git -C "$fixture_dir" symbolic-ref --short HEAD 2>/dev/null)
    mkdir -p "$(dirname "$fixture_dir/.intellisense/contracts/${safe_branch}.md")"; { echo ---; cat <<EOF
{
  "branch": "$current_branch",
  "mode": "bug_fix",
  "requirement": "test",
  "files_affected": ["/tmp/foo.txt"],
  "estimated_lines": 10,
  "confidence_score": 0.9,
  "risk_level": "low",
  "financial_impact": false,
  "high_risk_files_touched": [],
  "protected_files_touched": [],
  "rollback_strategy": "revert",
  "test_strategy": "manual",
  "session_id": "test-session",
  "prompt_hash": "deadbeef",
  "classification_id": "cls_test_deadbeef",
  "state": "approved"
}
EOF
echo ---; } >"$fixture_dir/.intellisense/contracts/${safe_branch}.md"
}

write_invalid_contract() {
    local fixture_dir="$1"
    local branch="$2"
    # Match production convention: slash → double-underscore
    local safe_branch="${branch//\//__}"
    # Missing required fields → validator exits 1
    mkdir -p "$(dirname "$fixture_dir/.intellisense/contracts/${safe_branch}.md")"; printf -- '---\n%s\n---\n' '{"branch":"feat/test","mode":"bug_fix"}' >"$fixture_dir/.intellisense/contracts/${safe_branch}.md"
}

payload() {
    local tool="$1"
    local input="$2"
    local session_id="$3"
    local cwd="$4"
    jq -n --arg t "$tool" --arg s "$session_id" --arg c "$cwd" --argjson i "$input" \
        '{tool_name: $t, tool_input: $i, session_id: $s, cwd: $c}'
}

# ─── Test 0: Branch-slug convention parity across ALL call sites ──────────────
# Pins the `${b//\//__}` convention. Exercises every script that constructs a
# contract filename from a branch name and asserts byte-identical output for
# the same input. If any site diverges (e.g. someone uses `tr '/' '_'`), this
# test fails loudly before c0f68cb-class bugs recur.
#
# Sites exercised:
#   1. hooks/pre-push::_contract_safe_branch  (function definition)
#   2. scripts/preToolUse-contract-gate.sh    (inline ${CURRENT_BRANCH//\//__})
#
# NOT exercised (out of scope, documented for the next contributor):
#   - skills/contract/SKILL.md is a prompt template, not a script. Claude
#     constructs the path following the SKILL prose. There is no writer
#     script to test. If a writer script is ever added, extend this test.
echo "Test 0: branch-slug convention parity across call sites"
PARITY_INPUTS=(
    "master"
    "feat/phase1"
    "feat/phase1-pretooluse-contract-gate"
    "fix/billing/tax-calculation"
    "docs/foo/bar/baz"
    "hotfix/x"
)
parity_extract_pre_push() {
    # Source the function definition out of hooks/pre-push and call it.
    local fn_body
    fn_body=$(awk '/^_contract_safe_branch\(\) \{/,/^\}/' "$REPO_ROOT/hooks/pre-push")
    eval "$fn_body"
    _contract_safe_branch "$1"
}
parity_extract_gate() {
    # Inline expression from preToolUse-contract-gate.sh
    local b="$1"
    echo "${b//\//__}"
}
PARITY_FAIL=0
for input in "${PARITY_INPUTS[@]}"; do
    OUT_PRE_PUSH=$(parity_extract_pre_push "$input")
    OUT_GATE=$(parity_extract_gate "$input")
    if [ "$OUT_PRE_PUSH" != "$OUT_GATE" ]; then
        echo "  ✗ PARITY VIOLATION for input '$input':"
        echo "    hooks/pre-push: $OUT_PRE_PUSH"
        echo "    gate script:    $OUT_GATE"
        PARITY_FAIL=1
        FAIL=$((FAIL + 1))
    fi
done
if [ "$PARITY_FAIL" -eq 0 ]; then
    echo "  ✓ all ${#PARITY_INPUTS[@]} inputs produce byte-identical output across both sites"
    PASS=$((PASS + 1))
fi
# Sanity-check the convention itself is what we expect (not tr '/' '_'):
EXPECTED_FOR_SLASH=$(parity_extract_pre_push "feat/x/y")
if [ "$EXPECTED_FOR_SLASH" = "feat__x__y" ]; then
    echo "  ✓ convention is '/' → '__' (double underscore), as required"
    PASS=$((PASS + 1))
else
    echo "  ✗ convention regression: 'feat/x/y' produced '$EXPECTED_FOR_SLASH' (expected 'feat__x__y')"
    FAIL=$((FAIL + 1))
fi

# ─── Test 1: Read-only bash passes through ────────────────────────────────────
echo "Test 1: read-only bash (grep) passes through"
FIX1=$(mktemp -d)
SETTINGS1=$(setup_fixture "$FIX1" pilot)
run_gate "$(payload Bash '{"command":"grep foo bar.txt"}' s1 "$FIX1")" "$SETTINGS1"
assert_exit 0 "exit 0"

# ─── Test 2: .intellisense/session/** allowlisted (Edit) ──────────────────────────────
echo "Test 2: Edit on .intellisense/session/ path allowlisted"
run_gate "$(payload Edit '{"file_path":".intellisense/contracts/foo.md"}' s2 "$FIX1")" "$SETTINGS1"
assert_exit 0 "exit 0"

# ─── Test 3: .intellisense/session/** allowlisted (Bash redirect) ─────────────────────
echo "Test 3: Bash with redirect into .intellisense/session/ allowlisted"
run_gate "$(payload Bash '{"command":"echo {} > .intellisense/contracts/foo.md"}' s3 "$FIX1")" "$SETTINGS1"
assert_exit 0 "exit 0"

# ─── Test 4: Pilot mode + missing classification → allow + warn ───────────────
echo "Test 4: pilot mode + missing classification → allow with stderr warn"
run_gate "$(payload Write '{"file_path":"/tmp/foo.txt"}' s4 "$FIX1")" "$SETTINGS1"
assert_exit 0 "exit 0"
assert_contains "no classification" "$LAST_STDERR" "stderr warning emitted"

# ─── Test 5: Enforced mode + missing classification → block ───────────────────
echo "Test 5: enforced mode + missing classification → block (exit 2)"
FIX5=$(mktemp -d)
SETTINGS5=$(setup_fixture "$FIX5" enforced)
run_gate "$(payload Write '{"file_path":"/tmp/foo.txt"}' s5 "$FIX5")" "$SETTINGS5"
assert_exit 2 "exit 2 (block)"
assert_contains "Classification missing" "$LAST_STDOUT" "stdout contains block reason"

# ─── Test 6: Tier 0 classification → allow regardless ─────────────────────────
echo "Test 6: Tier 0 classification → allow without contract"
write_classification "$FIX1" tier0sess 0
run_gate "$(payload Write '{"file_path":"/tmp/foo.txt"}' tier0sess "$FIX1")" "$SETTINGS1"
assert_exit 0 "exit 0"

# ─── Test 7: Tier 1 + missing contract → block (enforced mode) ───
# Pilot mode warns instead of blocks. To
# test the block path, use enforced mode.
# NOTE: path is a NON-safe code file (foo.go). A safe doc path (.md/.txt/README)
# would now take the fast lane (Test 7b) — this test asserts the block path for a
# real code edit, which is the behavior that must NOT regress.
echo "Test 7: enforced mode + Tier 1 + missing contract (code file) → block"
FIX7=$(mktemp -d)
SETTINGS7=$(setup_fixture "$FIX7" enforced)
write_classification "$FIX7" t1nocontract 1
run_gate "$(payload Write '{"file_path":"/tmp/foo.go"}' t1nocontract "$FIX7")" "$SETTINGS7"
assert_exit 2 "exit 2 (block in enforced mode)"
assert_contains "Change Contract" "$LAST_STDOUT" "stdout names the missing artifact"

# ─── Test 7b: fast lane — Tier 1 prompt + safe doc path + no contract → ALLOW ──
# A prompt-driven Tier-1 escalation on a cosmetic/doc path with no contract takes
# the fast lane (effective tier drops to path=0). This is the friction reduction.
echo "Test 7b: enforced mode + Tier 1 prompt + safe doc path + no contract → allow (fast lane)"
run_gate "$(payload Write '{"file_path":"README.md"}' t1nocontract "$FIX7")" "$SETTINGS7"
assert_exit 0 "exit 0 (fast lane: doc edit needs no contract)"

# ─── Test 7c: fast lane MUST NOT fire when a dangerous phrase was classified ──
# If the classifier floored the tier for a dangerous phrase, a safe path does
# NOT rescue it — full gating applies (no contract → block in enforced mode).
echo "Test 7c: Tier 1 + dangerous-phrase reasoning + safe path → still block"
FIX7c=$(mktemp -d)
SETTINGS7c=$(setup_fixture "$FIX7c" enforced)
cat >"$FIX7c/.intellisense/session/dngr.classification.json" <<'EOF'
{ "tier": "1", "mode": "bug_fix", "confidence": 0.8,
  "reasoning": ["dangerous phrase (comment out/disable/bypass/...) — behavior change, floored to Tier 1"] }
EOF
run_gate "$(payload Write '{"file_path":"README.md"}' dngr "$FIX7c")" "$SETTINGS7c"
assert_exit 2 "exit 2 (dangerous-phrase floor survives safe path)"
rm -rf "$FIX7c"

# ─── Test 8: Tier 1 + invalid contract → block (validator exit 1 → wrapper 2) ─
echo "Test 8: enforced mode + Tier 1 + invalid contract (validator exit 1) → wrapper exit 2"
write_classification "$FIX7" t1bad 1
write_invalid_contract "$FIX7" "feat/test"
run_gate "$(payload Write '{"file_path":"/tmp/foo.txt"}' t1bad "$FIX7")" "$SETTINGS7"
assert_exit 2 "exit 2 (block, exit code translation)"
assert_contains "validator exit 1" "$LAST_STDOUT" "stdout shows translated validator exit"

# ─── Test 9: Tier 1 + valid contract → allow ──────────────────────────────────
echo "Test 9: Tier 1 + valid contract → allow"
FIX9=$(mktemp -d)
SETTINGS9=$(setup_fixture "$FIX9" pilot)
write_classification "$FIX9" t1good 1
write_valid_contract "$FIX9" "feat/test"
run_gate "$(payload Write '{"file_path":"/tmp/foo.txt"}' t1good "$FIX9")" "$SETTINGS9"
assert_exit 0 "exit 0"

# ─── Test 10: Bash sed -i triggers mutation classifier ────────────────────────
# Enforced mode (pilot warns instead of blocks).
echo "Test 10: enforced mode + Bash sed -i on non-exempt path triggers gate (Tier 1, no contract → block)"
FIX10=$(mktemp -d)
SETTINGS10=$(setup_fixture "$FIX10" enforced)
write_classification "$FIX10" t1sed 1
# Note: /tmp/* is now an EXEMPT path (working files). Use a non-exempt path
# to test that real mutations are gated. /home/user/foo.txt is non-exempt.
run_gate "$(payload Bash '{"command":"sed -i \"s/foo/bar/\" /home/user/real-file.txt"}' t1sed "$FIX10")" "$SETTINGS10"
assert_exit 2 "exit 2 (mutation detected, no contract)"

# ─── Test 10b: /tmp/* exemption (new in Phase 4 false-positive fix) ───────────
echo "Test 10b: Bash sed -i on /tmp/* (exempt) passes through (Tier 1, no contract)"
run_gate "$(payload Bash '{"command":"sed -i \"s/foo/bar/\" /tmp/scratch.txt"}' t1sed "$FIX10")" "$SETTINGS10"
assert_exit 0 "exit 0 (/tmp/* exempt from mutation gate)"

# ─── Test 10c: /dev/null redirect exemption ───────────────────────────────────
echo "Test 10c: Bash redirect to /dev/null passes through (Tier 1, no contract)"
run_gate "$(payload Bash '{"command":"some_cmd > /dev/null 2>&1"}' t1sed "$FIX10")" "$SETTINGS10"
assert_exit 0 "exit 0 (/dev/null exempt from mutation gate)"

# ─── Test 10d: Quoted-string literal does not false-positive ──────────────────
echo "Test 10d: Bash command with 'sed -i' inside quotes is NOT treated as mutation"
run_gate "$(payload Bash '{"command":"echo \"the sed -i flag edits in place\""}' t1sed "$FIX10")" "$SETTINGS10"
assert_exit 0 "exit 0 (quoted-string false-positive avoided)"

# ─── Test 11: Bash mutation pattern false-negative check (eval bypass) ────────
# This is an intentionally documented limitation — we record it.
echo "Test 11: known limitation — eval-based bypass slips through classifier (documented)"
run_gate "$(payload Bash '{"command":"eval \"sed -i s/x/y/ /tmp/x.txt\""}' t1sed "$FIX10")" "$SETTINGS10"
if [ "$LAST_EXIT" -eq 0 ]; then
    echo "  ⚠ DOCUMENTED LIMITATION: eval-wrapped mutation slipped through (exit 0). Pre-push hook is the backstop."
    PASS=$((PASS + 1))
else
    echo "  ✓ eval-wrapped mutation caught (unexpected but acceptable)"
    PASS=$((PASS + 1))
fi

# ─── Hardening tests ────────────────────────────────

# ─── Test 12: gate_mode=pilot + Tier 1+ + no contract → BLOCK ───
# audit_chain_enforcement defaults to enforced, so missing-contract on Tier 1+
# blocks regardless of gate_mode: pilot mode never degrades audit-chain
# failures to warn-and-allow.
echo "Test 12: gate_mode=pilot + Tier 1+ + missing contract → BLOCK (audit-chain enforced by default)"
FIX12=$(mktemp -d)
SETTINGS12=$(setup_fixture "$FIX12" pilot)
write_classification "$FIX12" t12sid 2
# NO contract written — should BLOCK under default audit_chain_enforcement=enforced
run_gate "$(payload Edit '{"file_path":"/tmp/anywhere/x.go"}' t12sid "$FIX12")" "$SETTINGS12"
assert_exit 2 "Tier 1+ missing contract blocks even when gate_mode=pilot"
assert_contains "Tier 2 work requires" "$LAST_STDOUT" "block reason in stdout JSON"
assert_contains "intellisense.audit_chain_enforcement" "$LAST_STDOUT" "reason names the controlling setting"

# ─── Test 13: enforced mode still blocks (regression check) ───────────
echo "Test 13: enforced mode + Tier 1+ + missing contract → block"
FIX13=$(mktemp -d)
SETTINGS13=$(setup_fixture "$FIX13" enforced)
write_classification "$FIX13" t13sid 2
run_gate "$(payload Edit '{"file_path":"/tmp/anywhere/x.go"}' t13sid "$FIX13")" "$SETTINGS13"
assert_exit 2 "enforced mode blocks (no regression)"
assert_contains "Tier 2 work requires" "$LAST_STDOUT" "block reason in stdout JSON"

# ─── Test 14: out-of-scope file blocked in enforced mode ──────────────
echo "Test 14: Tier 1+ + valid contract + file NOT in files_affected → block (enforced)"
FIX14=$(mktemp -d)
SETTINGS14=$(setup_fixture "$FIX14" enforced)
write_classification "$FIX14" t14sid 1
write_valid_contract "$FIX14" "feat/test"
run_gate "$(payload Edit '{"file_path":"/tmp/foo.txt"}' t14sid "$FIX14")" "$SETTINGS14"
# /tmp/foo.txt IS in the test fixture's files_affected — check what write_valid_contract puts there
assert_exit 0 "in-scope file allowed"
# Now try out-of-scope
run_gate "$(payload Edit '{"file_path":"/etc/passwd"}' t14sid "$FIX14")" "$SETTINGS14"
assert_exit 2 "out-of-scope file blocked"
assert_contains "not in contract.files_affected" "$LAST_STDOUT" "block reason names files_affected"

# ─── Test 15: gate_mode=pilot + out-of-scope file → BLOCK ───────
# Scope drift is an audit-chain decision: audit_chain_enforcement=enforced
# (default) blocks regardless of gate_mode.
echo "Test 15: gate_mode=pilot + out-of-scope file → BLOCK (audit-chain enforced)"
FIX15=$(mktemp -d)
SETTINGS15=$(setup_fixture "$FIX15" pilot)
write_classification "$FIX15" t15sid 1
write_valid_contract "$FIX15" "feat/test"
run_gate "$(payload Edit '{"file_path":"/etc/passwd"}' t15sid "$FIX15")" "$SETTINGS15"
assert_exit 2 "out-of-scope file blocks even when gate_mode=pilot"
assert_contains "not in contract.files_affected" "$LAST_STDOUT" "block reason in stdout JSON"

# Cleanup new fixtures
for d in "$FIX12" "$FIX13" "$FIX14" "$FIX15"; do
    rm -rf "$d" 2>/dev/null
done

# ─── Test 19: command-specific Bash arg parsing (no false-blocks) ───
# A previous extraction treated non-path args
# (sed scripts, chmod modes, package names) as paths. Now per-command parsing.
echo "Test 19: command-specific Bash arg parsing — no false-blocks on declared targets"
FIX19=$(mktemp -d)
SETTINGS19=$(setup_fixture "$FIX19" enforced)
write_classification "$FIX19" t19sid 1
# Contract declares: foo.txt + foo.sh + package.json + package-lock.json
mkdir -p "$FIX19/.intellisense/session"
mkdir -p "$(dirname "$FIX19/.intellisense/contracts/feat__test.md")"; { echo ---; cat <<EOF
{"branch":"feat/test","mode":"refactor","requirement":"x","files_affected":["foo.txt","foo.sh","package.json","package-lock.json","yarn.lock","Cargo.toml","Cargo.lock"],"estimated_lines":10,"confidence_score":0.9,"risk_level":"low","financial_impact":false,"high_risk_files_touched":[],"protected_files_touched":[],"rollback_strategy":"x","test_strategy":"x","session_id":"test-sid","prompt_hash":"deadbeef","classification_id":"cls_test_deadbeef","state":"approved"}
EOF
echo ---; } >"$FIX19/.intellisense/contracts/feat__test.md"
# Each ALLOW case must exit 0 (in-scope despite non-path args in command)
ALLOW_CASES=(
    "sed -i s/x/y/ foo.txt"      # sed script s/x/y/ NOT treated as path
    "chmod +x foo.sh"            # mode +x NOT treated as path
    "chown root foo.txt"         # owner NOT treated as path
    "npm install left-pad"       # only package.json + package-lock.json required
    "yarn add somepkg"           # only package.json + yarn.lock required
    "cargo update"               # only Cargo.toml + Cargo.lock required
)
ALLOW_FAIL=0
for cmd in "${ALLOW_CASES[@]}"; do
    run_gate "$(payload Bash "{\"command\":\"$cmd\"}" t19sid "$FIX19")" "$SETTINGS19"
    if [ "$LAST_EXIT" -ne 0 ]; then
        echo "  ✗ '$cmd' false-blocked (exit=$LAST_EXIT)"
        REASON=$(echo "$LAST_STDOUT" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null | head -c 200)
        echo "    reason: $REASON"
        ALLOW_FAIL=$((ALLOW_FAIL + 1))
    fi
done
if [ "$ALLOW_FAIL" -eq 0 ]; then
    echo "  ✓ all ${#ALLOW_CASES[@]} declared-target commands allowed (no false-blocks)"
    PASS=$((PASS + 1))
else
    echo "  ✗ $ALLOW_FAIL false-blocks"
    FAIL=$((FAIL + ALLOW_FAIL))
fi
# Negative cases — undeclared targets MUST still block
BLOCK_CASES=(
    "sed -i s/x/y/ undeclared.txt"
    "chmod +x undeclared.sh"
    "pnpm add foo"  # pnpm-lock.yaml NOT in contract; should block
)
BLOCK_FAIL=0
for cmd in "${BLOCK_CASES[@]}"; do
    run_gate "$(payload Bash "{\"command\":\"$cmd\"}" t19sid "$FIX19")" "$SETTINGS19"
    if [ "$LAST_EXIT" -ne 2 ]; then
        echo "  ✗ '$cmd' should block but exit=$LAST_EXIT"
        BLOCK_FAIL=$((BLOCK_FAIL + 1))
    fi
done
if [ "$BLOCK_FAIL" -eq 0 ]; then
    echo "  ✓ all ${#BLOCK_CASES[@]} undeclared-target commands correctly blocked"
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + BLOCK_FAIL))
fi
rm -rf "$FIX19"

# ─── Test 19c: QUOTED multi-file sed — first file must not be missed ─────────
# With a QUOTED expression and multiple files, stripping the quotes would
# leave file1 as the apparent "expression" and lose it from the scope check.
# Sentinel-replacement of quoted regions preserves token position so file1
# stays in the file list.
echo "Test 19c: quoted multi-file sed — every named file is scope-checked"
FIX19c=$(mktemp -d)
SETTINGS19c=$(setup_fixture "$FIX19c" enforced)
write_classification "$FIX19c" t19csid 1

# Case A: contract declares ONLY file2.txt; quoted sed names file1.txt FIRST →
# must block with reason naming file1.txt.
mkdir -p "$FIX19c/.intellisense/session"
mkdir -p "$(dirname "$FIX19c/.intellisense/contracts/feat__test.md")"; { echo ---; cat <<EOF
{"branch":"feat/test","mode":"refactor","requirement":"x","files_affected":["file2.txt"],"estimated_lines":10,"confidence_score":0.9,"risk_level":"low","financial_impact":false,"high_risk_files_touched":[],"protected_files_touched":[],"rollback_strategy":"x","test_strategy":"x","session_id":"test-sid","prompt_hash":"deadbeef","classification_id":"cls_test_deadbeef","state":"approved"}
EOF
echo ---; } >"$FIX19c/.intellisense/contracts/feat__test.md"
run_gate "$(payload Bash '{"command":"sed -i 's/foo/bar/' file1.txt file2.txt"}' t19csid "$FIX19c")" "$SETTINGS19c"
assert_exit 2 "quoted multi-file sed blocks (was incorrectly allowing — file1 missed)"
assert_contains "file1.txt" "$LAST_STDOUT" "reason names the FIRST file (file1.txt), not just the last"

# Case B: contract declares BOTH file1 + file2; quoted multi-file must allow
mkdir -p "$(dirname "$FIX19c/.intellisense/contracts/feat__test.md")"; { echo ---; cat <<EOF
{"branch":"feat/test","mode":"refactor","requirement":"x","files_affected":["file1.txt","file2.txt"],"estimated_lines":10,"confidence_score":0.9,"risk_level":"low","financial_impact":false,"high_risk_files_touched":[],"protected_files_touched":[],"rollback_strategy":"x","test_strategy":"x","session_id":"test-sid","prompt_hash":"deadbeef","classification_id":"cls_test_deadbeef","state":"approved"}
EOF
echo ---; } >"$FIX19c/.intellisense/contracts/feat__test.md"
run_gate "$(payload Bash '{"command":"sed -i 's/foo/bar/' file1.txt file2.txt"}' t19csid "$FIX19c")" "$SETTINGS19c"
assert_exit 0 "quoted multi-file sed allows when ALL files declared"

# Case C: double-quoted variant — same behavior expected
mkdir -p "$(dirname "$FIX19c/.intellisense/contracts/feat__test.md")"; { echo ---; cat <<EOF
{"branch":"feat/test","mode":"refactor","requirement":"x","files_affected":["file2.txt"],"estimated_lines":10,"confidence_score":0.9,"risk_level":"low","financial_impact":false,"high_risk_files_touched":[],"protected_files_touched":[],"rollback_strategy":"x","test_strategy":"x","session_id":"test-sid","prompt_hash":"deadbeef","classification_id":"cls_test_deadbeef","state":"approved"}
EOF
echo ---; } >"$FIX19c/.intellisense/contracts/feat__test.md"
run_gate "$(payload Bash '{"command":"sed -i \"s/foo/bar/\" file1.txt file2.txt"}' t19csid "$FIX19c")" "$SETTINGS19c"
assert_exit 2 "double-quoted multi-file sed also blocks correctly"
assert_contains "file1.txt" "$LAST_STDOUT" "reason names file1.txt for double-quoted variant too"
rm -rf "$FIX19c"

# ─── Test 19b: multi-file sed extraction ──────────────────
echo "Test 19b: multi-file sed -i extracts ALL target files"
FIX19b=$(mktemp -d)
SETTINGS19b=$(setup_fixture "$FIX19b" enforced)
write_classification "$FIX19b" t19bsid 1
mkdir -p "$FIX19b/.intellisense/session"
mkdir -p "$(dirname "$FIX19b/.intellisense/contracts/feat__test.md")"; { echo ---; cat <<EOF
{"branch":"feat/test","mode":"refactor","requirement":"x","files_affected":["a.txt","b.txt"],"estimated_lines":10,"confidence_score":0.9,"risk_level":"low","financial_impact":false,"high_risk_files_touched":[],"protected_files_touched":[],"rollback_strategy":"x","test_strategy":"x","session_id":"test-sid","prompt_hash":"deadbeef","classification_id":"cls_test_deadbeef","state":"approved"}
EOF
echo ---; } >"$FIX19b/.intellisense/contracts/feat__test.md"
# All files declared → allow
run_gate "$(payload Bash '{"command":"sed -i s/x/y/ a.txt b.txt"}' t19bsid "$FIX19b")" "$SETTINGS19b"
assert_exit 0 "multi-file sed, all in scope, allowed"
# One file undeclared → block naming THAT file
run_gate "$(payload Bash '{"command":"sed -i s/x/y/ a.txt undeclared.txt"}' t19bsid "$FIX19b")" "$SETTINGS19b"
assert_exit 2 "multi-file sed, partial out-of-scope, blocked"
assert_contains "undeclared.txt" "$LAST_STDOUT" "block reason names undeclared.txt (not just last arg)"
# -i.bak shape
run_gate "$(payload Bash '{"command":"sed -i.bak s/x/y/ a.txt b.txt"}' t19bsid "$FIX19b")" "$SETTINGS19b"
assert_exit 0 "sed -i.bak multi-file allowed"
# -ie shape (combined flags)
run_gate "$(payload Bash '{"command":"sed -ie s/x/y/ a.txt"}' t19bsid "$FIX19b")" "$SETTINGS19b"
assert_exit 0 "sed -ie allowed"
rm -rf "$FIX19b"

# ─── Test 19d: sed -e expr1 -e expr2 file — regression for a false block
# Regression for the bug where `-e expr1 -e expr2 file` extracted "expr1" as
# the path because the awk extractor didn't know `-e`/`-f` consume an arg.
# Fix lives in scripts/preToolUse-contract-gate.sh awk block: `expect_flag_arg`
# variable skips the token following `-e` or `-f` before counting positional
# args as candidate paths.
echo "Test 19d: sed -e expr1 -e expr2 file extracts file (not the expressions)"
FIX19d=$(mktemp -d)
SETTINGS19d=$(setup_fixture "$FIX19d" enforced)
write_classification "$FIX19d" t19dsid 1
mkdir -p "$FIX19d/.intellisense/session"
mkdir -p "$(dirname "$FIX19d/.intellisense/contracts/feat__test.md")"; { echo ---; cat <<EOF
{"branch":"feat/test","mode":"refactor","requirement":"x","files_affected":["file1.txt"],"estimated_lines":10,"confidence_score":0.9,"risk_level":"low","financial_impact":false,"high_risk_files_touched":[],"protected_files_touched":[],"rollback_strategy":"x","test_strategy":"x","session_id":"test-sid","prompt_hash":"deadbeef","classification_id":"cls_test_deadbeef","state":"approved"}
EOF
echo ---; } >"$FIX19d/.intellisense/contracts/feat__test.md"
# In-scope file with -e flags should pass (expressions are not paths)
run_gate "$(payload Bash '{"command":"sed -i -e s/a/b/ -e s/c/d/ file1.txt"}' t19dsid "$FIX19d")" "$SETTINGS19d"
assert_exit 0 "sed -i -e expr -e expr file (in scope) allowed"
# Out-of-scope file with -e flags must still block (on the file, not the expr)
run_gate "$(payload Bash '{"command":"sed -i -e s/a/b/ -e s/c/d/ undeclared.txt"}' t19dsid "$FIX19d")" "$SETTINGS19d"
assert_exit 2 "sed -i -e expr -e expr undeclared.txt blocks"
assert_contains "undeclared.txt" "$LAST_STDOUT" "block reason names undeclared.txt, not the sed expression"
# -f flag (script file) must also be skipped
run_gate "$(payload Bash '{"command":"sed -i -f /tmp/script.sed file1.txt"}' t19dsid "$FIX19d")" "$SETTINGS19d"
assert_exit 0 "sed -i -f scriptfile file (in scope) allowed"
rm -rf "$FIX19d"

# ─── Test 20-21: unknown-mutation-no-path — enforced blocks, pilot warns ─────
# Explicit test: a Bash command that matches a mutation pattern
# (so the classifier knows mutation happened) but has no per-command parser
# in _extract_paths_for_bash — extraction returns empty. In enforced mode the
# gate MUST block (cannot verify scope); in pilot mode MUST warn and allow.
# `dd of=...` is the canonical example: matches the dd-output pattern but no
# parser handles its arg syntax.
echo "Test 20: unknown mutation + no extractable path — enforced blocks"
FIX20=$(mktemp -d)
SETTINGS20=$(setup_fixture "$FIX20" enforced)
write_classification "$FIX20" t20sid 1
write_valid_contract "$FIX20" "feat/test"
run_gate "$(payload Bash '{"command":"dd if=/dev/zero of=foo.bin bs=1024"}' t20sid "$FIX20")" "$SETTINGS20"
assert_exit 2 "enforced blocks unknown-no-path mutation"
assert_contains "path could not be extracted" "$LAST_STDOUT" "block reason names the no-path condition"

echo "Test 21: unknown mutation + no extractable path + pilot → BLOCK"
# Unscopeable Bash mutation on Tier 1+ is an
# audit-chain decision; audit_chain_enforcement=enforced (default) blocks
# regardless of gate_mode.
SETTINGS21=$(setup_fixture "$FIX20" pilot)
run_gate "$(payload Bash '{"command":"dd if=/dev/zero of=foo.bin bs=1024"}' t20sid "$FIX20")" "$SETTINGS21"
assert_exit 2 "audit-chain blocks unknown-no-path mutation even in pilot"
assert_contains "path could not be extracted" "$LAST_STDOUT" "block reason names the no-path condition"
rm -rf "$FIX20"

# ─── Test 18+: expanded Bash mutation coverage ──────────────────────
# gate must catch common Claude-emitted file
# mutations beyond sed -i / redirects. Each command below MUST trigger
# the mutation classifier (so the gate at least gets to its tier/contract
# checks instead of allowing the bash through unconditionally).
echo "Test 18: expanded Bash mutation patterns"
FIX18=$(mktemp -d)
SETTINGS18=$(setup_fixture "$FIX18" enforced)
write_classification "$FIX18" t18sid 1
# Tier 1 + no contract → out-of-scope mutation = block in enforced mode
EXPANDED_CMDS=(
    "mkdir newdir"
    "touch foo.go"
    "chmod +x foo.sh"
    "ln -s a b"
    "gofmt -w main.go"
    "prettier --write src/"
    "ruff --fix ."
    "go mod tidy"
    "git checkout HEAD -- file.go"
    "git rm old.go"
    "npm install foo"
)
EXP_PASS=0
EXP_FAIL=0
for cmd in "${EXPANDED_CMDS[@]}"; do
    run_gate "$(payload Bash "{\"command\":\"$cmd\"}" t18sid "$FIX18")" "$SETTINGS18"
    # All these should hit the gate logic. Tier 1 + no contract = block (exit 2).
    if [ "$LAST_EXIT" -eq 2 ]; then
        EXP_PASS=$((EXP_PASS + 1))
    else
        echo "  ✗ '$cmd' did NOT trigger gate (exit=$LAST_EXIT, expected 2)"
        EXP_FAIL=$((EXP_FAIL + 1))
    fi
done
if [ "$EXP_FAIL" -eq 0 ]; then
    echo "  ✓ all ${#EXPANDED_CMDS[@]} expanded patterns trigger the gate"
    PASS=$((PASS + 1))
else
    echo "  ✗ $EXP_FAIL of ${#EXPANDED_CMDS[@]} expanded patterns missed"
    FAIL=$((FAIL + EXP_FAIL))
fi
rm -rf "$FIX18"

# ─── Test 22-26: Settings freshness check ──────────────────────
# The gate hook compares intellisense.config_version in local ~/.claude/settings.json
# against the central template at ${INTELLISENSE_SETUP_PATH}/.claude/settings.json.template.
# A mismatch prints a throttled stderr warning so devs re-sync via setup.sh.
# Failure-isolated: any error in the check must NEVER block edits.

# Helper: build a settings.json fixture with explicit config_version.
setup_fixture_with_version() {
    local fixture_dir="$1"
    local gate_mode="$2"
    local config_version="$3"
    mkdir -p "$fixture_dir/.intellisense/session"
    git -C "$fixture_dir" init -q -b feat/test 2>/dev/null
    git -C "$fixture_dir" config user.email test@test 2>/dev/null
    git -C "$fixture_dir" config user.name test 2>/dev/null

    local settings="$fixture_dir/settings.json"
    if [ -n "$config_version" ]; then
        cat >"$settings" <<EOF
{ "intellisense": { "gate_mode": "$gate_mode", "config_version": $config_version } }
EOF
    else
        cat >"$settings" <<EOF
{ "intellisense": { "gate_mode": "$gate_mode" } }
EOF
    fi
    echo "$settings"
}

# Helper: build a template fixture with explicit config_version.
write_template_fixture() {
    local path="$1"
    local config_version="$2"
    cat >"$path" <<EOF
{ "intellisense": { "gate_mode": "pilot", "graph_enforcement": "warn", "config_version": $config_version } }
EOF
}

# Test 22: versions match → no warning
echo "Test 22: freshness — versions match → no warning emitted"
FIX22=$(mktemp -d)
SETTINGS22=$(setup_fixture_with_version "$FIX22" pilot 1)
TEMPLATE22="$FIX22/template.json"
write_template_fixture "$TEMPLATE22" 1
TIMESTAMP22="$FIX22/last-warned"
export INTELLISENSE_TEMPLATE_FILE="$TEMPLATE22"
export INTELLISENSE_FRESHNESS_TIMESTAMP_FILE="$TIMESTAMP22"
run_gate "$(payload Bash '{"command":"grep foo bar.txt"}' s22 "$FIX22")" "$SETTINGS22"
assert_exit 0 "fresh install allows"
if [[ "$LAST_STDERR" != *"config_version"* ]]; then
    echo "  ✓ no freshness warning when versions match"
    PASS=$((PASS + 1))
else
    echo "  ✗ unexpected freshness warning fired when versions matched"
    echo "    stderr: $LAST_STDERR"
    FAIL=$((FAIL + 1))
fi
unset INTELLISENSE_TEMPLATE_FILE INTELLISENSE_FRESHNESS_TIMESTAMP_FILE
rm -rf "$FIX22"

# Test 23: stale config (template newer) → warning fires
echo "Test 23: freshness — template version > local version → stderr warning"
FIX23=$(mktemp -d)
SETTINGS23=$(setup_fixture_with_version "$FIX23" pilot 1)
TEMPLATE23="$FIX23/template.json"
write_template_fixture "$TEMPLATE23" 2
TIMESTAMP23="$FIX23/last-warned"
export INTELLISENSE_TEMPLATE_FILE="$TEMPLATE23"
export INTELLISENSE_FRESHNESS_TIMESTAMP_FILE="$TIMESTAMP23"
run_gate "$(payload Bash '{"command":"grep foo bar.txt"}' s23 "$FIX23")" "$SETTINGS23"
assert_exit 0 "stale config does NOT block edits"
assert_contains "config_version" "$LAST_STDERR" "stderr names config_version drift"
assert_contains "setup.sh" "$LAST_STDERR" "stderr names the recovery command"
unset INTELLISENSE_TEMPLATE_FILE INTELLISENSE_FRESHNESS_TIMESTAMP_FILE
rm -rf "$FIX23"

# Test 24: throttled (recently warned) → no warning this invocation
echo "Test 24: freshness — recent warning timestamp throttles repeat warning"
FIX24=$(mktemp -d)
SETTINGS24=$(setup_fixture_with_version "$FIX24" pilot 1)
TEMPLATE24="$FIX24/template.json"
write_template_fixture "$TEMPLATE24" 2  # mismatch — would warn if not throttled
TIMESTAMP24="$FIX24/last-warned"
date +%s > "$TIMESTAMP24"  # just warned NOW
export INTELLISENSE_TEMPLATE_FILE="$TEMPLATE24"
export INTELLISENSE_FRESHNESS_TIMESTAMP_FILE="$TIMESTAMP24"
run_gate "$(payload Bash '{"command":"grep foo bar.txt"}' s24 "$FIX24")" "$SETTINGS24"
assert_exit 0 "throttled invocation allows"
if [[ "$LAST_STDERR" != *"config_version"* ]]; then
    echo "  ✓ recent timestamp suppresses repeat warning"
    PASS=$((PASS + 1))
else
    echo "  ✗ throttle did not suppress warning"
    echo "    stderr: $LAST_STDERR"
    FAIL=$((FAIL + 1))
fi
unset INTELLISENSE_TEMPLATE_FILE INTELLISENSE_FRESHNESS_TIMESTAMP_FILE
rm -rf "$FIX24"

# Test 25: escape hatch (INTELLISENSE_SKIP_FRESHNESS_CHECK=1) → no warning
echo "Test 25: freshness — INTELLISENSE_SKIP_FRESHNESS_CHECK=1 silences check"
FIX25=$(mktemp -d)
SETTINGS25=$(setup_fixture_with_version "$FIX25" pilot 1)
TEMPLATE25="$FIX25/template.json"
write_template_fixture "$TEMPLATE25" 2  # mismatch — would warn without escape hatch
TIMESTAMP25="$FIX25/last-warned"
export INTELLISENSE_TEMPLATE_FILE="$TEMPLATE25"
export INTELLISENSE_FRESHNESS_TIMESTAMP_FILE="$TIMESTAMP25"
export INTELLISENSE_SKIP_FRESHNESS_CHECK=1
run_gate "$(payload Bash '{"command":"grep foo bar.txt"}' s25 "$FIX25")" "$SETTINGS25"
assert_exit 0 "escape hatch allows"
if [[ "$LAST_STDERR" != *"config_version"* ]]; then
    echo "  ✓ INTELLISENSE_SKIP_FRESHNESS_CHECK=1 silences freshness warning"
    PASS=$((PASS + 1))
else
    echo "  ✗ escape hatch did not silence warning"
    echo "    stderr: $LAST_STDERR"
    FAIL=$((FAIL + 1))
fi
unset INTELLISENSE_TEMPLATE_FILE INTELLISENSE_FRESHNESS_TIMESTAMP_FILE INTELLISENSE_SKIP_FRESHNESS_CHECK
rm -rf "$FIX25"

# Test 27: template lacking config_version field → silent pass
echo "Test 27: freshness — template without config_version field → no warning"
FIX27=$(mktemp -d)
SETTINGS27=$(setup_fixture_with_version "$FIX27" pilot 1)
TEMPLATE27="$FIX27/template.json"
# Template with no config_version key under the intellisense namespace
cat >"$TEMPLATE27" <<EOF
{ "intellisense": { "gate_mode": "pilot", "graph_enforcement": "warn" } }
EOF
TIMESTAMP27="$FIX27/last-warned"
export INTELLISENSE_TEMPLATE_FILE="$TEMPLATE27"
export INTELLISENSE_FRESHNESS_TIMESTAMP_FILE="$TIMESTAMP27"
run_gate "$(payload Bash '{"command":"grep foo bar.txt"}' s27 "$FIX27")" "$SETTINGS27"
assert_exit 0 "template without config_version allows"
if [[ "$LAST_STDERR" != *"config_version"* ]]; then
    echo "  ✓ no warning emitted when template lacks config_version field"
    PASS=$((PASS + 1))
else
    echo "  ✗ spurious warning fired on template without config_version"
    echo "    stderr: $LAST_STDERR"
    FAIL=$((FAIL + 1))
fi
# Also assert no throttle file was written (function should have returned early)
if [ ! -f "$TIMESTAMP27" ]; then
    echo "  ✓ no throttle file written without a template config_version"
    PASS=$((PASS + 1))
else
    echo "  ✗ throttle file written without a template config_version"
    FAIL=$((FAIL + 1))
fi
unset INTELLISENSE_TEMPLATE_FILE INTELLISENSE_FRESHNESS_TIMESTAMP_FILE
rm -rf "$FIX27"

# Test 26: failure isolation — corrupt template, hook still allows + no spam
echo "Test 26: freshness — corrupt template → hook still allows + no jq error spam"
FIX26=$(mktemp -d)
SETTINGS26=$(setup_fixture_with_version "$FIX26" pilot 1)
TEMPLATE26="$FIX26/template.json"
echo "{ this is not valid JSON :::" > "$TEMPLATE26"
TIMESTAMP26="$FIX26/last-warned"
export INTELLISENSE_TEMPLATE_FILE="$TEMPLATE26"
export INTELLISENSE_FRESHNESS_TIMESTAMP_FILE="$TIMESTAMP26"
run_gate "$(payload Bash '{"command":"grep foo bar.txt"}' s26 "$FIX26")" "$SETTINGS26"
assert_exit 0 "corrupt template does NOT block the edit (failure-isolated)"
if [[ "$LAST_STDERR" != *"config_version"* ]] && [[ "$LAST_STDERR" != *"jq: error"* ]]; then
    echo "  ✓ no warning + no jq error spam on corrupt template"
    PASS=$((PASS + 1))
else
    echo "  ✗ failure isolation broken — leaked error to stderr"
    echo "    stderr: $LAST_STDERR"
    FAIL=$((FAIL + 1))
fi
unset INTELLISENSE_TEMPLATE_FILE INTELLISENSE_FRESHNESS_TIMESTAMP_FILE
rm -rf "$FIX26"

# =============================================================================
# Tests 28-47: audit-chain enforcement separated from gate_mode
# =============================================================================

# Helper: write a settings.json with custom intellisense.audit_chain_enforcement value.
# The standard setup_fixture only sets gate_mode; this layers on top.
write_settings_with_audit_chain() {
    local fixture_dir="$1"
    local gate_mode="$2"
    local audit_chain="$3"
    local settings="$fixture_dir/settings.json"
    mkdir -p "$fixture_dir/.intellisense/session"
    git -C "$fixture_dir" init -q -b feat/test 2>/dev/null || true
    git -C "$fixture_dir" config user.email test@test 2>/dev/null
    git -C "$fixture_dir" config user.name test 2>/dev/null
    cat >"$settings" <<EOF
{ "intellisense": { "gate_mode": "$gate_mode", "audit_chain_enforcement": "$audit_chain" } }
EOF
    echo "$settings"
}

# ─── Test 28: state=draft → BLOCK (R6 edit context via audit-chain) ──────────
echo "Test 28: gate_mode=pilot + state=draft → BLOCK (R6 via audit-chain)"
FIX28=$(mktemp -d); SETTINGS28=$(setup_fixture "$FIX28" pilot)
write_classification "$FIX28" t28sid 1
write_valid_contract "$FIX28" "feat/test"
"$ENGINE" contract set "$FIX28/.intellisense/contracts/feat__test.md" state=draft
run_gate "$(payload Edit '{"file_path":"/tmp/foo.txt"}' t28sid "$FIX28")" "$SETTINGS28"
assert_exit 2 "state=draft blocks under audit-chain (edit context)"
assert_contains "state=draft" "$LAST_STDOUT" "R6 reason surfaced"
rm -rf "$FIX28"

# ─── Test 29: state=presented → BLOCK ────────────────────────────────────────
echo "Test 29: gate_mode=pilot + state=presented → BLOCK"
FIX29=$(mktemp -d); SETTINGS29=$(setup_fixture "$FIX29" pilot)
write_classification "$FIX29" t29sid 1
write_valid_contract "$FIX29" "feat/test"
"$ENGINE" contract set "$FIX29/.intellisense/contracts/feat__test.md" state=presented
run_gate "$(payload Edit '{"file_path":"/tmp/foo.txt"}' t29sid "$FIX29")" "$SETTINGS29"
assert_exit 2 "state=presented blocks"
assert_contains "state=presented" "$LAST_STDOUT" "R6 reason surfaced"
rm -rf "$FIX29"

# ─── Test 30: state=retroactive → BLOCK (reviewer-evidence only, edit ctx) ────
echo "Test 30: gate_mode=pilot + state=retroactive → BLOCK (reviewer-evidence only)"
FIX30=$(mktemp -d); SETTINGS30=$(setup_fixture "$FIX30" pilot)
write_classification "$FIX30" t30sid 1
write_valid_contract "$FIX30" "feat/test"
"$ENGINE" contract set "$FIX30/.intellisense/contracts/feat__test.md" state=retroactive
run_gate "$(payload Edit '{"file_path":"/tmp/foo.txt"}' t30sid "$FIX30")" "$SETTINGS30"
assert_exit 2 "state=retroactive blocks at edit time (reviewer-evidence only)"
assert_contains "reviewer-evidence" "$LAST_STDOUT" "R6 message names the evidence-only semantic"
rm -rf "$FIX30"

# ─── Test 31: state=evidence_only → BLOCK ─────────────────────────────────────
echo "Test 31: gate_mode=pilot + state=evidence_only → BLOCK"
FIX31=$(mktemp -d); SETTINGS31=$(setup_fixture "$FIX31" pilot)
write_classification "$FIX31" t31sid 1
write_valid_contract "$FIX31" "feat/test"
"$ENGINE" contract set "$FIX31/.intellisense/contracts/feat__test.md" state=evidence_only
run_gate "$(payload Edit '{"file_path":"/tmp/foo.txt"}' t31sid "$FIX31")" "$SETTINGS31"
assert_exit 2 "state=evidence_only blocks at edit time"
assert_contains "reviewer-evidence" "$LAST_STDOUT" "R6 message names the evidence-only semantic"
rm -rf "$FIX31"

# ─── Test 32: classification_id mismatch + pilot → BLOCK (R7 via audit-chain) ─
echo "Test 32: gate_mode=pilot + wrong classification_id → BLOCK (R7 via audit-chain)"
FIX32=$(mktemp -d); SETTINGS32=$(setup_fixture "$FIX32" pilot)
# Classification carries cls_NEW; contract (written by write_valid_contract) carries cls_test_deadbeef.
write_classification_with_cid "$FIX32" t32sid 1 "cls_NEW_taskA"
write_valid_contract "$FIX32" "feat/test"
run_gate "$(payload Edit '{"file_path":"/tmp/foo.txt"}' t32sid "$FIX32")" "$SETTINGS32"
assert_exit 2 "classification_id mismatch blocks under audit-chain"
assert_contains "R7" "$LAST_STDOUT" "R7 reason surfaced"
rm -rf "$FIX32"

# ─── Test 33: audit_chain_enforcement=warn opt-out → allow + [audit-chain warn] ─
echo "Test 33: audit_chain_enforcement=warn + Tier 1+ missing contract → warn-and-allow"
FIX33=$(mktemp -d); SETTINGS33=$(write_settings_with_audit_chain "$FIX33" pilot warn)
write_classification "$FIX33" t33sid 2
# No contract written; would normally block. Opt-out should let it through.
INTELLISENSE_AUDIT_LOG33=$(mktemp -d)
INTELLISENSE_AUDIT_CHAIN_LOG_DIR="$INTELLISENSE_AUDIT_LOG33" run_gate \
    "$(payload Edit '{"file_path":"/tmp/anywhere/x.go"}' t33sid "$FIX33")" "$SETTINGS33"
assert_exit 0 "explicit opt-out restores warn-and-allow"
assert_contains "[audit-chain warn]" "$LAST_STDERR" "loud opt-out prefix in stderr"
rm -rf "$FIX33" "$INTELLISENSE_AUDIT_LOG33"

# ─── Test 34: Tier 0 + pilot + no contract → allow (unchanged) ────────────────
echo "Test 34: gate_mode=pilot + Tier 0 + no contract → allow (Tier 0 unchanged)"
FIX34=$(mktemp -d); SETTINGS34=$(setup_fixture "$FIX34" pilot)
write_classification "$FIX34" t34sid 0
run_gate "$(payload Edit '{"file_path":"/tmp/anywhere/x.txt"}' t34sid "$FIX34")" "$SETTINGS34"
assert_exit 0 "Tier 0 still passes without contract"
rm -rf "$FIX34"

# ─── Test 35: Tier 0 path + pilot + NO classification → warn (advisory) ───────
echo "Test 35: gate_mode=pilot + no classification + Tier 0 path → warn (gate_mode governs advisory)"
FIX35=$(mktemp -d); SETTINGS35=$(setup_fixture "$FIX35" pilot)
# no write_classification — file absent; Edit on a Tier 0 path (documentation: the engine's level-0 tier)
run_gate "$(payload Edit '{"file_path":"/tmp/anywhere/x.md"}' nosid "$FIX35")" "$SETTINGS35"
assert_exit 0 "missing classification + Tier 0 path → gate_mode advisory (pilot warn)"
assert_contains "no classification" "$LAST_STDERR" "advisory stderr emitted"
rm -rf "$FIX35"

# ─── Test 36: Tier 1+ path + pilot + NO classification → BLOCK (audit-chain) ──
echo "Test 36: gate_mode=pilot + no classification + Tier 1+ path → BLOCK (audit-chain)"
FIX36=$(mktemp -d); SETTINGS36=$(setup_fixture "$FIX36" pilot)
mkdir -p "$FIX36/scripts"
touch "$FIX36/scripts/preToolUse-contract-gate.sh"
# NO write_classification — classification absent; INTELLISENSE_EFFECTIVE_TIER_LIB
# points at real library so PATH_TIER computes 1 from "scripts/*".
INTELLISENSE_EFFECTIVE_TIER_LIB="$REPO_ROOT/scripts/lib/effective-tier.sh" run_gate \
    "$(payload Edit '{"file_path":"scripts/preToolUse-contract-gate.sh"}' nosid "$FIX36")" "$SETTINGS36"
assert_exit 2 "Tier 1+ path with missing classification blocks under audit-chain"
assert_contains "Classification missing for Tier" "$LAST_STDOUT" "block reason names tier"
rm -rf "$FIX36"

# ─── Test 37: warn-mode → JSONL audit row written ─────────────────────────────
echo "Test 37: audit_chain_enforcement=warn → JSONL audit row written"
FIX37=$(mktemp -d); SETTINGS37=$(write_settings_with_audit_chain "$FIX37" pilot warn)
write_classification "$FIX37" t37sid 2
INTELLISENSE_AUDIT_LOG37=$(mktemp -d)
INTELLISENSE_AUDIT_CHAIN_LOG_DIR="$INTELLISENSE_AUDIT_LOG37" run_gate \
    "$(payload Edit '{"file_path":"/tmp/y.go"}' t37sid "$FIX37")" "$SETTINGS37"
assert_exit 0 "warn-mode allows"
if [ -f "$INTELLISENSE_AUDIT_LOG37/audit-chain-warnings.jsonl" ] && \
   jq -e '.tool_name == "Edit" and (.reason | contains("Tier")) and (.session_id == "t37sid")' \
       "$INTELLISENSE_AUDIT_LOG37/audit-chain-warnings.jsonl" >/dev/null 2>&1; then
    echo "  ✓ JSONL audit row written with expected fields"; PASS=$((PASS + 1))
else
    echo "  ✗ JSONL audit row missing or malformed"; FAIL=$((FAIL + 1))
    echo "    log contents: $(cat "$INTELLISENSE_AUDIT_LOG37/audit-chain-warnings.jsonl" 2>/dev/null)"
fi
rm -rf "$FIX37" "$INTELLISENSE_AUDIT_LOG37"

# ─── Test 38: BASH_MUTATION_NO_PATH=1 + NO classification → BLOCK ─────────────
echo "Test 38: pilot + no classification + Bash mutation w/ unextractable path → BLOCK"
FIX38=$(mktemp -d); SETTINGS38=$(setup_fixture "$FIX38" pilot)
# No write_classification — classification absent
# `dd of=...` matches the dd-output mutation pattern but has no per-command
# parser in _extract_paths_for_bash, so BASH_MUTATION_NO_PATH=1 is set.
# Combined with missing classification: tier cannot be determined → audit-chain
# blocks via check (a) in the gate's reordered flow.
run_gate "$(payload Bash '{"command":"dd if=/dev/zero of=/tmp/foo.bin bs=1024"}' nosid "$FIX38")" "$SETTINGS38"
assert_exit 2 "Bash mutation + no classification + unextractable path blocks under audit-chain"
assert_contains "Cannot prove this is Tier 0" "$LAST_STDOUT" "block reason names the uncertainty"
rm -rf "$FIX38"

# ─── Test 39: degraded install + Tier 1+ path + enforced → BLOCK ──────────────
echo "Test 39: degraded install (library missing) + Tier 1+ path → BLOCK (fail-closed)"
FIX39=$(mktemp -d); SETTINGS39=$(setup_fixture "$FIX39" pilot)
mkdir -p "$FIX39/scripts"
touch "$FIX39/scripts/foo.sh"
write_classification "$FIX39" t39sid 0  # would be Tier 0 by prompt; library would escalate
# Library missing forces fail-closed
INTELLISENSE_EFFECTIVE_TIER_LIB="/nonexistent/path/effective-tier.sh" run_gate \
    "$(payload Edit '{"file_path":"scripts/foo.sh"}' t39sid "$FIX39")" "$SETTINGS39"
assert_exit 2 "library missing blocks under default enforced"
assert_contains "Effective-tier library unavailable" "$LAST_STDOUT" "reason names the missing library"
rm -rf "$FIX39"

# ─── Test 40: degraded install + Tier 0 path + enforced → BLOCK ───────────────
# Per user direction: "blocked as setup error is acceptable; cannot prove Tier 0
# without source-of-truth library." Library-missing → audit-chain fires for ALL
# paths, including ones that would have been Tier 0 if the library were present.
echo "Test 40: degraded install + Tier 0 path + enforced → BLOCK (setup error acceptable)"
FIX40=$(mktemp -d); SETTINGS40=$(setup_fixture "$FIX40" pilot)
write_classification "$FIX40" t40sid 0
INTELLISENSE_EFFECTIVE_TIER_LIB="/nonexistent/path/effective-tier.sh" run_gate \
    "$(payload Edit '{"file_path":"/tmp/foo.txt"}' t40sid "$FIX40")" "$SETTINGS40"
assert_exit 2 "library missing blocks even on Tier 0 path"
assert_contains "Effective-tier library unavailable" "$LAST_STDOUT" "reason names the missing library"
rm -rf "$FIX40"

# ─── Test 41: degraded install + audit_chain_enforcement=warn → allow + JSONL ─
echo "Test 41: degraded install + warn-mode → allow + JSONL audit"
FIX41=$(mktemp -d); SETTINGS41=$(write_settings_with_audit_chain "$FIX41" pilot warn)
write_classification "$FIX41" t41sid 0
INTELLISENSE_AUDIT_LOG41=$(mktemp -d)
INTELLISENSE_EFFECTIVE_TIER_LIB="/nonexistent/path/effective-tier.sh" \
INTELLISENSE_AUDIT_CHAIN_LOG_DIR="$INTELLISENSE_AUDIT_LOG41" run_gate \
    "$(payload Edit '{"file_path":"/tmp/foo.txt"}' t41sid "$FIX41")" "$SETTINGS41"
assert_exit 0 "warn-mode allows even on library-missing"
assert_contains "[audit-chain warn]" "$LAST_STDERR" "loud opt-out stderr"
if [ -f "$INTELLISENSE_AUDIT_LOG41/audit-chain-warnings.jsonl" ] && \
   jq -e '.reason | contains("Effective-tier library unavailable")' \
       "$INTELLISENSE_AUDIT_LOG41/audit-chain-warnings.jsonl" >/dev/null 2>&1; then
    echo "  ✓ JSONL audit row recorded library-missing reason"; PASS=$((PASS + 1))
else
    echo "  ✗ JSONL audit row missing or wrong content"; FAIL=$((FAIL + 1))
fi
rm -rf "$FIX41" "$INTELLISENSE_AUDIT_LOG41"

# ─── Test 42: normal install + Tier 0 + valid classification → ALLOW ──────────
# Regression: library-missing branch must NOT fire when library is present.
echo "Test 42: normal install + Tier 0 edit → ALLOW"
FIX42=$(mktemp -d); SETTINGS42=$(setup_fixture "$FIX42" pilot)
write_classification "$FIX42" t42sid 0
INTELLISENSE_EFFECTIVE_TIER_LIB="$REPO_ROOT/scripts/lib/effective-tier.sh" run_gate \
    "$(payload Edit '{"file_path":"/tmp/foo.txt"}' t42sid "$FIX42")" "$SETTINGS42"
assert_exit 0 "Tier 0 with library present still passes (no library-missing block)"
rm -rf "$FIX42"

# =============================================================================
# Tests 43-47: hardening (settings defaults, audit-log failure,
# schema parity, protected-path matrix, multi-file mixed-tier)
# =============================================================================

# ─── Test 43: audit_chain_enforcement defaults to enforced ────────────────────
echo "Test 43a: audit_chain_enforcement key MISSING → defaults to enforced"
FIX43=$(mktemp -d)
mkdir -p "$FIX43/.intellisense/session"
git -C "$FIX43" init -q -b feat/test 2>/dev/null
git -C "$FIX43" config user.email test@test 2>/dev/null
git -C "$FIX43" config user.name test 2>/dev/null
SETTINGS43a="$FIX43/settings_no_key.json"
cat >"$SETTINGS43a" <<'EOF'
{ "intellisense": { "gate_mode": "pilot" } }
EOF
write_classification "$FIX43" t43sid 2
run_gate "$(payload Edit '{"file_path":"/tmp/x.go"}' t43sid "$FIX43")" "$SETTINGS43a"
assert_exit 2 "missing audit_chain_enforcement key → enforced default"

echo "Test 43b: audit_chain_enforcement INVALID value → defaults to enforced"
SETTINGS43b="$FIX43/settings_invalid.json"
cat >"$SETTINGS43b" <<'EOF'
{ "intellisense": { "gate_mode": "pilot", "audit_chain_enforcement": "garbage" } }
EOF
run_gate "$(payload Edit '{"file_path":"/tmp/x.go"}' t43sid "$FIX43")" "$SETTINGS43b"
assert_exit 2 "invalid audit_chain_enforcement value → enforced default"

echo "Test 43c: settings file MISSING → defaults to enforced"
run_gate "$(payload Edit '{"file_path":"/tmp/x.go"}' t43sid "$FIX43")" "$FIX43/does_not_exist.json"
assert_exit 2 "missing settings file → enforced default"
rm -rf "$FIX43"

# ─── Test 44: audit log write failure → still allows + secondary stderr ──────
echo "Test 44: warn-mode + unwritable audit log dir → allow + 'audit log write failed' stderr"
FIX44=$(mktemp -d); SETTINGS44=$(write_settings_with_audit_chain "$FIX44" pilot warn)
write_classification "$FIX44" t44sid 2
# Create the log dir, drop write perms, then point at a child inside it that
# can never be created. (chmod-ing the dir read-only blocks mkdir -p of child.)
INTELLISENSE_AUDIT_LOG44=$(mktemp -d); chmod 0500 "$INTELLISENSE_AUDIT_LOG44"
INTELLISENSE_AUDIT_CHAIN_LOG_DIR="$INTELLISENSE_AUDIT_LOG44/blocked_subdir" run_gate \
    "$(payload Edit '{"file_path":"/tmp/x.go"}' t44sid "$FIX44")" "$SETTINGS44"
assert_exit 0 "warn-mode still allows on logging failure (break-glass)"
assert_contains "audit log write failed" "$LAST_STDERR" "secondary loud stderr emitted"
chmod +w "$INTELLISENSE_AUDIT_LOG44" 2>/dev/null
rm -rf "$FIX44" "$INTELLISENSE_AUDIT_LOG44"

# ─── Test 45: schema state enum == validator VALID_STATE (drift control) ─────
echo "Test 45: schema state enum == validator VALID_STATE (parity)"
schema_states=$(jq -r '.properties.state.enum | sort | join(" ")' "$REPO_ROOT/skills/contract/schema.json")
shell_line=$(grep -E "^VALID_STATE='" "$REPO_ROOT/scripts/validate-contract-schema.sh")
shell_states=$(echo "$shell_line" | sed -E "s/^VALID_STATE='//; s/'$//" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$schema_states" = "$shell_states" ]; then
    echo "  ✓ schema enum [$schema_states] matches VALID_STATE [$shell_states]"
    PASS=$((PASS + 1))
else
    echo "  ✗ DRIFT: schema=[$schema_states] shell=[$shell_states]"
    FAIL=$((FAIL + 1))
fi

# ─── Test 46: protected-path missing-classification matrix (6 sub-cases) ─────
echo "Test 46: missing classification + protected path → BLOCK (6 paths)"
PROTECTED_MATRIX=(
    "setup.sh"
    "hooks/pre-push"
    "scripts/preToolUse-contract-gate.sh"
    "rules/baseline/security.md"
    ".github/workflows/intellisense.yml"
    "skills/contract/SKILL.md"
)
for path in "${PROTECTED_MATRIX[@]}"; do
    FIXm=$(mktemp -d); SETTINGSm=$(setup_fixture "$FIXm" pilot)
    # These are this repository's protected paths: judge them by its own policy (the engine reads it).
    cp "$REPO_ROOT/.intellisense.yml" "$FIXm/.intellisense.yml"
    mkdir -p "$FIXm/$(dirname "$path")" 2>/dev/null
    touch "$FIXm/$path" 2>/dev/null
    # NO write_classification — classification absent
    INTELLISENSE_EFFECTIVE_TIER_LIB="$REPO_ROOT/scripts/lib/effective-tier.sh" run_gate \
        "$(payload Edit "$(jq -nc --arg p "$path" '{file_path: $p}')" nosid "$FIXm")" "$SETTINGSm"
    if [ "$LAST_EXIT" -eq 2 ]; then
        echo "  ✓ $path → BLOCK (exit 2)"; PASS=$((PASS + 1))
    else
        echo "  ✗ $path → exit $LAST_EXIT (expected 2)"
        echo "    stdout: $LAST_STDOUT"
        echo "    stderr: $LAST_STDERR"
        FAIL=$((FAIL + 1))
    fi
    rm -rf "$FIXm"
done

# ─── Test 47: multi-file mixed-tier Bash mutation + missing classification ───
echo "Test 47: Bash mutating Tier 0 + Tier 1 files + missing classification → BLOCK"
FIX47=$(mktemp -d); SETTINGS47=$(setup_fixture "$FIX47" pilot)
mkdir -p "$FIX47/scripts"
touch "$FIX47/scripts/foo.sh"
# NO write_classification.
# sed -i with two file arguments: /tmp/x (Tier 0) AND scripts/foo.sh (Tier 1).
# Effective tier = max(0, 1) = 1 → audit-chain blocks even though PROMPT_TIER missing.
INTELLISENSE_EFFECTIVE_TIER_LIB="$REPO_ROOT/scripts/lib/effective-tier.sh" run_gate \
    "$(payload Bash '{"command":"sed -i s/x/y/ /tmp/x scripts/foo.sh"}' nosid "$FIX47")" "$SETTINGS47"
assert_exit 2 "mixed-tier mutation with missing classification blocks (highest tier wins)"
assert_contains "Classification missing for Tier" "$LAST_STDOUT" "block reason names Tier"
rm -rf "$FIX47"

# ─── Test 48: routing telemetry — repeated same escalation deduped to one event ─
# writer was overcounting (one row per gated edit). Fix records
# once per stable {from_tier, to_tier, trigger, reason} per session.
echo "Test 48: routing telemetry — 3 repeated account edits write only ONE event"
FIX48=$(mktemp -d); SETTINGS48=$(setup_fixture "$FIX48" pilot)
write_classification "$FIX48" sid48 0
mkdir -p "$FIX48/app/account"
touch "$FIX48/app/account/Account.php"
for _i in 1 2 3; do
    INTELLISENSE_EFFECTIVE_TIER_LIB="$REPO_ROOT/scripts/lib/effective-tier.sh" run_gate \
        "$(payload Edit '{"file_path":"app/account/Account.php"}' sid48 "$FIX48")" "$SETTINGS48" >/dev/null
done
ROUTING48="$FIX48/.intellisense/session/sid48.routing.jsonl"
if [ -f "$ROUTING48" ]; then
    NUM48=$(wc -l <"$ROUTING48" | tr -d ' ')
    if [ "$NUM48" = "1" ]; then
        echo "  ✓ 3 gated invocations → 1 unique routing event"
        PASS=$((PASS + 1))
    else
        echo "  ✗ expected 1 event, got $NUM48"
        cat "$ROUTING48"
        FAIL=$((FAIL + 1))
    fi
    EID48=$(jq -r '.event_id // empty' "$ROUTING48" 2>/dev/null)
    if [ -n "$EID48" ]; then
        echo "  ✓ event carries event_id ($EID48)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ event missing event_id"
        cat "$ROUTING48"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  ✗ routing.jsonl never written"
    FAIL=$((FAIL + 1))
fi
rm -rf "$FIX48"

# ─── Test 49: routing telemetry — distinct escalations write two events ─────────
echo "Test 49: routing telemetry — Tier 0→1 then Tier 0→2 writes two distinct events"
FIX49=$(mktemp -d); SETTINGS49=$(setup_fixture "$FIX49" pilot)
write_classification "$FIX49" sid49 0
mkdir -p "$FIX49/scripts" "$FIX49/app/account"
touch "$FIX49/scripts/foo.sh"
touch "$FIX49/app/account/Account.php"
INTELLISENSE_EFFECTIVE_TIER_LIB="$REPO_ROOT/scripts/lib/effective-tier.sh" run_gate \
    "$(payload Edit '{"file_path":"scripts/foo.sh"}' sid49 "$FIX49")" "$SETTINGS49" >/dev/null
INTELLISENSE_EFFECTIVE_TIER_LIB="$REPO_ROOT/scripts/lib/effective-tier.sh" run_gate \
    "$(payload Edit '{"file_path":"app/account/Account.php"}' sid49 "$FIX49")" "$SETTINGS49" >/dev/null
ROUTING49="$FIX49/.intellisense/session/sid49.routing.jsonl"
if [ -f "$ROUTING49" ]; then
    NUM49=$(wc -l <"$ROUTING49" | tr -d ' ')
    if [ "$NUM49" = "2" ]; then
        echo "  ✓ distinct escalations → 2 events"
        PASS=$((PASS + 1))
    else
        echo "  ✗ expected 2 events, got $NUM49"
        cat "$ROUTING49"
        FAIL=$((FAIL + 1))
    fi
    DISTINCT=$(jq -r '.event_id // empty' "$ROUTING49" 2>/dev/null | sort -u | grep -c .)
    if [ "$DISTINCT" = "2" ]; then
        echo "  ✓ event_ids are distinct between escalation steps"
        PASS=$((PASS + 1))
    else
        echo "  ✗ event_ids not distinct (got $DISTINCT unique)"
        cat "$ROUTING49"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  ✗ routing.jsonl never written"
    FAIL=$((FAIL + 1))
fi
rm -rf "$FIX49"

# ─── Test 50: chained read-only Bash with `;` separator → ALLOW ──────────────
# The path extractor must stop at `;`: for `cmd 2>/dev/null; other_cmd` the
# path is `/dev/null`, not `/dev/null;` — otherwise the exempt-entry match
# fails and a read-only command is treated as a mutation and blocked on R7.
echo "Test 50a: ';'-chained read-only redirects to /dev/null → ALLOW"
FIX50a=$(mktemp -d); SETTINGS50a=$(setup_fixture "$FIX50a" pilot)
write_classification "$FIX50a" t50asid 1
INTELLISENSE_EFFECTIVE_TIER_LIB="$REPO_ROOT/scripts/lib/effective-tier.sh" run_gate \
    "$(payload Bash '{"command":"ls file 2>/dev/null; ls dir 2>/dev/null"}' t50asid "$FIX50a")" "$SETTINGS50a"
assert_exit 0 "';'-chained 2>/dev/null does not capture semicolon as path"
rm -rf "$FIX50a"

echo "Test 50b: ';'-chained with real-file redirect still mutation-detected"
FIX50b=$(mktemp -d); SETTINGS50b=$(setup_fixture "$FIX50b" pilot)
write_classification "$FIX50b" t50bsid 1
# Real redirect to a non-exempt path; should still trip the gate (no contract → block).
INTELLISENSE_EFFECTIVE_TIER_LIB="$REPO_ROOT/scripts/lib/effective-tier.sh" run_gate \
    "$(payload Bash '{"command":"echo x > /tmp/somefile.txt; ls"}' t50bsid "$FIX50b")" "$SETTINGS50b"
# /tmp/* is exempt per the wrapper's exempt-path list, so this case still allows.
# The point of 50b is that the path EXTRACTION itself doesn't break — i.e.
# `/tmp/somefile.txt` is extracted cleanly (no semicolon attached), so the
# exempt branch fires correctly.
assert_exit 0 "redirect to /tmp/* in ';'-chained command extracts path cleanly + exempts"
rm -rf "$FIX50b"

# ══════════════════════════════════════════════════════════════════════════════
# BRANCH FRESHNESS SYNC GATE — pre-edit (plan v7)
# Hermetic: local bare remotes only (no network). Freshness is re-enabled
# per-invocation (the suite disables it by default above).
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Branch freshness sync gate (pre-edit) ──"

SYNC_LIB="$REPO_ROOT/scripts/lib/sync-ref.sh"

# run_gate_fresh <payload> <settings_file> — like run_gate but with the
# freshness check ENABLED (INTELLISENSE_SKIP_SYNC_CHECK=0).
run_gate_fresh() {
    local payload="$1" settings="$2" out err
    out=$(mktemp); err=$(mktemp)
    INTELLISENSE_SKIP_SYNC_CHECK=0 INTELLISENSE_SETTINGS_FILE="$settings" INTELLISENSE_SYNC_REF_LIB="$SYNC_LIB" \
        bash "$GATE" <<<"$payload" >"$out" 2>"$err"
    LAST_EXIT=$?; LAST_STDOUT=$(cat "$out"); LAST_STDERR=$(cat "$err"); rm -f "$out" "$err"
}

# setup_behind_repo <basedir> <behind>  — builds work + bare origin/upstream;
# when behind=1, work/main is 1 commit behind origin/main AND upstream/main.
setup_behind_repo() {
    local d="$1" behind="$2"
    git init -q --bare "$d/up.git"; git init -q --bare "$d/origin.git"
    git init -q -b main "$d/work"
    git -C "$d/work" config user.email t@t; git -C "$d/work" config user.name t
    printf 'base\n' >"$d/work/seed.txt"
    git -C "$d/work" add seed.txt; git -C "$d/work" commit -qm base
    git -C "$d/work" remote add upstream "$d/up.git"
    git -C "$d/work" remote add origin "$d/origin.git"
    git -C "$d/work" push -q upstream main; git -C "$d/work" push -q origin main
    if [ "$behind" -gt 0 ]; then
        git -C "$d/work" checkout -q -b adv
        printf 'theirs\n' >>"$d/work/seed.txt"
        git -C "$d/work" commit -qam advance
        git -C "$d/work" push -q upstream adv:main; git -C "$d/work" push -q origin adv:main
        git -C "$d/work" checkout -q main
    fi
    git -C "$d/work" fetch -q upstream; git -C "$d/work" fetch -q origin
    git -C "$d/work" remote set-head upstream main >/dev/null 2>&1
    git -C "$d/work" remote set-head origin main >/dev/null 2>&1
    mkdir -p "$d/work/.intellisense/session"
}

assert_lib() { # <expected> <actual> <label>
    if [ "$1" = "$2" ]; then echo "  ✓ $3"; PASS=$((PASS + 1));
    else echo "  ✗ $3 (expected '$1' got '$2')"; FAIL=$((FAIL + 1)); fi
}

# ── parse_integration_ref adversarial unit table (RR-I3 / RR-I7) ──
FSPARSE=$(mktemp -d); setup_behind_repo "$FSPARSE" 1
( . "$SYNC_LIB"
  R="$FSPARSE/work"
  assert_lib "ok|explicit"           "$(sync_parse_integration_ref "$R" "upstream/main"        | cut -f1,2 | tr '\t' '|')" "valid explicit upstream/main"
  assert_lib "ok|explicit"           "$(sync_parse_integration_ref "$R" "upstream/release/2.4" | cut -f1,2 | tr '\t' '|')" "slashed branch passes check-ref-format"
  assert_lib "config_error|explicit" "$(sync_parse_integration_ref "$R" "upstream/feat..x"     | cut -f1,2 | tr '\t' '|')" "'..' rejected (config_error)"
  assert_lib "config_error|explicit" "$(sync_parse_integration_ref "$R" "upstream/x@{0}"       | cut -f1,2 | tr '\t' '|')" "'@{' rejected (config_error)"
  assert_lib "config_error|explicit" "$(sync_parse_integration_ref "$R" "upstream/x.lock"      | cut -f1,2 | tr '\t' '|')" "trailing .lock rejected (config_error)"
  assert_lib "config_error|explicit" "$(sync_parse_integration_ref "$R" "-upstream/x"          | cut -f1,2 | tr '\t' '|')" "leading dash rejected (config_error)"
  assert_lib "config_error|explicit" "$(sync_parse_integration_ref "$R" "noslashbranch"        | cut -f1,2 | tr '\t' '|')" "no remote segment rejected (config_error)"
  assert_lib "config_error|explicit" "$(sync_parse_integration_ref "$R" ""                     | cut -f1,2 | tr '\t' '|')" "empty rejected (config_error)"
  assert_lib "infra|explicit"        "$(sync_parse_integration_ref "$R" "nosuchremote/x"       | cut -f1,2 | tr '\t' '|')" "missing remote = infra (NOT config_error)"
  # resolver determinism / parity basis (RR-I4): both gates call this function.
  assert_lib "ok|inferred"           "$(sync_resolve_integration_ref "$R" 0 | cut -f1,2 | tr '\t' '|')" "resolve (no manifest, gh off) = inferred"
)
rm -rf "$FSPARSE"

# ── Fork-targeting correctness (post-review #1): upstream MUST win over the
# fork's own master, even when upstream/HEAD is not set locally. ──
FSFORK=$(mktemp -d)
git init -q --bare "$FSFORK/origin.git"; git init -q --bare "$FSFORK/upstream.git"
git -C "$FSFORK/upstream.git" symbolic-ref HEAD refs/heads/master   # control upstream default
git init -q -b master "$FSFORK/work"
git -C "$FSFORK/work" config user.email t@t; git -C "$FSFORK/work" config user.name t
printf 'A\n' >"$FSFORK/work/f.txt"; git -C "$FSFORK/work" add f.txt; git -C "$FSFORK/work" commit -qm A
git -C "$FSFORK/work" remote add origin "$FSFORK/origin.git"
git -C "$FSFORK/work" remote add upstream "$FSFORK/upstream.git"
git -C "$FSFORK/work" push -q origin master; git -C "$FSFORK/work" push -q upstream master
git -C "$FSFORK/work" checkout -q -b adv
printf 'B\n' >>"$FSFORK/work/f.txt"; git -C "$FSFORK/work" commit -qam B
git -C "$FSFORK/work" push -q upstream adv:master   # upstream/master now A+B
git -C "$FSFORK/work" checkout -q master            # work=A: == fork master, 1 behind upstream
git -C "$FSFORK/work" fetch -q origin; git -C "$FSFORK/work" fetch -q upstream
git -C "$FSFORK/work" remote set-head origin master >/dev/null 2>&1   # origin/HEAD set...
# ...but DELIBERATELY unset upstream/HEAD (some git versions auto-create it on
# fetch via followRemoteHEAD) so the ls-remote / fail-open paths are exercised.
git -C "$FSFORK/work" symbolic-ref --delete refs/remotes/upstream/HEAD 2>/dev/null || true
( . "$SYNC_LIB"
  R="$FSFORK/work"
  git -C "$R" symbolic-ref --delete refs/remotes/upstream/HEAD 2>/dev/null || true
  rec=$(sync_resolve_integration_ref "$R" 0)
  assert_lib "ok|inferred|upstream" \
    "$(sync_rec_status "$rec")|$(sync_rec_confidence "$rec")|$(sync_rec_remote "$rec")" \
    "upstream/HEAD unset → resolves upstream via ls-remote, NOT origin/fork-master"
  # Behind MUST be 1 (vs upstream B). If it had targeted origin/master (the fork,
  # == work), behind would be 0 — a false 'fresh'. This is the Case-1 guard.
  assert_lib "1" "$(sync_fetch_and_behind "$R" "$(sync_rec_remote "$rec")" "$(sync_rec_branch "$rec")")" \
    "behind computed vs upstream (=1), not false-fresh vs fork master"
  # upstream unresolvable (bogus url) + no upstream/HEAD → fail-open infra, NEVER origin.
  git -C "$R" symbolic-ref --delete refs/remotes/upstream/HEAD 2>/dev/null || true
  git -C "$R" remote set-url upstream /tmp/intellisense-nonexistent-bogus.git
  assert_lib "infra" "$(sync_resolve_integration_ref "$R" 0 | cut -f1)" \
    "upstream unresolvable → fail-open (never falls back to fork master)"
)
rm -rf "$FSFORK"

# ── No-upstream (single-remote / non-fork) still infers from origin ──
FSORIG=$(mktemp -d)
git init -q --bare "$FSORIG/origin.git"
git init -q -b main "$FSORIG/work"
git -C "$FSORIG/work" config user.email t@t; git -C "$FSORIG/work" config user.name t
printf 'x\n' >"$FSORIG/work/f.txt"; git -C "$FSORIG/work" add f.txt; git -C "$FSORIG/work" commit -qm x
git -C "$FSORIG/work" remote add origin "$FSORIG/origin.git"; git -C "$FSORIG/work" push -q origin main
git -C "$FSORIG/work" fetch -q origin; git -C "$FSORIG/work" remote set-head origin main >/dev/null 2>&1
( . "$SYNC_LIB"
  assert_lib "ok|inferred|origin" \
    "$(sync_resolve_integration_ref "$FSORIG/work" 0 | cut -f1,2,3 | tr '\t' '|')" \
    "no upstream remote → infers origin/<default> (non-fork path intact)"
)
rm -rf "$FSORIG"

# ── Gate integration ──
SYNC_SETTINGS_DIR=$(mktemp -d)
printf '{"intellisense":{"gate_mode":"pilot","sync_enforcement":"warn"}}\n'     >"$SYNC_SETTINGS_DIR/warn.json"
printf '{"intellisense":{"gate_mode":"pilot","sync_enforcement":"enforced"}}\n' >"$SYNC_SETTINGS_DIR/enf.json"

# F-warn: warn + inferred + behind=1 → allow (exit 0), marker warned_behind, stderr names behind.
FSW=$(mktemp -d); setup_behind_repo "$FSW" 1
run_gate_fresh "$(payload Edit '{"file_path":"'"$FSW"'/work/seed.txt"}' FS1 "$FSW/work")" "$SYNC_SETTINGS_DIR/warn.json"
assert_exit 0 "freshness warn+behind allows the edit"
assert_contains "behind" "$LAST_STDERR" "warn behind emits stderr advisory"
assert_contains "warned_behind" "$(cat "$FSW/work/.intellisense/session/FS1.sync-freshness-checked" 2>/dev/null)" "marker tagged warned_behind"
rm -rf "$FSW"

# F-block: enforced + explicit manifest + behind=1 → BLOCK (exit 2), no marker.
FSB=$(mktemp -d); setup_behind_repo "$FSB" 1
printf '{"integration_ref":"upstream/main"}\n' >"$FSB/work/.intellisense/manifest.json"
run_gate_fresh "$(payload Edit '{"file_path":"'"$FSB"'/work/seed.txt"}' FS1 "$FSB/work")" "$SYNC_SETTINGS_DIR/enf.json"
assert_exit 2 "freshness enforced+explicit+behind blocks (exit 2)"
[ ! -f "$FSB/work/.intellisense/session/FS1.sync-freshness-checked" ] && { echo "  ✓ no marker on block (retry re-checks)"; PASS=$((PASS+1)); } || { echo "  ✗ marker written on block"; FAIL=$((FAIL+1)); }
rm -rf "$FSB"

# F-configblock: enforced + malformed explicit manifest → CONFIG ERROR block (I7).
FSC=$(mktemp -d); setup_behind_repo "$FSC" 1
printf '{"integration_ref":"upstream/x@{0}"}\n' >"$FSC/work/.intellisense/manifest.json"
run_gate_fresh "$(payload Edit '{"file_path":"'"$FSC"'/work/seed.txt"}' FS1 "$FSC/work")" "$SYNC_SETTINGS_DIR/enf.json"
assert_exit 2 "freshness enforced+config_error blocks (exit 2)"
# die_block emits the reason in the stdout JSON (permissionDecisionReason).
assert_contains "CONFIG error" "$LAST_STDOUT" "config-error message distinguishes from infra"
rm -rf "$FSC"

# F-configwarn: warn + malformed explicit manifest → warn+allow (I7).
FSCW=$(mktemp -d); setup_behind_repo "$FSCW" 1
printf '{"integration_ref":"upstream/x@{0}"}\n' >"$FSCW/work/.intellisense/manifest.json"
run_gate_fresh "$(payload Edit '{"file_path":"'"$FSCW"'/work/seed.txt"}' FS1 "$FSCW/work")" "$SYNC_SETTINGS_DIR/warn.json"
assert_exit 0 "freshness warn+config_error allows"
assert_contains "invalid" "$LAST_STDERR" "config-error warning surfaced"
rm -rf "$FSCW"

# F-fresh: behind=0 → marker fresh, allow.
FSF=$(mktemp -d); setup_behind_repo "$FSF" 0
run_gate_fresh "$(payload Edit '{"file_path":"'"$FSF"'/work/seed.txt"}' FS1 "$FSF/work")" "$SYNC_SETTINGS_DIR/enf.json"
assert_exit 0 "freshness behind=0 allows even in enforced"
assert_contains "fresh" "$(cat "$FSF/work/.intellisense/session/FS1.sync-freshness-checked" 2>/dev/null)" "marker tagged fresh"
rm -rf "$FSF"

# F-bash: Bash tool must NOT trigger freshness (structured-edit-only, G1).
FSBASH=$(mktemp -d); setup_behind_repo "$FSBASH" 1
printf '{"integration_ref":"upstream/main"}\n' >"$FSBASH/work/.intellisense/manifest.json"
run_gate_fresh "$(payload Bash '{"command":"echo hi"}' FS1 "$FSBASH/work")" "$SYNC_SETTINGS_DIR/enf.json"
assert_exit 0 "Bash tool does not trigger freshness block"
[ ! -f "$FSBASH/work/.intellisense/session/FS1.sync-freshness-checked" ] && { echo "  ✓ no freshness marker for Bash tool"; PASS=$((PASS+1)); } || { echo "  ✗ freshness ran for Bash"; FAIL=$((FAIL+1)); }
rm -rf "$FSBASH"

# F-session-skip: edits to .intellisense/session/** never trigger freshness (G4 superset).
FSS=$(mktemp -d); setup_behind_repo "$FSS" 1
printf '{"integration_ref":"upstream/main"}\n' >"$FSS/work/.intellisense/manifest.json"
run_gate_fresh "$(payload Write '{"file_path":".intellisense/contracts/FS1.md"}' FS1 "$FSS/work")" "$SYNC_SETTINGS_DIR/enf.json"
assert_exit 0 ".intellisense/session/** write skips freshness (allowlist + G4)"
rm -rf "$FSS"

rm -rf "$SYNC_SETTINGS_DIR"

# ══════════════════════════════════════════════════════════════════════════════
# Bash parser must not mis-extract FD redirects / arrows / comments.
# In each case the spurious fragment is the ONLY out-of-scope token, so a
# false-positive => block (exit 2) and a correct parser => allow (exit 0).
# Negative cases prove real mutations still block (no over-stripping).
# ══════════════════════════════════════════════════════════════════════════════
echo "parser precision (redirects / arrows / comments)"

write_nu5_contract() {  # <fixture> <branch>
    local d="$1" sb="${2//\//__}"
    mkdir -p "$(dirname "$d/.intellisense/contracts/${sb}.md")"; { echo ---; cat <<'EOF'
{"branch":"feat/test","mode":"bug_fix","requirement":"nu5","files_affected":["realfile.txt","realdir"],"estimated_lines":10,"confidence_score":0.9,"risk_level":"low","financial_impact":false,"high_risk_files_touched":[],"protected_files_touched":[],"rollback_strategy":"x","test_strategy":"x","session_id":"nu5sid","prompt_hash":"deadbeef","classification_id":"cls_test_deadbeef","state":"approved"}
EOF
echo ---; } >"$d/.intellisense/contracts/${sb}.md"
}

nu5_run() {  # <label> <command> <expected_exit>
    local fx settings
    fx=$(mktemp -d); settings=$(setup_fixture "$fx" pilot)
    write_classification "$fx" nu5sid 1
    write_nu5_contract "$fx" "feat/test"
    run_gate "$(payload Bash "$(jq -n --arg c "$2" '{command:$c}')" nu5sid "$fx")" "$settings"
    assert_exit "$3" "$1"
    rm -rf "$fx"
}

# RED — these false-positive today; must ALLOW after the fix (realfile.txt/realdir in scope).
nu5_run "FD redirect '2>/dev/null' not captured as a path"   'rm realfile.txt 2>/dev/null'          0
nu5_run "FD dup '2>&1' not captured as a path"               'rm realfile.txt 2>&1'                 0
nu5_run "stdout+stderr redirect to /dev/null exempt"         'rm realfile.txt >/dev/null 2>&1'      0
nu5_run "trailing '# comment' is stripped"                   'mkdir realdir # clean up later'       0
nu5_run "arrow '->' inside a trailing comment is not a path" 'mkdir realdir # step1 -> step2'       0

# NEGATIVE — must STILL block (guards against over-stripping).
nu5_run "real redirect to out-of-scope file still blocks"    'echo x > /home/user/secret.txt'       2
nu5_run "sed -i multi-file: out-of-scope file still blocks"  'sed -i s/a/b/ realfile.txt other.txt' 2
nu5_run "rm of an out-of-scope file still blocks"            'rm /home/user/other.txt'              2

# ─── Test 51: jq missing → fail CLOSED (audit-chain), warn-mode break-glass ──
# Allowing when jq is missing would silently disable ALL gate enforcement on a
# degraded install, so the gate treats missing jq as an audit-chain integrity failure: block with a
# remediation message; audit_chain_enforcement=warn remains the audited
# break-glass. INTELLISENSE_TEST_SIMULATE_NO_JQ=1 forces the no-jq path without
# mutating PATH — it can only make the gate stricter, never weaker.
echo "Test 51a: jq missing + default audit-chain (enforced) → BLOCK with remediation"
FIX51=$(mktemp -d)
SETTINGS51=$(write_settings_with_audit_chain "$FIX51" pilot enforced)
export INTELLISENSE_TEST_SIMULATE_NO_JQ=1
run_gate "$(payload Edit "$(jq -n '{file_path:"x.go"}')" jq51 "$FIX51")" "$SETTINGS51"
unset INTELLISENSE_TEST_SIMULATE_NO_JQ
assert_exit 2 "jq missing + enforced audit chain → block"
assert_contains "jq not on PATH" "$LAST_STDOUT" "block reason names the missing dependency"
rm -rf "$FIX51"

echo "Test 51b: jq missing + audit_chain_enforcement=warn (break-glass) → ALLOW + loud warn"
FIX51B=$(mktemp -d)
SETTINGS51B=$(write_settings_with_audit_chain "$FIX51B" pilot warn)
export INTELLISENSE_TEST_SIMULATE_NO_JQ=1
run_gate "$(payload Edit "$(jq -n '{file_path:"x.go"}')" jq51b "$FIX51B")" "$SETTINGS51B"
unset INTELLISENSE_TEST_SIMULATE_NO_JQ
assert_exit 0 "jq missing + warn break-glass → allow"
assert_contains "audit-chain warn" "$LAST_STDERR" "stderr carries the audit-chain warn banner"
rm -rf "$FIX51B"

# 51c exercises the REAL production path: jq genuinely
# absent from PATH, not simulated. The warn-allow promise says every
# break-glass allow is JSONL-audited — that must hold on exactly the machines
# where jq is missing, so _audit_chain_log_warn needs a jq-free writer.
echo "Test 51c: REAL no-jq (PATH stub) — break-glass warn still writes the JSONL audit row"
FIX51C=$(mktemp -d)
SETTINGS51C=$(write_settings_with_audit_chain "$FIX51C" pilot warn)
STUBBIN="$FIX51C/stubbin"
mkdir -p "$STUBBIN"
for t in bash cat grep sed date mkdir rm; do
    src=$(command -v "$t") && ln -s "$src" "$STUBBIN/$t"
done
P51C=$(payload Edit "$(jq -n '{file_path:"x.go"}')" jq51c "$FIX51C")
OUT51C=$(mktemp); ERR51C=$(mktemp)
env PATH="$STUBBIN" INTELLISENSE_SETTINGS_FILE="$SETTINGS51C" \
    INTELLISENSE_AUDIT_CHAIN_LOG_DIR="$FIX51C/audit" INTELLISENSE_SKIP_SYNC_CHECK=1 \
    bash "$GATE" <<<"$P51C" >"$OUT51C" 2>"$ERR51C"
RC51C=$?
if [ "$RC51C" -eq 0 ]; then
    echo "  ✓ real no-jq + warn break-glass → allow (exit=0)"; PASS=$((PASS + 1))
else
    echo "  ✗ expected exit 0, got $RC51C"; echo "    stderr: $(cat "$ERR51C")"; FAIL=$((FAIL + 1))
fi
ROW51C="$FIX51C/audit/audit-chain-warnings.jsonl"
if [ -f "$ROW51C" ] && grep -q "jq missing" "$ROW51C" && jq -e . "$ROW51C" >/dev/null 2>&1; then
    echo "  ✓ JSONL audit row written without jq and parses as JSON"; PASS=$((PASS + 1))
else
    echo "  ✗ audit row missing or invalid: $(cat "$ROW51C" 2>/dev/null || echo '<absent>')"; FAIL=$((FAIL + 1))
fi
rm -f "$OUT51C" "$ERR51C"; rm -rf "$FIX51C"

# ─── Test 52: git/gh false-positives ───────────────────────────
# The gate's bash parser cannot tell "mention of a mutation" from "a real file
# edit." Two confirmed false-positives blocked routine plumbing under
# audit_chain_enforcement=enforced (default):
#   (a) path-less git tree/index ops (git stash pop, git reset --hard/--mixed,
#       git apply, git clean -f) match a mutation pattern but expose NO governed
#       path -> BASH_MUTATION_NO_PATH -> block "file path could not be extracted"
#       (gate line ~1194), even with a valid contract in scope.
#   (b) gh PR/issue commands whose multi-line/heredoc BODY prose ('> after',
#       'touch up ...') leaks into path extraction -> bogus out-of-scope paths.
# These tests reproduce both with a VALID contract present (the realistic
# mid-task scenario) and assert the commands are allowed. Guard tests assert a
# real local mutation chained after an exempt git op is STILL gated.

echo "Test 52a: git stash pop @ Tier 1 enforced + valid contract → allow"
FIX52=$(mktemp -d)
SETTINGS52=$(setup_fixture "$FIX52" enforced)
write_classification "$FIX52" t52sid 1
write_valid_contract "$FIX52" "feat/test"
run_gate "$(payload Bash '{"command":"git stash pop"}' t52sid "$FIX52")" "$SETTINGS52"
assert_exit 0 "git stash pop is not a contract-scoped mutation"

echo "Test 52b: gh pr create with multi-line body → allow"
run_gate "$(payload Bash '{"command":"gh pr create --title \"Fix gate\" --body \"## Summary\n- before > after improvement\n- touch up the docs\""}' t52sid "$FIX52")" "$SETTINGS52"
assert_exit 0 "gh is a network/API command, never a local file mutation"

echo "Test 52c: other path-less git ops (reset --hard, clean -fd, apply) → allow"
run_gate "$(payload Bash '{"command":"git reset --hard HEAD~1"}' t52sid "$FIX52")" "$SETTINGS52"
assert_exit 0 "git reset --hard allowed"
run_gate "$(payload Bash '{"command":"git clean -fd"}' t52sid "$FIX52")" "$SETTINGS52"
assert_exit 0 "git clean -fd allowed"
run_gate "$(payload Bash '{"command":"git apply /tmp/patch.diff"}' t52sid "$FIX52")" "$SETTINGS52"
assert_exit 0 "git apply allowed"

echo "Test 52d: GUARD — real mutation chained after an exempt git op is STILL gated"
run_gate "$(payload Bash '{"command":"git stash pop && rm /etc/secret-config.go"}' t52sid "$FIX52")" "$SETTINGS52"
assert_exit 2 "rm of out-of-scope file still blocks in a chain"
assert_contains "not in contract.files_affected" "$LAST_STDOUT" "block reason names the real mutation target"

echo "Test 52e: GUARD — gh exemption is first-line only; a LEADING mutation before gh still blocks"
run_gate "$(payload Bash '{"command":"rm /etc/secret-config.go\ngh pr create --title \"x\""}' t52sid "$FIX52")" "$SETTINGS52"
assert_exit 2 "leading rm on line 1 is not rescued by gh on line 2"
rm -rf "$FIX52"

# ─── Results ──────────────────────────────────────────────────────────────────

echo ""
echo "─────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
