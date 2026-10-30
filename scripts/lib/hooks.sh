#!/bin/bash
# hooks.sh — Shared hooksPath resolution. Source this file; do not execute directly.
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/hooks.sh"  (from scripts/)
#        source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/hooks.sh"  (from repo root)

# Resolve the active git hooks directory for a repo, respecting core.hooksPath and worktrees.
# Returns 1 with error on stderr if path is not inside a git repo.
resolve_hooks_dir() {
  local repo_path="${1:-$(pwd)}"

  if ! git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: not inside git repo: $repo_path" >&2
    return 1
  fi

  local custom_hooks
  custom_hooks=$(git -C "$repo_path" config core.hooksPath 2>/dev/null || echo "")
  if [ -n "$custom_hooks" ]; then
    [[ "$custom_hooks" = /* ]] && echo "$custom_hooks" || echo "$repo_path/$custom_hooks"
    return 0
  fi

  local git_dir
  git_dir=$(git -C "$repo_path" rev-parse --git-dir 2>/dev/null || echo "$repo_path/.git")
  [[ "$git_dir" = /* ]] && echo "$git_dir/hooks" || echo "$repo_path/$git_dir/hooks"
}

# Resolve the full path of the pre-push hook for a repo.
resolve_pre_push_hook_path() {
  local repo_path="${1:-$(pwd)}"
  local hooks_dir
  hooks_dir=$(resolve_hooks_dir "$repo_path") || return 1
  echo "$hooks_dir/pre-push"
}

# Install a hook file safely with CRLF-normalized comparison.
# Policy: missing → create; identical (CRLF-normalized) → skip; different → write .intellisense-new.
install_hook_safe() {
  local src="$1"
  local dst="$2"
  local label="${3:-pre-push hook}"
  local force="${4:-false}"

  mkdir -p "$(dirname "$dst")"

  if [ ! -f "$dst" ]; then
    cp "$src" "$dst"
    chmod +x "$dst"
    echo "✓ $label installed"
    return 0
  fi

  if cmp -s <(tr -d '\r' < "$src") <(tr -d '\r' < "$dst"); then
    echo "✓ $label up-to-date"
    return 0
  fi

  if [ "$force" = "true" ]; then
    # Backups go to ~/.intellisense-backups/repo-hooks/ (path-encoded), not as a sibling
    # of $dst. Keeps every intellisense-created backup in one consistent place and
    # avoids surprises for any future tooling that scans repos.
    local backups_dir="${INTELLISENSE_BACKUPS_DIR:-$HOME/.intellisense-backups}/repo-hooks"
    mkdir -p "$backups_dir"
    local encoded="${dst//\//_}"
    local backup="$backups_dir/${encoded}.bak-$(date +%Y%m%d%H%M%S)"
    cp "$dst" "$backup"
    cp "$src" "$dst"
    chmod +x "$dst"
    echo "✓ $label replaced (backup: $backup)"
    return 0
  fi

  cp "$src" "${dst}.intellisense-new"
  echo "⚠️  $label differs — review ${dst##*/}.intellisense-new before merging"
}
