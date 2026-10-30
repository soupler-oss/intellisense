#!/bin/bash
# intellisense-paths.sh — Per-repo intellisense metadata path resolution. Source this file; do not
# execute directly.
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib/intellisense-paths.sh"  (from scripts/)
#        source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/intellisense-paths.sh"  (from repo root)
#
# Per-repo intellisense metadata lives under <repo>/.intellisense/. This module
# exposes path resolution split into PURE and SIDE-EFFECT halves:
#   - intellisense_state_dir / intellisense_state_path are pure. They never create directories.
#   - ensure_intellisense_state_dir creates <repo>/.intellisense when called.
# Discipline: any function that mkdir's MUST have ensure_ in its name. Readers
# never accidentally create .intellisense/ in a repo that has none.

# Map a key to its filename under .intellisense/.
# Keys: version, manifest, local, stubs-status, kb-status, existing-knowledge-report
_intellisense_state_filename() {
  case "$1" in
    version)                   echo "version" ;;
    manifest)                  echo "manifest.json" ;;
    local)                     echo "local.json" ;;
    stubs-status)              echo "stubs-status.json" ;;
    kb-status)                 echo "kb-status.md" ;;
    existing-knowledge-report) echo "existing-knowledge-report.md" ;;
    *)
      echo "ERROR: unknown intellisense state key: $1" >&2
      return 1
      ;;
  esac
}

# Pure: echo <repo>/.intellisense with no I/O.
intellisense_state_dir() {
  local repo="${1:-$(pwd)}"
  echo "$repo/.intellisense"
}

# Side-effect: ensure <repo>/.intellisense exists. Call from writers only.
ensure_intellisense_state_dir() {
  local repo="${1:-$(pwd)}"
  local dir
  dir=$(intellisense_state_dir "$repo") || return 1
  mkdir -p "$dir"
}

# Pure: canonical write path for a key, e.g. <repo>/.intellisense/version.
# Writers must call ensure_intellisense_state_dir before writing.
intellisense_state_path() {
  local repo="$1" key="$2"
  local file
  file=$(_intellisense_state_filename "$key") || return 1
  echo "$(intellisense_state_dir "$repo")/$file"
}

# ============================================================================
# PATH normalization for intellisense tooling discovery.
#
# code-review-graph and bd are commonly installed under ~/.local/bin (pipx /
# pip --user / uv tool) or /opt/homebrew/bin (Homebrew on Apple Silicon). A
# user's interactive shell PATH may include those, but a child process spawned
# by a wrapper or a subshell may not inherit them. This causes tools to be
# silently invisible to graph-bootstrap.sh / setup-repos.sh / setup.sh even
# though they are correctly installed.
#
# _ensure_local_bin_on_path is tool-agnostic: it just ensures the two common
# install dirs are on $PATH if they exist. It does NOT name specific binaries.
# Tool-specific resolution (`command -v code-review-graph` etc.) stays in the
# consuming scripts.
#
# Discipline: prepend missing entries (so they shadow nothing the user already
# has). Idempotent: a second call is a no-op. Safe to source from any setup
# script before any tool-existence check.
# ============================================================================

_ensure_local_bin_on_path() {
  local candidate
  for candidate in \
    "$HOME/.local/bin" \
    /opt/homebrew/bin \
    /usr/local/bin \
    /home/linuxbrew/.linuxbrew/bin
  do
    [ -d "$candidate" ] || continue
    case ":$PATH:" in
      *":$candidate:"*) ;;  # already present
      *) PATH="$candidate:$PATH" ;;
    esac
  done
  export PATH
}
