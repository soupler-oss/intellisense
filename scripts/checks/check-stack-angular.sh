#!/bin/bash
# Check Angular stack requirements

function check_stack_angular() {
  local repo_path="$1"

  # Check for package.json
  if [ ! -f "$repo_path/package.json" ]; then
    echo "⚠️  WARN: package.json not found (expected in Node repo)"
    return 0
  fi

  # Check for angular.json
  if [ ! -f "$repo_path/angular.json" ]; then
    echo "⚠️  WARN: angular.json not found (expected in Angular app)"
    return 0
  fi

  return 0
}

export -f check_stack_angular
