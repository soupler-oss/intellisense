#!/usr/bin/env bash
# tests/test_classifier_session_init.sh
#
# Tests for the classifier's session init (userPromptSubmit-classifier.sh additions):
# - Writes .intellisense/session/current-session-id with the active session uuid
# - Initializes .intellisense/session/<session_id>.usage.json with the canonical shape
#

set -euo pipefail

# Locate the script under test (relative to this test file)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLASSIFIER="$REPO_ROOT/scripts/userPromptSubmit-classifier.sh"

# Test scaffolding
PASS=0
FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# Build an isolated temp workspace per case
make_workspace() {
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/.intellisense/session"
    echo "$tmp"
}

# Run the classifier with a synthetic stdin payload, return the workspace path
# Args: $1 session_id  $2 prompt  $3 cwd (workspace)
run_classifier() {
    local sid="$1" prompt="$2" cwd="$3"
    local payload
    payload=$(jq -n --arg p "$prompt" --arg s "$sid" --arg c "$cwd" \
        '{prompt: $p, session_id: $s, cwd: $c}')
    # Classifier exits 0 for normal flow; suppress its stdout (which is hook context)
    echo "$payload" | "$CLASSIFIER" >/dev/null 2>&1 || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Case 1: First prompt in a fresh workspace writes current-session-id
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 1: current-session-id is written on first prompt ==="
WS=$(make_workspace)
run_classifier "sid-case1-abc123" "test prompt: fix the account bug" "$WS"

if [[ -f "$WS/.intellisense/session/current-session-id" ]]; then
    val=$(cat "$WS/.intellisense/session/current-session-id")
    if [[ "$val" == "sid-case1-abc123" ]]; then
        pass "current-session-id contains the active session uuid"
    else
        fail "current-session-id contents wrong: expected 'sid-case1-abc123', got '$val'"
    fi
else
    fail "current-session-id file was not created"
fi
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
# Case 2: First prompt initializes usage.json with canonical shape
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 2: usage.json is initialized with canonical shape ==="
WS=$(make_workspace)
run_classifier "sid-case2-def456" "test prompt: add a feature" "$WS"

UFILE="$WS/.intellisense/session/sid-case2-def456.usage.json"
if [[ -f "$UFILE" ]]; then
    pass "usage.json was created"

    # Validate shape
    sid=$(jq -r '.session_id // empty' "$UFILE")
    skills=$(jq -r '.skills_used | length' "$UFILE" 2>/dev/null || echo "BAD")
    agents=$(jq -r '.agents_spawned | length' "$UFILE" 2>/dev/null || echo "BAD")
    ts=$(jq -r '.first_prompt_ts // empty' "$UFILE")

    [[ "$sid" == "sid-case2-def456" ]] && pass "usage.json.session_id correct" || fail "usage.json.session_id wrong: '$sid'"
    [[ "$skills" == "0" ]] && pass "usage.json.skills_used is empty array" || fail "skills_used not an empty array (got: $skills)"
    [[ "$agents" == "0" ]] && pass "usage.json.agents_spawned is empty array" || fail "agents_spawned not an empty array (got: $agents)"
    [[ -n "$ts" ]] && pass "usage.json.first_prompt_ts is non-empty (got: $ts)" || fail "first_prompt_ts is empty"
else
    fail "usage.json was not created"
fi
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
# Case 3: Second prompt in same session does NOT overwrite usage.json
# (preserves any skills/agents that the PostToolUse usage tracker may have appended)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 3: subsequent prompts preserve existing usage.json ==="
WS=$(make_workspace)
run_classifier "sid-case3-ghi789" "first prompt" "$WS"

# Simulate the PostToolUse usage tracker appending a skill (e.g. dev used /plan)
UFILE="$WS/.intellisense/session/sid-case3-ghi789.usage.json"
jq '.skills_used = ["plan"]' "$UFILE" > "$UFILE.tmp" && mv "$UFILE.tmp" "$UFILE"

# Run a second prompt with the same session_id
run_classifier "sid-case3-ghi789" "second prompt" "$WS"

# Verify the skill we added is still there
skills_after=$(jq -r '.skills_used | join(",")' "$UFILE")
if [[ "$skills_after" == "plan" ]]; then
    pass "usage.json preserved skills_used across second prompt"
else
    fail "usage.json was overwritten on second prompt (skills_used: '$skills_after')"
fi
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
# Case 4: current-session-id is updated when a NEW session starts in same cwd
# (covers the case where a dev opens a second Claude Code window)
# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 4: current-session-id reflects the latest active session ==="
WS=$(make_workspace)
run_classifier "sid-old-aaa" "old session prompt" "$WS"
run_classifier "sid-new-bbb" "new session prompt" "$WS"

current=$(cat "$WS/.intellisense/session/current-session-id")
if [[ "$current" == "sid-new-bbb" ]]; then
    pass "current-session-id was updated to the newest session"
else
    fail "current-session-id stuck on old session (got: '$current')"
fi
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
