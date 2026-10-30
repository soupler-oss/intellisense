#!/bin/bash
# Check intellisense version consistency between local state and setup directory

# Source per-repo intellisense metadata path resolver (.intellisense/ layout)
_check_version_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$_check_version_lib_dir/intellisense-paths.sh"

function check_version() {
  local repo_path="$1"
  local intellisense_setup_dir="$2"
  local local_path version_path
  local_path=$(intellisense_state_path "$repo_path" local)
  version_path=$(intellisense_state_path "$repo_path" version)

  # Read version from setup directory
  local setup_version=""
  if [ -f "$intellisense_setup_dir/VERSION" ]; then
    setup_version=$(cat "$intellisense_setup_dir/VERSION" | tr -d '[:space:]')
  fi

  # Read version from local state file
  local local_version=""
  if [ -f "$local_path" ]; then
    local_version=$(jq -r '.intellisense_version' "$local_path" 2>/dev/null)
  fi

  # Check for version mismatch (advisory, not blocking)
  if [ -n "$local_version" ] && [ -n "$setup_version" ] && [ "$local_version" != "$setup_version" ]; then
    echo "⚠️  WARN: Version mismatch — repo installed with $local_version, INTELLISENSE_SETUP is $setup_version"
  fi

  # Check for the version file (.intellisense/version)
  if [ ! -f "$version_path" ]; then
    echo "⚠️  WARN: intellisense version file not found (expected on older installs)"
  fi

  return 0
}

export -f check_version
