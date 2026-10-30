#!/bin/bash
# Check repository intellisense initialization state

# Source per-repo intellisense metadata path resolver (.intellisense/ layout)
_check_repo_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)"
source "$_check_repo_lib_dir/intellisense-paths.sh"

function check_repo() {
  local repo_path="$1"
  local manifest_path local_path
  manifest_path=$(intellisense_state_path "$repo_path" manifest)
  local_path=$(intellisense_state_path "$repo_path" local)

  # Check if manifest exists
  if [ ! -f "$manifest_path" ]; then
    echo "❌ NOT INITIALIZED — run setup-repos.sh to install intellisense"
    return 2
  fi

  # Check if local state file exists (advisory, may be missing on fresh clone)
  if [ ! -f "$local_path" ]; then
    echo "⚠️  WARN: .intellisense/local.json missing (expected on fresh clone)"
  fi

  # Verify manifest version
  local manifest_version
  manifest_version=$(jq -r '.intellisense_manifest_version' "$manifest_path" 2>/dev/null)
  if [ "$?" -ne 0 ] || [ -z "$manifest_version" ]; then
    echo "❌ FAIL: Cannot read $manifest_path"
    return 1
  fi

  if [ "$manifest_version" != "1" ]; then
    echo "❌ FAIL: Unsupported manifest version: $manifest_version (expected 1)"
    return 1
  fi

  # Read stack and components from manifest
  local stack
  local components_raw
  stack=$(jq -r '.stack' "$manifest_path" 2>/dev/null)
  components_raw=$(jq -c '.components' "$manifest_path" 2>/dev/null)

  if [ -z "$stack" ] || [ -z "$components_raw" ]; then
    echo "❌ FAIL: $manifest_path missing required fields (stack, components)"
    return 1
  fi

  local issues=0

  # Check components
  if echo "$components_raw" | jq -e 'map(. == "claude-md") | any' >/dev/null 2>&1; then
    if [ ! -f "$repo_path/CLAUDE.md" ]; then
      echo "❌ FAIL: CLAUDE.md missing but 'claude-md' in components"
      ((issues++))
    fi
  fi

  if echo "$components_raw" | jq -e 'map(. == "knowledge-base") | any' >/dev/null 2>&1; then
    if [ ! -d "$repo_path/knowledge-base" ]; then
      echo "❌ FAIL: knowledge-base/ directory missing but 'knowledge-base' in components"
      ((issues++))
    fi
  fi

  # Beads checks apply only when the team chose Beads as its tracker (verify-setup.sh reads
  # ~/.intellisense/integrations.env into TRACKER). Other trackers need no per-repo state.
  if [ "${TRACKER:-none}" = "beads" ]; then
    # Beads .beads/ initialized (Dolt config marker)
    if [ ! -f "$repo_path/.beads/config.yaml" ]; then
      echo "❌ FAIL: .beads/ not initialized (config.yaml missing)"
      echo "    Fix: bash <INTELLISENSE_SETUP>/setup-repos.sh --repo \"$repo_path\" --stack <stack>"
      ((issues++))
    fi

    # core.hooksPath flipped to .beads/hooks AND chain present in pre-push
    local hooks_path
    hooks_path=$(cd "$repo_path" && git config --get core.hooksPath 2>/dev/null)
    if [ -z "$hooks_path" ]; then
      echo "❌ FAIL: core.hooksPath unset (expected .beads/hooks after bd init)"
      ((issues++))
    elif [ ! -f "$hooks_path/pre-push" ]; then
      echo "❌ FAIL: $hooks_path/pre-push missing"
      ((issues++))
    elif ! grep -q 'BEGIN BEADS INTEGRATION' "$hooks_path/pre-push" \
         || ! grep -q 'BEGIN intellisense INTEGRATION' "$hooks_path/pre-push"; then
      echo "❌ FAIL: pre-push at $hooks_path missing BEADS or intellisense integration block"
      echo "    Fix: bash <INTELLISENSE_SETUP>/setup-repos.sh --repo \"$repo_path\" --stack <stack>"
      ((issues++))
    fi
  fi

  return $issues
}

export -f check_repo
