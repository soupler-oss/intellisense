#!/bin/bash
# Check Go stack requirements

function check_stack_go() {
  local repo_path="$1"

  # Check for go.mod
  if [ ! -f "$repo_path/go.mod" ]; then
    echo "⚠️  WARN: go.mod not found (expected in Go repo)"
    return 0
  fi

  # Info: check for expected Go directories (advisory only)
  local has_dirs=0
  for dir in handlers services models repositories; do
    if [ -d "$repo_path/$dir" ]; then
      ((has_dirs++))
    fi
  done

  if [ $has_dirs -eq 0 ]; then
    echo "ℹ️  INFO: No standard Go directories found (handlers/, services/, models/, repositories/)"
  fi

  return 0
}

export -f check_stack_go
