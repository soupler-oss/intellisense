#!/bin/bash
# Check PHP/Laravel stack requirements

function check_stack_php() {
  local repo_path="$1"

  # Check for composer.json
  if [ ! -f "$repo_path/composer.json" ]; then
    echo "⚠️  WARN: composer.json not found (expected in PHP repo)"
    return 0
  fi

  # Info: check for Laravel indicator
  if [ ! -f "$repo_path/artisan" ]; then
    echo "ℹ️  INFO: artisan not found (expected in Laravel app)"
  fi

  return 0
}

export -f check_stack_php
