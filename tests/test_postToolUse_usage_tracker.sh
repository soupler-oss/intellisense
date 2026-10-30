#!/usr/bin/env bash
# tests/test_postToolUse_usage_tracker.sh
#
# Tests for the PostToolUse usage tracker: scripts/postToolUse-usage-tracker.sh
# - Reads PostToolUse stdin payload {tool_name, tool_input, session_id, cwd}
# - On tool_name=Skill   → append tool_input.skill to skills_used (dedup)
# - On tool_name=Agent   → append tool_input.subagent_type to agents_spawned (dedup)
# - On any other tool    → no-op
# - Idempotent: same skill twice doesn't duplicate
# - Concurrent-safe: atomic file replace via mv
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TRACKER="$REPO_ROOT/scripts/postToolUse-usage-tracker.sh"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

make_workspace() {
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/.intellisense/session"
    echo "$tmp"
}

# Seed an empty usage.json so the tracker has something to append to
seed_usage_json() {
    local cwd="$1" sid="$2"
    jq -n --arg sid "$sid" --arg ts "2026-05-19T04:00:00Z" \
        '{session_id: $sid, skills_used: [], agents_spawned: [], first_prompt_ts: $ts}' \
        > "$cwd/.intellisense/session/${sid}.usage.json"
}

# Run tracker with a synthetic PostToolUse payload
run_tracker() {
    local cwd="$1" sid="$2" tool_name="$3" tool_input_json="$4"
    local payload
    payload=$(jq -n \
        --arg sid "$sid" \
        --arg cwd "$cwd" \
        --arg tn "$tool_name" \
        --argjson ti "$tool_input_json" \
        '{session_id: $sid, cwd: $cwd, tool_name: $tn, tool_input: $ti}')
    echo "$payload" | "$TRACKER" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 1: Skill invocation appends to skills_used ==="
WS=$(make_workspace); SID="sid-skill-001"
seed_usage_json "$WS" "$SID"
run_tracker "$WS" "$SID" "Skill" '{"skill":"plan"}'

skills=$(jq -r '.skills_used | join(",")' "$WS/.intellisense/session/$SID.usage.json")
[[ "$skills" == "plan" ]] && pass "Skill 'plan' appended" || fail "expected 'plan', got '$skills'"
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 2: Agent invocation appends to agents_spawned ==="
WS=$(make_workspace); SID="sid-agent-002"
seed_usage_json "$WS" "$SID"
run_tracker "$WS" "$SID" "Agent" '{"subagent_type":"Explore","description":"test"}'

agents=$(jq -r '.agents_spawned | join(",")' "$WS/.intellisense/session/$SID.usage.json")
[[ "$agents" == "Explore" ]] && pass "Agent 'Explore' appended" || fail "expected 'Explore', got '$agents'"
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 3: Duplicate Skill is deduplicated ==="
WS=$(make_workspace); SID="sid-dedup-003"
seed_usage_json "$WS" "$SID"
run_tracker "$WS" "$SID" "Skill" '{"skill":"tdd"}'
run_tracker "$WS" "$SID" "Skill" '{"skill":"tdd"}'
run_tracker "$WS" "$SID" "Skill" '{"skill":"tdd"}'

count=$(jq -r '.skills_used | length' "$WS/.intellisense/session/$SID.usage.json")
[[ "$count" == "1" ]] && pass "duplicate 'tdd' deduped to 1 entry" || fail "expected 1, got $count"
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 4: Multiple different skills accumulate in order ==="
WS=$(make_workspace); SID="sid-multi-004"
seed_usage_json "$WS" "$SID"
run_tracker "$WS" "$SID" "Skill" '{"skill":"plan"}'
run_tracker "$WS" "$SID" "Skill" '{"skill":"tdd"}'
run_tracker "$WS" "$SID" "Skill" '{"skill":"code-review"}'

skills=$(jq -r '.skills_used | join(",")' "$WS/.intellisense/session/$SID.usage.json")
[[ "$skills" == "plan,tdd,code-review" ]] && pass "3 skills accumulated in order" || fail "expected 'plan,tdd,code-review', got '$skills'"
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 5: Skill and Agent payloads coexist ==="
WS=$(make_workspace); SID="sid-mix-005"
seed_usage_json "$WS" "$SID"
run_tracker "$WS" "$SID" "Skill" '{"skill":"plan"}'
run_tracker "$WS" "$SID" "Agent" '{"subagent_type":"Plan"}'
run_tracker "$WS" "$SID" "Skill" '{"skill":"tdd"}'
run_tracker "$WS" "$SID" "Agent" '{"subagent_type":"Explore"}'

skills=$(jq -r '.skills_used | join(",")' "$WS/.intellisense/session/$SID.usage.json")
agents=$(jq -r '.agents_spawned | join(",")' "$WS/.intellisense/session/$SID.usage.json")
[[ "$skills" == "plan,tdd" ]] && pass "skills accumulated correctly with agents interleaved" || fail "skills: expected 'plan,tdd', got '$skills'"
[[ "$agents" == "Plan,Explore" ]] && pass "agents accumulated correctly with skills interleaved" || fail "agents: expected 'Plan,Explore', got '$agents'"
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 6: Non-Skill/non-Agent tool is a no-op ==="
WS=$(make_workspace); SID="sid-noop-006"
seed_usage_json "$WS" "$SID"
run_tracker "$WS" "$SID" "Edit" '{"file_path":"/tmp/x","old_string":"a","new_string":"b"}'
run_tracker "$WS" "$SID" "Bash" '{"command":"ls"}'

count_s=$(jq -r '.skills_used | length' "$WS/.intellisense/session/$SID.usage.json")
count_a=$(jq -r '.agents_spawned | length' "$WS/.intellisense/session/$SID.usage.json")
[[ "$count_s" == "0" && "$count_a" == "0" ]] && pass "Edit and Bash were no-ops" || fail "non-Skill/Agent tools modified state (skills=$count_s, agents=$count_a)"
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 7: Missing usage.json is created on demand ==="
# Real scenario: the PostToolUse usage tracker fires before the classifier's session init's first prompt completes (unlikely but possible)
WS=$(make_workspace); SID="sid-cold-007"
# NO seed — usage.json does not exist yet
run_tracker "$WS" "$SID" "Skill" '{"skill":"diagnose"}'

UFILE="$WS/.intellisense/session/$SID.usage.json"
if [[ -f "$UFILE" ]]; then
    skills=$(jq -r '.skills_used | join(",")' "$UFILE")
    [[ "$skills" == "diagnose" ]] && pass "missing usage.json was created and populated" || fail "created but missing skill: '$skills'"
else
    fail "tracker did not create usage.json when missing"
fi
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== Case 8: Empty/missing session_id is a no-op (defensive) ==="
WS=$(make_workspace)
# Build a payload with empty session_id
payload='{"session_id":"","cwd":"'$WS'","tool_name":"Skill","tool_input":{"skill":"plan"}}'
echo "$payload" | "$TRACKER" 2>/dev/null || true

# No file should have been created
count=$(find "$WS/.intellisense/session" -name "*.usage.json" 2>/dev/null | wc -l | tr -d ' ')
[[ "$count" == "0" ]] && pass "empty session_id was a no-op" || fail "tracker created files despite missing session_id ($count files)"
rm -rf "$WS"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
