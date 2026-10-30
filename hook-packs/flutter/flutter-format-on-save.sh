#!/bin/bash
# hook-packs/flutter/flutter-format-on-save.sh
# PostToolUse hook — auto-format a Dart file immediately after Edit/Write.
#
# Unlike flutter-format-changed.sh (pre-commit, reads `git diff --cached`),
# this runs per-file right after Claude edits it, so the formatted result is
# what Claude sees on the next read. Mirrors the format-on-save pattern used
# by claude-code-kit and per-repo Flutter setups.
#
# Wire it via .claude/settings.json (see infrastructure/hooks-template.json):
#   "PostToolUse": [{ "matcher": "Edit|Write",
#     "hooks": [{ "type": "command",
#       "command": "~/.claude/hooks/flutter-format-on-save.sh" }] }]
#
# Install with:
#   cp hook-packs/flutter/flutter-format-on-save.sh ~/.claude/hooks/flutter-format-on-save.sh
#   chmod +x ~/.claude/hooks/flutter-format-on-save.sh

set -euo pipefail

# PostToolUse passes tool context as JSON on stdin: {"tool_input":{"file_path":"..."}}
payload="$(cat)"

file_path=""
if command -v jq >/dev/null 2>&1; then
  file_path="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
else
  # jq-less fallback: grep the first "file_path" string value
  file_path="$(printf '%s' "$payload" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed -E 's/.*"([^"]*)"$/\1/' || true)"
fi

# Nothing to do if we couldn't resolve a path, it's gone, or it's not Dart
[[ -z "$file_path" ]] && exit 0
[[ ! -f "$file_path" ]] && exit 0
[[ "$file_path" != *.dart ]] && exit 0

# Skip generated files — formatting them is churn and they're regenerated anyway
case "$file_path" in
  *.g.dart|*.freezed.dart|*.gr.dart|*.config.dart|*.chopper.dart|*.mocks.dart)
    exit 0 ;;
esac

# Skip silently when the Dart toolchain isn't installed
command -v dart >/dev/null 2>&1 || exit 0

dart format "$file_path" >/dev/null 2>&1 || true
