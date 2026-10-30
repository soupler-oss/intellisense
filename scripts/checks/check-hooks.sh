#!/bin/bash
# Check git hooks installation (only if hooks in components)

# Source shared hooks resolution library
source "$(dirname "${BASH_SOURCE[0]}")/../lib/hooks.sh"

function check_hooks() {
  local repo_path="$1"

  # Resolve hook path respecting core.hooksPath and worktrees
  local hook_path
  hook_path=$(resolve_pre_push_hook_path "$repo_path" 2>/dev/null) || true

  if [ -z "$hook_path" ]; then
    echo "⚠️  WARN: Unable to resolve hooks directory"
    return 0
  fi

  # Check if pre-push hook exists at resolved path
  if [ ! -f "$hook_path" ]; then
    echo "⚠️  WARN: pre-push hook not found at $hook_path"
    return 0
  fi

  # Check if hook is executable
  if [ ! -x "$hook_path" ]; then
    echo "⚠️  WARN: pre-push hook exists but is not executable"
    return 0
  fi

  return 0
}

export -f check_hooks
