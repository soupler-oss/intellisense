#!/usr/bin/env bash
# UserPromptSubmit hook: inject TDD reminder when the prompt is in TDD context.
#
# WHY: SKILL.md content gets pushed out of context in long sessions. File-based
# rules decay; injected reminders don't. This hook keeps the 5 most critical
# TDD rules salient when the model is actually doing TDD work.
#
# SCOPING (must satisfy ALL):
#   1. cwd is inside a git work tree (signals dev work, not /tmp / read-only)
#   2. AT LEAST ONE of:
#      a) `.intellisense/session/tdd-mode` marker file exists in repo root (explicit opt-in
#         for the session — touch it when starting TDD, rm when done)
#      b) Submitted prompt contains TDD-indicator keywords (heuristic match
#         on the JSON payload Claude Code passes via stdin: /tdd, RED, GREEN,
#         "test first", "failing test", TDD)
#
# IMPORTANT — what this hook is NOT:
#   - This is a REMINDER, not enforcement. The model can still violate the
#     rules. Real enforcement requires a PreToolUse hook on Edit/Write
#     (deferred per the rollout plan).
#   - This hook does NOT fire on planning, review, refactor, hotfix, or
#     read-only sessions unless the prompt or marker explicitly invokes TDD.
#
# OPT-OUT: export CLAUDE_TDD_HOOK_DISABLED=1
# OPT-IN (always-on for the session): touch .intellisense/session/tdd-mode in repo root
# TOKEN COST WHEN FIRED: ~55 tokens per prompt
#

set -euo pipefail

# Opt-out
if [[ "${CLAUDE_TDD_HOOK_DISABLED:-}" == "1" ]]; then
  exit 0
fi

# Skip if not in a git repo (avoids noise on /tmp, read-only sessions)
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

# Determine TDD context. Two signals:
TDD_CONTEXT=0

# Signal A: explicit marker file in repo root
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo .)"
if [[ -f "${REPO_ROOT}/.intellisense/session/tdd-mode" ]]; then
  TDD_CONTEXT=1
fi

# Signal B: prompt content (Claude Code passes prompt via stdin as JSON or
# plain text; check both forms with case-insensitive keyword match)
if [[ "$TDD_CONTEXT" -eq 0 ]] && [[ ! -t 0 ]]; then
  # stdin has data — read up to 8KB to keep this fast
  PROMPT_BLOB="$(head -c 8192 || true)"
  if echo "$PROMPT_BLOB" | grep -qiE '/tdd|test-driven|\bTDD\b|red[- ]green|failing test|red phase|green phase|test first|write.*test.*before'; then
    TDD_CONTEXT=1
  fi
fi

# Not in TDD context → silent exit
if [[ "$TDD_CONTEXT" -eq 0 ]]; then
  exit 0
fi

# Inject the reminder. stdout becomes additional prompt context for Claude.
cat <<'EOF'
[TDD REMINDER — these are reminders, not enforcement; the model can still violate them]
1. No production code without a failing test first.
2. Runtime RED only. Compile/import error is not RED. Add minimal stub, re-RED at assertion level.
3. Retry bound: 5 impl attempts max → halt and emit TDD-RETRY-EXHAUSTED diagnostic.
4. Never edit a test to match implementation. Edit test only if assertion or setup is invalid → re-RED from Step 2.
5. Bug-fix mode: 3 files max. Beyond that → escalate to full_feature or split into separate fixes.
EOF
