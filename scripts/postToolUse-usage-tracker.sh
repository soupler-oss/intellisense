#!/usr/bin/env bash
# scripts/postToolUse-usage-tracker.sh
#
# the PostToolUse usage tracker — PostToolUse hook for Skill + Agent capture.
# Registered in .claude/settings.json with matcher "Skill|Agent".
#
# On each fire:
#   - tool_name == "Skill" → append tool_input.skill to skills_used[]
#   - tool_name == "Agent" → append tool_input.subagent_type to agents_spawned[]
#   - any other tool       → no-op (defensive; shouldn't match per the regex)
#
# Both writes are deduped (set semantics) and atomic (tmp + mv).
#
# Stdin payload (JSON):
#   { session_id, cwd, tool_name, tool_input, ... }
#
# Output to .intellisense/session/<session_id>.usage.json:
#   { session_id, skills_used: [...], agents_spawned: [...], first_prompt_ts: <iso> }
#

set -uo pipefail

# Read stdin payload; exit silently on empty (hook may fire with no body)
PAYLOAD=$(cat 2>/dev/null || true)
[ -z "$PAYLOAD" ] && exit 0

# Defensive: jq must be present (every intellisense dev machine has it)
command -v jq >/dev/null 2>&1 || exit 0

SESSION_ID=$(jq -r '.session_id // empty' <<<"$PAYLOAD" 2>/dev/null)
CWD=$(jq -r '.cwd // empty' <<<"$PAYLOAD" 2>/dev/null)
TOOL_NAME=$(jq -r '.tool_name // empty' <<<"$PAYLOAD" 2>/dev/null)

# All three must be present, else we have no anchor and skip
[ -z "$SESSION_ID" ] && exit 0
[ -z "$CWD" ] && exit 0
[ -z "$TOOL_NAME" ] && exit 0

# Only Skill and Agent are interesting
case "$TOOL_NAME" in
    Skill|Agent) ;;
    *) exit 0 ;;
esac

INTELLISENSE_SESSION_DIR="$CWD/.intellisense/session"
USAGE_FILE="$INTELLISENSE_SESSION_DIR/${SESSION_ID}.usage.json"

# Resolve the value to append, per tool type
if [ "$TOOL_NAME" = "Skill" ]; then
    FIELD="skills_used"
    VAL=$(jq -r '.tool_input.skill // empty' <<<"$PAYLOAD" 2>/dev/null)
else
    FIELD="agents_spawned"
    # Default subagent_type to "general-purpose" when omitted (matches the Agent
    # tool's documented default behavior)
    VAL=$(jq -r '.tool_input.subagent_type // "general-purpose"' <<<"$PAYLOAD" 2>/dev/null)
fi

# Nothing to do if no value parsed
[ -z "$VAL" ] && exit 0

mkdir -p "$INTELLISENSE_SESSION_DIR" 2>/dev/null || exit 0

# If usage.json doesn't exist yet (the PostToolUse usage tracker firing before the classifier's session init had a chance), seed it.
# This shouldn't normally happen but the hook order isn't strictly guaranteed.
if [ ! -f "$USAGE_FILE" ]; then
    jq -n --arg sid "$SESSION_ID" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{session_id: $sid, skills_used: [], agents_spawned: [], first_prompt_ts: $ts}' \
        > "$USAGE_FILE.tmp" 2>/dev/null \
        && mv "$USAGE_FILE.tmp" "$USAGE_FILE" || exit 0
fi

# Atomic append-with-dedup: read → modify → write tmp → mv
# Using set semantics via `if (.<field> | index($v)) then . else (.<field> += [$v]) end`
jq --arg v "$VAL" --arg f "$FIELD" \
    'if (.[$f] // [] | index($v)) then . else .[$f] = ((.[$f] // []) + [$v]) end' \
    "$USAGE_FILE" > "$USAGE_FILE.tmp" 2>/dev/null \
    && mv "$USAGE_FILE.tmp" "$USAGE_FILE" || true

exit 0
