#!/usr/bin/env bash
# test_pre_push_graph_enforce.sh — Tests for the warn → block flip in
# hooks/pre-push's graph_warn_if_needed function.
#
# Strategy: source hooks/pre-push functions into a subshell with a mocked
# environment (fake repo, .intellisense/manifest.json, .intellisense/MANAGED, settings.json).
# Then call graph_warn_if_needed directly and check return code + output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRE_PUSH="$REPO_ROOT/hooks/pre-push"

# No stack is mandatory-supported by default (intellisense_graph_stack_support opts
# in per-organization). This suite exists to test the mandatory-stack
# enforcement path specifically, so opt Go/Python in for the whole run.
export INTELLISENSE_GRAPH_MANDATORY_STACKS="go python"
# The graph only applies when the team chose it as code intelligence.
export INTELLISENSE_CODE_INTEL=code-review-graph

PASS=0
FAIL=0

assert_exit() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  ✓ $label (exit=$actual)"
        PASS=$((PASS + 1))
    else
        echo "  ✗ $label (expected exit $expected, got $actual)"
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
        echo "    haystack: $haystack" | head -c 300
        FAIL=$((FAIL + 1))
    fi
}

# Make a fake intellisense-managed repo fixture with the given stack and optional graph status
make_fixture() {
    local stack="$1"
    local has_graph="${2:-no}"  # yes|no
    local fixture
    fixture=$(mktemp -d)
    git -C "$fixture" init -q 2>/dev/null
    mkdir -p "$fixture/.intellisense"
    touch "$fixture/.intellisense/MANAGED"
    cat >"$fixture/.intellisense/manifest.json" <<EOF
{ "stack": "$stack", "version": "test" }
EOF
    if [ "$has_graph" = "yes" ]; then
        # readiness field required, not just file existence.
        cat >"$fixture/.intellisense/graph-status.json" <<EOF
{ "built_at_utc": "2099-01-01T00:00:00Z", "stack": "$stack", "readiness": "ready" }
EOF
    fi
    # Need at least one commit so HEAD exists for staleness check
    git -C "$fixture" config user.email t@t 2>/dev/null
    git -C "$fixture" config user.name t 2>/dev/null
    echo dummy > "$fixture/.intellisense/dummy.txt"
    git -C "$fixture" add .intellisense 2>/dev/null
    git -C "$fixture" commit -q -m "init" 2>/dev/null
    echo "$fixture"
}

make_settings() {
    local mode="$1"  # warn|block|unset
    local f
    f=$(mktemp)
    if [ "$mode" = "unset" ]; then
        echo '{}' >"$f"
    else
        cat >"$f" <<EOF
{ "intellisense": { "graph_enforcement": "$mode" } }
EOF
    fi
    echo "$f"
}

# Source the pre-push functions in a subshell. We can't source pre-push
# directly because it has top-level code; instead, extract just the
# function definitions we need.
call_graph_check() {
    local repo="$1"
    local settings="$2"
    local override="${3:-}"
    # Extract from the first graph helper (`_graph_is_managed`) through to just
    # before the next major divider (TIER 1 section). Line-number based to
    # avoid awk range fragility.
    local start end body
    start=$(grep -n "^_graph_is_managed()" "$PRE_PUSH" | head -1 | cut -d: -f1)
    end=$(grep -n "^# =====" "$PRE_PUSH" | awk -F: -v s="$start" '$1 > s {print $1; exit}')
    [ -z "$start" ] || [ -z "$end" ] && { echo "FATAL: failed to locate graph fn boundaries" >&2; return 99; }
    body=$(sed -n "${start},$((end - 1))p" "$PRE_PUSH")
    (
        cd "$repo"
        eval "$body"
        INTELLISENSE_SETTINGS_FILE="$settings"
        [ -n "$override" ] && export INTELLISENSE_GRAPH_ENFORCE_OVERRIDE="$override"
        graph_warn_if_needed 2>&1
        echo "__EXIT__$?"
    )
}

# Test 1: warn mode + missing graph + mandatory stack → allow with warn message
echo "Test 1: warn mode + Go + no graph → allow"
FIX1=$(make_fixture go no)
SET1=$(make_settings warn)
OUT1=$(call_graph_check "$FIX1" "$SET1")
EXIT1=$(echo "$OUT1" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "0" "$EXIT1" "warn mode allows"
assert_contains "warn" "$OUT1" "warn message present"

# Test 2: block mode + missing graph + mandatory stack (Go) → BLOCK (exit 1)
echo "Test 2: block mode + Go + no graph → block"
FIX2=$(make_fixture go no)
SET2=$(make_settings block)
OUT2=$(call_graph_check "$FIX2" "$SET2")
EXIT2=$(echo "$OUT2" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "1" "$EXIT2" "block mode + mandatory-supported + missing graph → block"
assert_contains "BLOCKED" "$OUT2" "BLOCKED message in output"

# Test 3: block mode + Python (mandatory) + no graph → BLOCK
echo "Test 3: block mode + Python + no graph → block"
FIX3=$(make_fixture python no)
SET3=$(make_settings block)
OUT3=$(call_graph_check "$FIX3" "$SET3")
EXIT3=$(echo "$OUT3" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "1" "$EXIT3" "block mode + Python (mandatory) + missing graph → block"

# Test 4: block mode + TypeScript (candidate-supported) + no graph → ALLOW (warn only)
echo "Test 4: block mode + TypeScript (candidate) + no graph → allow (warn-only for candidate)"
FIX4=$(make_fixture typescript no)
SET4=$(make_settings block)
OUT4=$(call_graph_check "$FIX4" "$SET4")
EXIT4=$(echo "$OUT4" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "0" "$EXIT4" "candidate-supported never blocks (only mandatory)"
assert_contains "graph not ready" "$OUT4" "warn message still emitted"

# Test 5: block mode + Laravel (weak) + no graph → ALLOW (warn only)
echo "Test 5: block mode + Laravel (weak) + no graph → allow"
FIX5=$(make_fixture laravel no)
SET5=$(make_settings block)
OUT5=$(call_graph_check "$FIX5" "$SET5")
EXIT5=$(echo "$OUT5" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "0" "$EXIT5" "weak stack never blocks"

# Test 6: block mode + Go + WITH graph → allow
echo "Test 6: block mode + Go + graph present → allow"
FIX6=$(make_fixture go yes)
SET6=$(make_settings block)
OUT6=$(call_graph_check "$FIX6" "$SET6")
EXIT6=$(echo "$OUT6" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "0" "$EXIT6" "graph present → allow even in block mode"

# Test 7: ENV var override blocks → warn forces warn mode regardless of settings
echo "Test 7: settings=block but env INTELLISENSE_GRAPH_ENFORCE_OVERRIDE=warn → allow"
FIX7=$(make_fixture go no)
SET7=$(make_settings block)
OUT7=$(call_graph_check "$FIX7" "$SET7" warn)
EXIT7=$(echo "$OUT7" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "0" "$EXIT7" "env override warn → allow"

# Test 8: Settings file missing → default warn → allow
echo "Test 8: settings file missing → default warn → allow"
FIX8=$(make_fixture go no)
OUT8=$(call_graph_check "$FIX8" "/tmp/does-not-exist-$$")
EXIT8=$(echo "$OUT8" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "0" "$EXIT8" "default warn → allow"

# Test 9: Repo not intellisense-managed → silent allow regardless of mode
echo "Test 9: non-intellisense-managed repo + block mode → silent allow"
FIX9=$(mktemp -d)
git -C "$FIX9" init -q 2>/dev/null
# Intentionally NO .intellisense/MANAGED file
SET9=$(make_settings block)
OUT9=$(call_graph_check "$FIX9" "$SET9")
EXIT9=$(echo "$OUT9" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "0" "$EXIT9" "non-managed → silent allow"

# Test 10: graph-exception.json → allow even in block mode
echo "Test 10: graph-exception.json + block mode + Go + missing graph → allow"
FIX10=$(make_fixture go no)
echo '{ "reason": "test" }' > "$FIX10/.intellisense/graph-exception.json"
SET10=$(make_settings block)
OUT10=$(call_graph_check "$FIX10" "$SET10")
EXIT10=$(echo "$OUT10" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "0" "$EXIT10" "graph-exception present → allow"

# Test 11: graph file exists but readiness=failed → treated as not ready
echo "Test 11: readiness=failed treated as not-ready (block mode, mandatory)"
FIX11=$(mktemp -d)
git -C "$FIX11" init -q 2>/dev/null
mkdir -p "$FIX11/.intellisense"
touch "$FIX11/.intellisense/MANAGED"
echo '{ "stack": "go" }' > "$FIX11/.intellisense/manifest.json"
echo '{ "stack": "go", "readiness": "failed", "built_at_utc": "2099-01-01T00:00:00Z" }' > "$FIX11/.intellisense/graph-status.json"
git -C "$FIX11" config user.email t@t 2>/dev/null
git -C "$FIX11" config user.name t 2>/dev/null
echo dummy > "$FIX11/.intellisense/d.txt"
git -C "$FIX11" add .intellisense 2>/dev/null
git -C "$FIX11" commit -q -m init 2>/dev/null
SET11=$(make_settings block)
OUT11=$(call_graph_check "$FIX11" "$SET11")
EXIT11=$(echo "$OUT11" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "1" "$EXIT11" "readiness=failed → block in block mode (file exists but not ready)"
assert_contains "readiness=failed" "$OUT11" "error message names the failed readiness state"

# Test 12: graph file exists but missing readiness field → not ready
echo "Test 12: missing readiness field treated as not-ready"
FIX12=$(mktemp -d)
git -C "$FIX12" init -q 2>/dev/null
mkdir -p "$FIX12/.intellisense"
touch "$FIX12/.intellisense/MANAGED"
echo '{ "stack": "go" }' > "$FIX12/.intellisense/manifest.json"
echo '{ "stack": "go", "built_at_utc": "2099-01-01T00:00:00Z" }' > "$FIX12/.intellisense/graph-status.json"
git -C "$FIX12" config user.email t@t 2>/dev/null
git -C "$FIX12" config user.name t 2>/dev/null
echo dummy > "$FIX12/.intellisense/d.txt"
git -C "$FIX12" add .intellisense 2>/dev/null
git -C "$FIX12" commit -q -m init 2>/dev/null
SET12=$(make_settings block)
OUT12=$(call_graph_check "$FIX12" "$SET12")
EXIT12=$(echo "$OUT12" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "1" "$EXIT12" "missing readiness field → block (treated as unknown)"

# Test 13: readiness=ready passes (positive case)
echo "Test 13: readiness=ready allows the push"
FIX13=$(mktemp -d)
git -C "$FIX13" init -q 2>/dev/null
mkdir -p "$FIX13/.intellisense"
touch "$FIX13/.intellisense/MANAGED"
echo '{ "stack": "go" }' > "$FIX13/.intellisense/manifest.json"
echo '{ "stack": "go", "readiness": "ready", "built_at_utc": "2099-01-01T00:00:00Z" }' > "$FIX13/.intellisense/graph-status.json"
git -C "$FIX13" config user.email t@t 2>/dev/null
git -C "$FIX13" config user.name t 2>/dev/null
echo dummy > "$FIX13/.intellisense/d.txt"
git -C "$FIX13" add .intellisense 2>/dev/null
git -C "$FIX13" commit -q -m init 2>/dev/null
SET13=$(make_settings block)
OUT13=$(call_graph_check "$FIX13" "$SET13")
EXIT13=$(echo "$OUT13" | grep -oE "__EXIT__[0-9]+" | tail -1 | sed 's/__EXIT__//')
assert_exit "0" "$EXIT13" "readiness=ready → allow"

# Cleanup
for d in "$FIX1" "$FIX2" "$FIX3" "$FIX4" "$FIX5" "$FIX6" "$FIX7" "$FIX8" "$FIX9" "$FIX10" "$FIX11" "$FIX12" "$FIX13"; do
    rm -rf "$d" 2>/dev/null
done
for f in "$SET1" "$SET2" "$SET3" "$SET4" "$SET5" "$SET6" "$SET7" "$SET9" "$SET10"; do
    rm -f "$f" 2>/dev/null
done

echo ""
echo "─────────────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
echo "─────────────────────────────────────────────────"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
