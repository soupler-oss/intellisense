#!/bin/bash

# intellisense Setup Script
# Installs intellisense Live mode into Claude Code
# Uses symlinks to maintain single source of truth

# --- source-guard -------------------------------------------------------
# This script must be EXECUTED, not sourced. With `set -e` active (below),
# sourcing would let any failure — or the `exit 1` guards later in this file —
# terminate the user's interactive shell and close their terminal. Detect
# sourcing and bail safely with `return` so the parent shell survives.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  echo "ERROR: setup.sh must be executed, not sourced." >&2
  echo "  Run:  ./setup.sh        (or)   bash setup.sh" >&2
  echo "  You used 'source'/'.' — that closes your terminal on any error." >&2
  return 1 2>/dev/null || exit 1
fi
# ------------------------------------------------------------------------

set -e  # Exit on error

# Tracking arrays for safe rollback
CREATED_SYMLINKS=()
CREATED_FILES=()
BACKED_UP_ITEMS=()

# Parse command-line arguments
DRY_RUN=false
INTERACTIVE=true
REPOS_BASE=""
SETUP_REPOS=false
SKIP_REPO_SETUP=false
CLAUDE_MD_ACTION=""
INSTALL_HOOKS=true
INSTALL_CI=true
INTELLISENSE_SETUP_OVERRIDE=""
REFRESH_GLOBAL_CLAUDE=false
# Initialized explicitly so the gate at line ~548 has a defined value on every
# code path. Today set -e (no -u) tolerates the unset case via empty-string
# expansion, but the explicit default removes the latent dependency on that.
SKIP_TO_VALIDATION=false
RESOLVE_CURSOR_MODE=""
NO_HEARTBEAT=false
ROTATE_TOKEN=false
PRINT_TOKEN_INSTRUCTIONS=false
REFRESH_RUNTIME=false
# Optional integrations. Nothing is installed for "none". Flags win over the environment; with neither, an
# interactive run asks and a non-interactive run uses "none".
TRACKER="${INTELLISENSE_TRACKER:-}"
CODE_INTEL="${INTELLISENSE_CODE_INTEL:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --non-interactive)
      INTERACTIVE=false
      shift
      ;;
    --repos-base)
      REPOS_BASE="$2"
      shift 2
      ;;
    --setup-repos)
      SETUP_REPOS=true
      shift
      ;;
    --skip-repo-setup)
      SKIP_REPO_SETUP=true
      shift
      ;;
    --claude-md-action)
      CLAUDE_MD_ACTION="$2"
      shift 2
      ;;
    --intellisense-setup)
      INTELLISENSE_SETUP_OVERRIDE="$2"
      shift 2
      ;;
    --skip-hooks)
      INSTALL_HOOKS=false
      shift
      ;;
    --skip-ci)
      INSTALL_CI=false
      shift
      ;;
    --tracker)
      # Task tracker the task trailers point at: none, beads, github, jira, linear. Only beads installs a tool (bd).
      TRACKER="$2"
      shift 2
      ;;
    --code-intel)
      # Code intelligence for Live mode: none or code-review-graph (a Python tool + MCP server).
      CODE_INTEL="$2"
      shift 2
      ;;
    --refresh-global-claude)
      REFRESH_GLOBAL_CLAUDE=true
      shift
      ;;
    --resolve-cursor)
      # recovery path for corrupted token cursors. Optional next arg
      # picks the resolution non-interactively: "trust-final" or "reset".
      # Without an arg → interactive prompt.
      RESOLVE_CURSOR_MODE="prompt"
      if [[ -n "${2:-}" && "$2" != --* ]]; then
        RESOLVE_CURSOR_MODE="$2"
        shift
      fi
      shift
      ;;
    --no-heartbeat)
      # explicit opt-out from the daily analytics heartbeat.
      # Dev will not appear on the intellisense dashboard until they re-run setup.sh
      # without this flag.
      NO_HEARTBEAT=true
      shift
      ;;
    --rotate-token)
      # re-prompt for the INTELLISENSE_HEARTBEAT_TOKEN and replace any
      # existing token file. Used when admin rotates the shared bearer token.
      ROTATE_TOKEN=true
      shift
      ;;
    --print-token-instructions)
      # Print the instructions for getting the current heartbeat token
      # from your collector's owner, and exit 0. Useful in tickets / docs.
      PRINT_TOKEN_INSTRUCTIONS=true
      shift
      ;;
    --refresh-runtime)
      # Re-copy the heartbeat runtime files into ~/.intellisense/bin/
      # without re-running the rest of setup. Used by the post-merge git
      # hook and by developers who want to pick up an upstream heartbeat
      # fix without a full setup re-run.
      REFRESH_RUNTIME=true
      shift
      ;;
    *)
      shift
      ;;
  esac
done

# ─── --refresh-runtime short-circuit ─────────────────────────────────────────
# Delegated to a standalone script so the same code path is used by the
# post-merge git hook and by `bash setup.sh --refresh-runtime`. Runs WITHOUT
# touching the launchd plist, token, or any other setup state.
if [[ "$REFRESH_RUNTIME" == true ]]; then
  _refresh_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  exec "$_refresh_script_dir/scripts/refresh-heartbeat-runtime.sh" --verbose
fi

# ─── --print-token-instructions short-circuit ─────────────────────
if [[ "$PRINT_TOKEN_INSTRUCTIONS" == true ]]; then
  cat <<'EOF'
intellisense Heartbeat — where to find your endpoint + token
=====================================================

The heartbeat reporter POSTs to your organization's own telemetry collector
— this framework ships no default. It authenticates with one shared bearer
token. Get both values from:

  Your organization's intellisense platform admin.

Install them by re-running setup.sh with both in env vars:

  INTELLISENSE_HEARTBEAT_ENDPOINT='https://...' INTELLISENSE_HEARTBEAT_TOKEN='<paste>' \
    bash setup.sh --non-interactive --yes

Or just run setup.sh interactively and paste when prompted (endpoint is
plain text, token input is hidden):

  bash setup.sh

To rotate after a token change:

  bash setup.sh --rotate-token

To opt out of the heartbeat entirely:

  bash setup.sh --no-heartbeat
EOF
  exit 0
fi

# ─── --resolve-cursor short-circuit (PR 1 / post-commit recovery path) ────────────────
# Runs BEFORE the rest of setup. Reads the active session's token-cursor.json
# in the current git repo, surfaces the corrupted_cursor entry (set by post-commit when
# the final committed message diverged from prepare-commit-msg's pending_cursor), and lets the
# dev pick how to recover:
#   trust-final  → promote corrupted_cursor → committed_cursor (accept dev's
#                  edits as authoritative). Next commit attributes only tokens
#                  newer than the corrupted entry.
#   reset        → discard corrupted_cursor entirely. Next commit re-attributes
#                  the entire window from the previous committed_cursor.
intellisense_resolve_cursor() {
  local repo_root sid cursor_file mode
  mode="$RESOLVE_CURSOR_MODE"

  # `|| true` because set -e at the top of this script would otherwise exit
  # (git rev-parse returns 128 outside a repo); we want to surface a clean
  # error message instead.
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$repo_root" ]]; then
    echo "ERROR: --resolve-cursor must be run inside a git repo (the one where the corrupted commit landed)." >&2
    return 1
  fi
  if [[ ! -f "$repo_root/.intellisense/session/current-session-id" ]]; then
    echo "ERROR: no active intellisense session in $repo_root (no .intellisense/session/current-session-id)." >&2
    return 1
  fi
  sid="$(cat "$repo_root/.intellisense/session/current-session-id")"
  cursor_file="$repo_root/.intellisense/session/${sid}.token-cursor.json"
  if [[ ! -f "$cursor_file" ]]; then
    echo "ERROR: no cursor file for session $sid in $repo_root." >&2
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required for cursor resolution." >&2
    return 1
  fi
  if ! jq -e '.corrupted_cursor' "$cursor_file" >/dev/null 2>&1; then
    echo "No corrupted_cursor present in $cursor_file — nothing to resolve."
    echo "Cursor state is healthy; intellisense commits are not blocked."
    return 0
  fi

  echo "=== Corrupted cursor detected ==="
  echo "Cursor file : $cursor_file"
  echo "Session id  : $sid"
  echo
  echo "Current state:"
  jq '{committed_cursor, corrupted_cursor}' "$cursor_file"
  echo
  echo "Why this happened: post-commit (post-commit) detected that the actual final"
  echo "commit message diverged from what prepare-commit-msg staged (likely an edit to"
  echo "Intellisense-Metadata in \$EDITOR, or a manual rebase that altered the trailer)."
  echo
  echo "Two recovery options:"
  echo "  trust-final  — promote corrupted_cursor → committed_cursor; treat the"
  echo "                  final committed message as the new attribution truth."
  echo "                  Use this if YOU intentionally edited the trailer."
  echo "  reset        — discard corrupted_cursor entirely; next commit will"
  echo "                  re-tally the entire window from the prior cursor."
  echo "                  Use this if the trailer drift was accidental and you"
  echo "                  want the next commit to re-emit the full window."

  if [[ -z "$mode" || "$mode" == "prompt" ]]; then
    if [[ "$INTERACTIVE" = false ]]; then
      echo "ERROR: non-interactive mode set but no resolution specified." >&2
      echo "       Pass --resolve-cursor trust-final  OR  --resolve-cursor reset" >&2
      return 1
    fi
    echo
    read -r -p "Choose [trust-final / reset]: " mode
  fi

  local tmp
  tmp="$(mktemp)"
  case "$mode" in
    trust-final)
      jq '.committed_cursor = {
            last_processed_id: .corrupted_cursor.last_processed_id,
            tokens_consumed_pre_cursor: .corrupted_cursor.tokens_consumed_pre_cursor
          }
          | del(.corrupted_cursor)
          | del(.pending_cursor)' "$cursor_file" > "$tmp" && mv "$tmp" "$cursor_file"
      echo "✓ corrupted_cursor promoted to committed_cursor. intellisense commits unblocked."
      ;;
    reset)
      jq 'del(.corrupted_cursor) | del(.pending_cursor)' "$cursor_file" > "$tmp" && mv "$tmp" "$cursor_file"
      echo "✓ corrupted_cursor discarded. Next commit will re-attribute the window from the prior committed_cursor."
      ;;
    *)
      rm -f "$tmp"
      echo "ERROR: unknown resolution mode: '$mode' (expected: trust-final | reset)" >&2
      return 1
      ;;
  esac
}

if [[ -n "$RESOLVE_CURSOR_MODE" ]]; then
  intellisense_resolve_cursor
  exit $?
fi

# If non-interactive mode detected by terminal, allow override
if [ ! -t 0 ] && [ "$INTERACTIVE" = true ]; then
  INTERACTIVE=false
fi

# Cleanup and safe rollback on exit (scoped rollback)
cleanup() {
  local EXIT_CODE=$?
  if [ $EXIT_CODE -ne 0 ] && [ "$DRY_RUN" = false ]; then
    echo -e "${RED}Setup failed. Rolling back changes...${NC}"

    # Restore backed-up items. Each entry is "DST|BACKUP" — DST is the original
    # path, BACKUP is the exact path the file was moved to (under
    # ~/.intellisense-backups/). We mv the backup back, removing the symlink first so
    # mv doesn't fail with "destination exists".
    for entry in "${BACKED_UP_ITEMS[@]}"; do
      local original_path="${entry%%|*}"
      local backup_path="${entry##*|}"
      if [ -e "$backup_path" ]; then
        [ -L "$original_path" ] && rm -f "$original_path"
        mv "$backup_path" "$original_path"
        echo -e "  ${YELLOW}[RESTORED]${NC} $(basename "$original_path")"
      fi
    done

    # Remove created symlinks
    for symlink in "${CREATED_SYMLINKS[@]}"; do
      if [ -L "$symlink" ]; then
        rm -f "$symlink"
        echo -e "  ${YELLOW}[REMOVED]${NC} $symlink"
      fi
    done

    # Remove created files
    for file in "${CREATED_FILES[@]}"; do
      if [ -f "$file" ] && [ ! -L "$file" ]; then
        rm -f "$file"
        echo -e "  ${YELLOW}[REMOVED]${NC} $file"
      fi
    done

    echo -e "${YELLOW}Rollback complete (scoped to this run; ~/.claude preserved).${NC}"
  fi
  return $EXIT_CODE
}
trap cleanup ERR

# Color constants
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Allow override via --intellisense-setup flag (for testing)
if [ -n "$INTELLISENSE_SETUP_OVERRIDE" ]; then
  SCRIPT_DIR="$INTELLISENSE_SETUP_OVERRIDE"
fi
CLAUDE_HOME="$HOME/.claude"
# INTELLISENSE_HOME is a global so Steps 14 / 14.5 can verify intellisense symlinks
# even when Steps 1-13 are skipped on a re-run (version-match path).
INTELLISENSE_HOME="$HOME/.intellisense"
# INTELLISENSE_BACKUPS_DIR holds every .bak-<ts> created by setup.sh / install_pre_push_hook.
# Lives outside ~/.claude/ and ~/.claude-intellisense/ so backups never end up inside
# Claude Code's auto-load path. Override via env var only — no flag.
INTELLISENSE_BACKUPS_DIR="${INTELLISENSE_BACKUPS_DIR:-$HOME/.intellisense-backups}"

# Source shared hooks resolution library
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/hooks.sh"

# Source intellisense path helpers (PATH normalization + per-repo state-dir resolvers)
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/intellisense-paths.sh"

# Ensure ~/.local/bin and /opt/homebrew/bin are on PATH so tool-existence checks
# below (bd, code-review-graph) can find binaries installed via pipx / pip --user
# / uv tool / Homebrew even when the inherited shell PATH omits them.
_ensure_local_bin_on_path

# Read version from VERSION file — single source of truth
INTELLISENSE_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$INTELLISENSE_VERSION" ]; then
  echo "ERROR: VERSION file missing or empty at $SCRIPT_DIR/VERSION" >&2
  exit 1
fi

# Version tracking for incremental setup
STORED_VERSION=""
VERSION_MISMATCH=false
SKIP_SETUP_STEPS=false

# Validate all critical symlinks exist and point to valid directories
check_symlinks_valid() {
  local INTELLISENSE_HOME="$HOME/.intellisense"
  local CLAUDE_HOME="$HOME/.claude"

  # List of critical symlinks that MUST exist
  local CRITICAL_SYMLINKS=(
    "$CLAUDE_HOME/rules/baseline"
    "$CLAUDE_HOME/skills"
    "$CLAUDE_HOME/agents"
    "$CLAUDE_HOME/templates"
    "$CLAUDE_HOME/infrastructure"
    "$CLAUDE_HOME/service-map.md"
    "$INTELLISENSE_HOME/rules/language-specific"
    "$INTELLISENSE_HOME/rules/operational"
  )

  for SYMLINK in "${CRITICAL_SYMLINKS[@]}"; do
    # Check: is it a symlink? AND does it point to a valid target?
    if [ ! -L "$SYMLINK" ] || [ ! -d "$SYMLINK" ] && [ ! -f "$SYMLINK" ]; then
      echo -e "  ${RED}[INVALID]${NC} Symlink broken or missing: $SYMLINK"
      return 1
    fi
  done

  return 0
}

check_version() {
  if [ -f "$CLAUDE_HOME/.intellisense-version" ]; then
    STORED_VERSION="$(grep 'INTELLISENSE_VERSION=' "$CLAUDE_HOME/.intellisense-version" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')"
    if [ "$STORED_VERSION" = "$INTELLISENSE_VERSION" ]; then
      echo -e "  ${GREEN}[OK]${NC} Version check: ~/.claude at v$INTELLISENSE_VERSION (current)"

      # IMPROVED FIX: Also validate symlinks before skipping setup
      if check_symlinks_valid; then
        echo -e "  ${GREEN}[OK]${NC} Symlink validation: all critical symlinks valid"
        SKIP_SETUP_STEPS=true
      else
        echo -e "  ${YELLOW}[WARN]${NC} Symlinks invalid or missing — running full setup to restore"
        SKIP_SETUP_STEPS=false
      fi
    else
      echo -e "  ${YELLOW}[WARN]${NC} Version mismatch: v$STORED_VERSION → v$INTELLISENSE_VERSION"
      VERSION_MISMATCH=true
    fi
  fi
}

# Status line helper
status_line() {
  local STATUS="$1"
  local ITEM="$2"
  case "$STATUS" in
    CREATED) echo -e "  ${GREEN}[CREATED]${NC}  $ITEM" ;;
    SKIPPED) echo -e "  ${YELLOW}[SKIPPED]${NC}  $ITEM" ;;
    UPDATED) echo -e "  ${YELLOW}[UPDATED]${NC}  $ITEM" ;;
    FAILED)  echo -e "  ${RED}[FAILED]${NC}   $ITEM" ;;
  esac
}

# Generate Rules Loading Strategy section
generate_rules_loading_strategy() {
  cat << 'EOF'
**Baseline** (auto-loaded, symlinked to ~/.claude/rules/baseline/):
- ~/.claude/rules/baseline/security.md — security boundaries, secret/PII safety, pre-commit security checks
- ~/.claude/rules/baseline/reasoning-integrity.md — reasoning stability, anti-sycophancy, position integrity

**Operational** (source: ~/.intellisense/rules/operational/):
@~/.intellisense/rules/operational/development-workflow.md
- development-workflow.md — Phase 0/1 workflow spine; all modes (auto-loaded above)
- ~/.intellisense/rules/operational/development-workflow-impl.md — Phases 2-6; coding modes only
- ~/.intellisense/rules/operational/coding-style.md — file/function size limits, naming, structure (load_when: coding)
- ~/.intellisense/rules/operational/testing.md — full_feature and bug_fix only
- ~/.intellisense/rules/operational/git-workflow.md — commit/push/PR only
- ~/.intellisense/rules/operational/patterns.md — planning and design review
- ~/.intellisense/rules/operational/agents.md — agent orchestration, subject to mode gates

**Language-Specific** (source: ~/.intellisense/rules/language-specific/; loaded per repo):
- ~/.intellisense/rules/language-specific/go-patterns.md — Go services (Phase 2+ only)
- ~/.intellisense/rules/language-specific/angular-patterns.md — Angular apps (Phase 2+ only)
- ~/.intellisense/rules/language-specific/laravel-patterns.md — PHP/Laravel services (Phase 2+ only)
EOF
}

# Update managed block using markers
update_managed_block() {
  local FILE="$1"
  local BLOCK_NAME="$2"
  local CONTENT_FILE="$3"

  local START_MARKER="<!-- INTELLISENSE-MANAGED:${BLOCK_NAME}:start -->"
  local END_MARKER="<!-- INTELLISENSE-MANAGED:${BLOCK_NAME}:end -->"

  if ! grep -q "$START_MARKER" "$FILE" 2>/dev/null; then
    return 1  # No markers found — caller uses fallback
  fi

  local TEMP_FILE="${FILE}.tmp"
  local in_block=0

  while IFS= read -r line; do
    if [[ "$line" == "$START_MARKER" ]]; then
      echo "$line"           # preserve start marker
      cat "$CONTENT_FILE"
      in_block=1
    elif [[ "$line" == "$END_MARKER" ]]; then
      echo "$line"           # preserve end marker
      in_block=0
    elif [ $in_block -eq 0 ]; then
      echo "$line"
    fi
    # lines between markers are silently dropped — replaced by CONTENT_FILE above
  done < "$FILE" > "$TEMP_FILE"

  mv "$TEMP_FILE" "$FILE"
  return 0
}

# First migration fallback — replace section without markers
replace_section_with_markers() {
  local FILE="$1"
  local SECTION_START="$2"
  local SECTION_END="$3"
  local CONTENT_FILE="$4"

  local START_MARKER="<!-- INTELLISENSE-MANAGED:rules-loading-strategy:start -->"
  local END_MARKER="<!-- INTELLISENSE-MANAGED:rules-loading-strategy:end -->"

  local TEMP_FILE="${FILE}.tmp"
  local in_section=0

  while IFS= read -r line; do
    if [[ "$line" == "$SECTION_START"* ]]; then
      echo "$line"         # preserve heading (with any suffix like [intellisense])
      echo "$START_MARKER"
      cat "$CONTENT_FILE"
      echo "$END_MARKER"
      in_section=1
    elif [[ "$line" == "$SECTION_END" ]] && [ $in_section -eq 1 ]; then
      echo "$line"
      in_section=0
    elif [ $in_section -eq 0 ]; then
      echo "$line"
    fi
  done < "$FILE" > "$TEMP_FILE"

  mv "$TEMP_FILE" "$FILE"
}

# Prune oldest CLAUDE.bak-* files in $INTELLISENSE_BACKUPS_DIR — keep newest 3 by mtime.
# Called from regenerate_global_claude_md after each potential rotation. The
# cap of 3 gives a small recovery window without unbounded disk growth.
prune_claude_md_backups() {
  local KEEP=3
  [ -d "$INTELLISENSE_BACKUPS_DIR" ] || return 0
  ls -1t "$INTELLISENSE_BACKUPS_DIR"/CLAUDE.bak-* 2>/dev/null \
    | tail -n +$((KEEP + 1)) \
    | xargs -I {} rm -f {} 2>/dev/null || true
}

# Merge intellisense-managed keys from .claude/settings.json.template into the user's
# active ~/.claude/settings.json. Idempotent — strips prior intellisense hook entries
# before re-adding so re-runs don't duplicate. Called from BOTH the main setup
# path AND the version-match fast path (skip_to_validation), because the
# template can pick up new hook entries (e.g. PostToolUse for the PostToolUse usage tracker) between
# releases that share the same VERSION.
#
# Merges 4 intellisense-owned groups:
#   - .intellisense                          (config block)
#   - .hooks.PreToolUse              (contract gate)
#   - .hooks.PostToolUse             (usage tracker — Skill|Agent matcher)
#   - .hooks.UserPromptSubmit        (classifier; under matcher=="" entry)
# All other top-level keys and other hook matchers are preserved untouched.
regenerate_settings_json() {
  if [ ! -f "$SCRIPT_DIR/.claude/settings.json.template" ]; then
    echo -e "${YELLOW}[SKIP] Template not found: $SCRIPT_DIR/.claude/settings.json.template${NC}"
    return 0
  fi
  if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Would generate or merge ~/.claude/settings.json from template${NC}"
    return 0
  fi

  local RENDERED_TEMPLATE
  RENDERED_TEMPLATE=$(mktemp)
  sed "s|\${HOME}|$HOME|g; s|\${INTELLISENSE_SETUP_PATH}|$SCRIPT_DIR|g" \
      "$SCRIPT_DIR/.claude/settings.json.template" > "$RENDERED_TEMPLATE"

  if [ ! -f "$CLAUDE_HOME/settings.json" ]; then
    mv "$RENDERED_TEMPLATE" "$CLAUDE_HOME/settings.json"
    CREATED_FILES+=("$CLAUDE_HOME/settings.json")
    status_line "GENERATED" "~/.claude/settings.json (fresh install)"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    local BACKUP_PATH="$CLAUDE_HOME/settings.json.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$CLAUDE_HOME/settings.json" "$BACKUP_PATH"
    mv "$RENDERED_TEMPLATE" "$CLAUDE_HOME/settings.json"
    echo -e "${YELLOW}[WARN] jq not available — settings.json was overwritten. Backup: $BACKUP_PATH${NC}"
    status_line "OVERWRITTEN" "~/.claude/settings.json (no-jq fallback; backup saved)"
    return 0
  fi

  # Safe jq merge — preserves dev-local hooks/permissions/customizations.
  local BACKUP_PATH="$CLAUDE_HOME/settings.json.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$CLAUDE_HOME/settings.json" "$BACKUP_PATH"

  local TPL_INTELLISENSE TPL_PRETOOL TPL_CLASSIFIER TPL_POSTTOOL
  TPL_INTELLISENSE=$(jq '.intellisense // {}' "$RENDERED_TEMPLATE")
  TPL_PRETOOL=$(jq '[ .hooks.PreToolUse[]? | select(.hooks[]?.command | test("preToolUse-contract-gate")) ]' "$RENDERED_TEMPLATE")
  TPL_CLASSIFIER=$(jq '[ .hooks.UserPromptSubmit[]?.hooks[]? | select(.command | test("userPromptSubmit-classifier")) ]' "$RENDERED_TEMPLATE")
  # PostToolUse Skill|Agent matcher entries (the usage tracker). Selecting by
  # command keeps the whole matcher entry, so the "Skill|Agent" matcher survives
  # and a renamed matcher in the template still merges.
  TPL_POSTTOOL=$(jq '[ .hooks.PostToolUse[]? | select(.hooks[]?.command | test("postToolUse-usage-tracker")) ]' "$RENDERED_TEMPLATE")

  local MERGED
  MERGED=$(mktemp)
  jq \
      --argjson intellisense "$TPL_INTELLISENSE" \
      --argjson pretool "$TPL_PRETOOL" \
      --argjson classifier "$TPL_CLASSIFIER" \
      --argjson posttool "$TPL_POSTTOOL" \
      '
        .intellisense = ((.intellisense // {}) * $intellisense)
      | .hooks = (.hooks // {})
      | .hooks.PreToolUse = (
          [( .hooks.PreToolUse // [] )[] | select((.hooks // []) | map(.command | test("preToolUse-contract-gate")) | any | not)]
          + $pretool
        )
      | .hooks.PostToolUse = (
          [( .hooks.PostToolUse // [] )[] | select((.hooks // []) | map(.command | test("postToolUse-usage-tracker")) | any | not)]
          + $posttool
        )
      | .hooks.UserPromptSubmit = (
          ( (.hooks.UserPromptSubmit // [])
            | map(.hooks = ((.hooks // []) | map(select(.command | test("userPromptSubmit-classifier") | not))))
          )
        )
      | .hooks.UserPromptSubmit = (
          if (.hooks.UserPromptSubmit | map(.matcher == "") | any)
          then
            .hooks.UserPromptSubmit
            | map(if .matcher == "" then .hooks = ((.hooks // []) + $classifier) else . end)
          else
            [{matcher: "", hooks: $classifier}] + .hooks.UserPromptSubmit
          end
        )
      ' "$CLAUDE_HOME/settings.json" > "$MERGED"

  if jq -e . "$MERGED" >/dev/null 2>&1 && [ -s "$MERGED" ]; then
    mv "$MERGED" "$CLAUDE_HOME/settings.json"
    status_line "MERGED" "~/.claude/settings.json (intellisense keys merged; backup: $BACKUP_PATH)"
  else
    echo -e "${RED}ERROR: jq merge produced invalid output. Original preserved at $BACKUP_PATH; current file may need manual restoration.${NC}"
    cp "$BACKUP_PATH" "$CLAUDE_HOME/settings.json"
    rm -f "$MERGED"
  fi
  rm -f "$RENDERED_TEMPLATE"
}

# ─── intellisense heartbeat token install ────────────────────────────────
# Stores the shared bearer token to ~/.intellisense/heartbeat-token (0600), and the
# org's own telemetry endpoint to ~/.intellisense/heartbeat-endpoint (0600). Neither
# is bundled with this repo — every adopting organization stands up its own
# collector and configures both values here.
# Token source priority:
#   1. $INTELLISENSE_HEARTBEAT_TOKEN env var (set before running setup.sh)
#   2. Interactive paste (read -rs, hidden)
#   3. Existing token file (rotate path re-prompts; otherwise leave alone)
# Endpoint source priority: $INTELLISENSE_HEARTBEAT_ENDPOINT env var → interactive
# prompt → existing endpoint file. There is no built-in default endpoint —
# an unconfigured install has nowhere of ours to send data to.
# Skips entirely if --no-heartbeat passed.
#
# The token is NEVER:
#   - Committed to the intellisense repo
#   - Embedded in setup.sh
#   - Logged or echoed
#   - Stored anywhere besides ~/.intellisense/heartbeat-token (0600)
install_heartbeat_token() {
  # POLICY: the heartbeat is REQUIRED. setup.sh cannot complete without the
  # token being installed. There is no developer-facing opt-out and no
  # "install later" option — every re-run that finds it missing will fail.
  #
  # --no-heartbeat exists ONLY for CI/test environments that run setup.sh
  # against ephemeral repos. It is documented as such and not surfaced in
  # the interactive prompt.
  #
  # Return codes:
  #   0 = token installed (or --no-heartbeat / --dry-run)
  #   1 = no token available → caller must exit non-zero (BLOCKS setup)
  if [[ "$NO_HEARTBEAT" == true ]]; then
    status_line "SKIP" "intellisense heartbeat install (--no-heartbeat — CI/test only)"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[DRY-RUN] Would install intellisense heartbeat token + daily cron${NC}"
    return 0
  fi

  local token_dir="$HOME/.intellisense"
  local token_file="$token_dir/heartbeat-token"
  local endpoint_file="$token_dir/heartbeat-endpoint"
  mkdir -p "$token_dir" 2>/dev/null
  chmod 700 "$token_dir" 2>/dev/null || true

  local token=""
  local endpoint=""

  # Rotate path → always re-prompt, even if files already exist
  if [[ "$ROTATE_TOKEN" == true ]]; then
    rm -f "$token_file"
  fi

  # Endpoint resolution: env var → existing config → interactive prompt.
  # There is no bundled default — an org must point this at its own
  # collector before the heartbeat can go anywhere.
  if [[ -n "${INTELLISENSE_HEARTBEAT_ENDPOINT:-}" ]]; then
    endpoint="$INTELLISENSE_HEARTBEAT_ENDPOINT"
  elif [[ -f "$endpoint_file" ]]; then
    endpoint="$(cat "$endpoint_file" 2>/dev/null)"
  fi

  # 1. env var (CI / scripted installs)
  if [[ -n "${INTELLISENSE_HEARTBEAT_TOKEN:-}" ]]; then
    token="$INTELLISENSE_HEARTBEAT_TOKEN"
  # 2. token + endpoint already installed → reuse (and skip prompting)
  elif [[ -f "$token_file" && -n "$endpoint" ]]; then
    status_line "PRESENT" "intellisense heartbeat token already installed ($token_file)"
    return 0
  # 3. interactive — token + endpoint are REQUIRED, no defer / skip option
  elif [[ "$INTERACTIVE" == true && -t 0 ]]; then
    echo
    echo "  ─── intellisense heartbeat — REQUIRED to complete setup ──────────────────"
    echo
    echo "  The heartbeat POSTs daily developer stats (intellisense version, GitHub"
    echo "  login, repos onboarded, daily token usage, /skill adoption) to"
    echo "  your organization's telemetry collector. This install has no"
    echo "  bundled endpoint — every organization configures its own."
    echo
    if [[ -z "$endpoint" ]]; then
      echo "  Ask your intellisense platform admin for:"
      echo "    - the collector endpoint URL (INTELLISENSE_HEARTBEAT_ENDPOINT)"
      echo "    - a bearer token for it"
      echo
      read -rp "  intellisense heartbeat endpoint URL: " endpoint
    fi
    echo
    echo "  Paste the token below. Input is hidden. Press Enter when done."
    echo "  Setup cannot continue without a valid endpoint + token."
    echo
    read -rs -p "  intellisense heartbeat token: " token
    echo
  fi

  # Missing endpoint and/or token + not in CI mode → BLOCK setup with clear
  # instructions. One combined message so the "nothing configured" case
  # still names INTELLISENSE_HEARTBEAT_TOKEN even though endpoint is checked first.
  if [[ -z "$endpoint" || -z "$token" ]]; then
    local missing="endpoint and token"
    [[ -n "$endpoint" ]] && missing="token"
    [[ -n "$token" ]] && missing="endpoint"
    cat >&2 <<EOF

${RED}❌ Setup blocked: intellisense heartbeat $missing not configured.${NC}

  The heartbeat is required for org analytics — there is no skip option
  for developers, and this framework does not ship a default collector.

  How to provide it:

    Interactive (most common):
      bash setup.sh
      # paste when prompted

    Non-interactive / CI-scripted:
      INTELLISENSE_HEARTBEAT_ENDPOINT='https://...' INTELLISENSE_HEARTBEAT_TOKEN='<paste>' \\
        bash setup.sh --non-interactive --yes

  Where to find these values: ask your organization's intellisense platform admin.

  CI/test environments only (not for developer use):
      bash setup.sh --no-heartbeat

EOF
    return 1
  fi

  # Validate token format: printable ASCII, no whitespace, reasonable length
  if [[ ! "$token" =~ ^[A-Za-z0-9._/+=-]+$ ]] || (( ${#token} < 16 )) || (( ${#token} > 200 )); then
    cat >&2 <<EOF

${RED}❌ Setup blocked: token format invalid.${NC}

  Got: ${#token} characters. Expected: 16-200 printable ASCII chars
  (letters, digits, ._/+=-), no whitespace.

  Check with your organization's intellisense platform admin — values are typically
  60+ characters. Common mistake: pasting a wrapped/truncated value.

  Re-run setup.sh after getting the correct token.

EOF
    token=""   # wipe before return
    return 1
  fi

  # Write 0600
  umask 077
  printf '%s' "$token" > "$token_file"
  chmod 600 "$token_file"
  printf '%s' "$endpoint" > "$endpoint_file"
  chmod 600 "$endpoint_file"
  token=""   # wipe local var
  status_line "INSTALLED" "intellisense heartbeat token → $token_file (mode 600)"
  status_line "INSTALLED" "intellisense heartbeat endpoint → $endpoint_file (mode 600)"
}

# ─── intellisense heartbeat daily cron install ──────
# v8 design:
#   1. Copy runtime out of INTELLISENSE_SETUP into ~/.intellisense/bin/ so it works
#      regardless of where the repo lives. TCC denies launchd from reading
#      executables under ~/Desktop, ~/Documents, ~/Downloads.
#   2. Atomic copy + manifest write — survives concurrent setup.sh runs.
#   3. Plist EnvironmentVariables carries HB_VERSION_FILE + extended PATH
#      so jq/python3 resolve under launchd's reduced env.
#   4. Linux mirrors the copy-install (one code path, no TCC dependency
#      but the consistency is worth the trivial cost).

# Cross-platform atomic copy: cp → mv via a temp file in the destination dir.
# Returns 0 on success, non-zero on copy failure (caller decides what missing
# means).
_hb_atomic_install_file() {
  local src="$1" dst="$2" mode="${3:-644}"
  local tmp="$dst.tmp.$$"
  mkdir -p "$(dirname "$dst")" 2>/dev/null
  cp "$src" "$tmp" 2>/dev/null || return 1
  chmod "$mode" "$tmp" 2>/dev/null
  mv "$tmp" "$dst" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# Write MANIFEST.sha256 atomically using the cross-platform helper. Format:
#   <sha256>  <basename-or-libpath>
# Filenames are POSIX-safe by invariant (see plan Section 4 filename rule).
_hb_write_manifest() {
  local bin_dir="$1"
  local manifest="$bin_dir/MANIFEST.sha256"
  local tmp="$manifest.tmp.$$"

  # shellcheck source=scripts/lib/hash.sh
  source "$SCRIPT_DIR/scripts/lib/hash.sh" 2>/dev/null || return 1

  {
    # heartbeat-prices.json is DELIBERATELY excluded: hb_refresh_prices
    # swaps it at runtime from the repo so a model release reaches
    # devs without a git pull, so its hash legitimately changes after install.
    # This MUST match the exclusion in refresh-heartbeat-runtime.sh AND
    # verify-setup.sh Check 19c/19d — otherwise a fresh install writes a manifest
    # with prices.json and the verifier (which recomputes without it) reports a
    # false "runtime tampered" failure. Integrity covers the executables only;
    # the bundled prices.json is still installed (cold-start fallback).
    for f in intellisense-heartbeat.sh \
             lib/heartbeat-payload.sh \
             lib/heartbeat_usage_parser.py; do
      if [[ -f "$bin_dir/$f" ]]; then
        local h
        h="$(hb_sha256 "$bin_dir/$f")" || return 1
        printf '%s  %s\n' "$h" "$f"
      fi
    done
  } > "$tmp" || return 1
  mv "$tmp" "$manifest" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# Install the intellisense post-merge hook so `git pull` auto-refreshes the heartbeat
# runtime when any tracked heartbeat file changes.
#
# Honors `core.hooksPath` — beads sets this to `.beads/hooks`, so the hook
# must land there (not `.git/hooks`) or git ignores it.
#
# Coexists with beads' existing post-merge content: appends a sentinel-bracketed
# section, replacing only that section on re-runs. Pure sh syntax inside the
# section so beads' `#!/usr/bin/env sh` shebang stays valid.
#
# Returns 0 on success, 1 on failure (caller decides whether to warn).
_hb_install_post_merge_hook() {
  local setup_dir="$1"
  local template="$setup_dir/templates/git-hooks/post-merge"

  # Only install if we're in an actual git repo (skip for tarball installs).
  if ! ( cd "$setup_dir" && git rev-parse --git-dir >/dev/null 2>&1 ); then
    return 0
  fi
  if [[ ! -f "$template" ]]; then
    return 1
  fi

  # Resolve the real hooks dir (handles beads' core.hooksPath override).
  local hooks_dir
  hooks_dir="$( cd "$setup_dir" && git config --get core.hooksPath 2>/dev/null )"
  if [[ -z "$hooks_dir" ]]; then
    hooks_dir="$setup_dir/.git/hooks"
  elif [[ "$hooks_dir" != /* ]]; then
    hooks_dir="$setup_dir/$hooks_dir"
  fi
  mkdir -p "$hooks_dir" 2>/dev/null || return 1

  local target="$hooks_dir/post-merge"
  local begin='# --- BEGIN intellisense HEARTBEAT POST-MERGE v1 ---'
  local end='# --- END intellisense HEARTBEAT POST-MERGE v1 ---'
  local tmp="$target.tmp.$$"

  local section
  section="$(cat "$template")" || return 1

  if [[ ! -f "$target" ]]; then
    {
      printf '#!/usr/bin/env sh\n'
      printf '%s\n' "$section"
    } > "$tmp" || return 1
  elif grep -qF "$begin" "$target" 2>/dev/null; then
    # Existing hook with our sentinel — replace just our section.
    # Pass section via ENVIRON since `-v` rejects newlines in values.
    SECTION="$section" awk -v begin="$begin" -v end="$end" '
      BEGIN { in_block = 0 }
      $0 == begin { in_block = 1; print ENVIRON["SECTION"]; next }
      $0 == end { in_block = 0; next }
      !in_block { print }
    ' "$target" > "$tmp" || return 1
  else
    # Existing hook (likely beads or developer-written) — append our section.
    {
      cat "$target"
      printf '\n%s\n' "$section"
    } > "$tmp" || return 1
  fi

  chmod 755 "$tmp" 2>/dev/null
  mv "$tmp" "$target" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# resolve the developer's GitHub login once at install time, in
# the interactive shell where SSH keys / origin remotes / TTY are available.
# The resolved value is injected into the launchd plist EnvironmentVariables
# (and Linux cron env) so step 1 of hb_github_login (INTELLISENSE_GH_LOGIN env) wins
# at cron-fire time — including the case where gh is authenticated against a
# GitHub Enterprise account whose login differs from the dev's github.com
# handle (env-var override moved to step 1 as of 2026-06-03).
# Falls back through 5 sources; never prints to stdout except the final value.
resolve_github_login() {
  local login=""

  # 1. Explicit env override (admin / CI / company onboarding) — checked FIRST so
  #    it beats auto-detect, matching hb_github_login step 1 (commit 4850954).
  #    Without this, a dev who runs `INTELLISENSE_GH_LOGIN=handle bash setup.sh` would
  #    have it silently discarded when the origin-URL or SSH probe below resolves
  #    a (possibly wrong, e.g. GHE) login first — the override would never reach
  #    the baked plist/cron value.
  if [[ -n "${INTELLISENSE_GH_LOGIN:-}" ]]; then
    printf '%s' "$INTELLISENSE_GH_LOGIN"
    return 0
  fi

  # 2. $PWD origin URL — typical install flow is `cd <fork-clone> && bash setup.sh`,
  #    so origin contains the dev's GitHub username. Filter out upstream-org owners
  #    so a dev who cloned upstream by mistake falls through instead of being
  #    mis-labelled as the upstream org (INTELLISENSE_UPSTREAM_ORGS, space-separated).
  local url
  url="$(git -C "$PWD" remote get-url origin 2>/dev/null || true)"
  if [[ -n "$url" ]]; then
    login="$(echo "$url" \
      | sed -nE 's#^(git@github\.com:|https://github\.com/)([^/]+)/.*#\2#p')"
    if [[ " ${INTELLISENSE_UPSTREAM_ORGS:-soupler-oss} " == *" $login "* ]]; then
      login=""
    fi
  fi

  # 3. ssh -T git@github.com — works for any dev whose SSH key is registered on
  #    GitHub, regardless of whether they forked. GitHub answers with
  #    "Hi <username>! You've successfully authenticated...". Network call;
  #    BatchMode=yes prevents password prompts; ConnectTimeout caps the wait.
  if [[ -z "$login" ]] && command -v ssh >/dev/null 2>&1; then
    login="$(ssh -T -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new git@github.com 2>&1 \
      | sed -nE 's/^Hi ([A-Za-z0-9._-]+)!.*/\1/p')"
  fi

  # 4. Interactive prompt — last resort when auto-detect fails AND we have a TTY.
  #    Skipped in non-interactive mode (no -t 0); caller handles empty result.
  if [[ -z "$login" && -t 0 ]]; then
    printf "  GitHub username: " >&2
    read -r login || login=""
  fi

  # 5. Email local-part safety net — wrong identity > no identity for telemetry
  #    (matches the documented fallback in hb_github_login step 3). When all
  #    prior steps fail, emit the email local-part so the plist isn't empty
  #    and the cron has *something* to report.
  if [[ -z "$login" ]] && command -v git >/dev/null 2>&1; then
    local email
    email="$(git config --global --get user.email 2>/dev/null || true)"
    if [[ -n "$email" && "$email" == *"@"* ]]; then
      local candidate="${email%%@*}"
      if [[ "$candidate" =~ ^[A-Za-z0-9._-]+$ ]]; then
        login="$candidate"
      fi
    fi
  fi

  printf '%s' "$login"
}

install_heartbeat_cron() {
  if [[ "$NO_HEARTBEAT" == true ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    return 0
  fi
  # Don't install the cron if no token exists — the cron would just fail nightly
  if [[ ! -f "$HOME/.intellisense/heartbeat-token" ]]; then
    return 0
  fi

  # ─── v8: copy runtime out of INTELLISENSE_SETUP (TCC-safe location) ───────────────
  local bin_dir="$HOME/.intellisense/bin"
  mkdir -p "$bin_dir/lib" 2>/dev/null

  # Copy each runtime file atomically. Hard-fail if any copy fails — this
  # is a launchd-critical install.
  _hb_atomic_install_file "$SCRIPT_DIR/scripts/intellisense-heartbeat.sh" \
                          "$bin_dir/intellisense-heartbeat.sh" 755 \
    || { echo -e "${RED}[ERROR] failed to install intellisense-heartbeat.sh${NC}"; return 1; }
  _hb_atomic_install_file "$SCRIPT_DIR/scripts/lib/heartbeat-payload.sh" \
                          "$bin_dir/lib/heartbeat-payload.sh" 755 \
    || { echo -e "${RED}[ERROR] failed to install heartbeat-payload.sh${NC}"; return 1; }
  _hb_atomic_install_file "$SCRIPT_DIR/scripts/lib/heartbeat_usage_parser.py" \
                          "$bin_dir/lib/heartbeat_usage_parser.py" 755 \
    || { echo -e "${RED}[ERROR] failed to install heartbeat_usage_parser.py${NC}"; return 1; }
  _hb_atomic_install_file "$SCRIPT_DIR/scripts/lib/heartbeat-prices.json" \
                          "$bin_dir/lib/heartbeat-prices.json" 644 \
    || { echo -e "${RED}[ERROR] failed to install heartbeat-prices.json${NC}"; return 1; }
  _hb_atomic_install_file "$SCRIPT_DIR/scripts/lib/hash.sh" \
                          "$bin_dir/lib/hash.sh" 755 \
    || { echo -e "${RED}[ERROR] failed to install hash.sh${NC}"; return 1; }

  # Copy VERSION into a non-TCC-protected location so the heartbeat can
  # report intellisense_version without needing repo access under launchd.
  if [[ -f "$SCRIPT_DIR/VERSION" ]]; then
    _hb_atomic_install_file "$SCRIPT_DIR/VERSION" \
                            "$HOME/.intellisense/VERSION" 644 \
      || echo -e "${YELLOW}[WARN] failed to copy VERSION (heartbeat will report 'unknown')${NC}"
  fi

  # Write manifest. Failure is non-fatal (heartbeat still works; verify-setup
  # will flag the missing manifest).
  _hb_write_manifest "$bin_dir" \
    || echo -e "${YELLOW}[WARN] failed to write MANIFEST.sha256${NC}"

  # Install the post-merge git hook so future `git pull` in INTELLISENSE_SETUP
  # auto-refreshes the runtime when heartbeat files change. Per-clone
  # (git hooks aren't version-controlled); re-running setup.sh re-installs.
  _hb_install_post_merge_hook "$SCRIPT_DIR" \
    || echo -e "${YELLOW}[WARN] failed to install post-merge git hook (manual 'bash setup.sh --refresh-runtime' still works)${NC}"

  local heartbeat_script="$bin_dir/intellisense-heartbeat.sh"
  local version_file="$HOME/.intellisense/VERSION"
  # Extended PATH for launchd / cron — covers Apple Silicon (/opt/homebrew/bin),
  # Intel Macs (/usr/local/bin), Linuxbrew, user-local installs.
  local sched_path="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

  # resolve GitHub login NOW (interactive shell — gh / SSH / TTY
  # all work here) and bake into the cron env. At fire time launchd's stripped
  # env breaks both `gh api user` and SSH-agent access; even when gh DOES
  # succeed (e.g. under a developer's login shell), it may be authenticated
  # against a GitHub Enterprise account whose login differs from the
  # developer's github.com handle. INTELLISENSE_GH_LOGIN is now hb_github_login
  # step 1, so the value baked here always wins. Without this injection,
  # the cron would fall through to step 3 (email local-part) or emit the
  # wrong GHE login from step 2.
  local intellisense_gh_login
  intellisense_gh_login="$(resolve_github_login)"
  if [[ -z "$intellisense_gh_login" ]]; then
    echo -e "${YELLOW}[WARN] could not resolve GitHub login at install time; heartbeat will fall back to email local-part at cron time${NC}"
  fi
  # Export so the post-install "fire once" (a child subshell in the main flow)
  # inherits the SAME login baked into the plist/cron below. Without this the
  # immediate heartbeat re-resolves via hb_github_login — which has no
  # origin-URL step — and falls to the email local-part on first-time machines
  # where gh isn't authenticated yet, mislabelling the dev's very first row.
  [[ -n "$intellisense_gh_login" ]] && export INTELLISENSE_GH_LOGIN="$intellisense_gh_login"

  local platform; platform="$(uname -s 2>/dev/null)"

  case "$platform" in
    Darwin)
      # launchd plist — fires HOURLY via StartCalendarInterval with only Minute=0
      # Unlike StartInterval, StartCalendarInterval COALESCES fires
      # missed while the host was asleep/off into a single fire on wake — that's
      # the multi-day-off catch-up. The app-level watermark makes runs with
      # nothing due near-free (no POST, no git fetch), so a transient outage
      # recovers within the hour instead of next day.
      local plist_dir="$HOME/Library/LaunchAgents"
      local plist="$plist_dir/in.intellisense.heartbeat.plist"
      local plist_tmp="$plist.tmp.$$"
      mkdir -p "$plist_dir"
      cat > "$plist_tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>in.intellisense.heartbeat</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$heartbeat_script</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HB_VERSION_FILE</key><string>$version_file</string>
        <key>INTELLISENSE_SETUP_PATH</key><string>$SCRIPT_DIR</string>
        <key>PATH</key><string>$sched_path</string>
        <key>INTELLISENSE_GH_LOGIN</key><string>$intellisense_gh_login</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Minute</key><integer>0</integer>
    </dict>
    <key>StandardErrorPath</key><string>$HOME/.claude-intellisense/heartbeat-cron.log</string>
    <key>StandardOutPath</key><string>$HOME/.claude-intellisense/heartbeat-cron.log</string>
</dict>
</plist>
EOF
      mv "$plist_tmp" "$plist" 2>/dev/null || { rm -f "$plist_tmp"; \
        echo -e "${RED}[ERROR] failed to write plist${NC}"; return 1; }

      # Reload: unload first (ignore errors) then load. Idempotent.
      launchctl unload "$plist" 2>/dev/null || true
      if launchctl load "$plist" 2>/dev/null; then
        status_line "INSTALLED" "intellisense heartbeat launchd job (hourly, watermark-gated; TCC-safe runtime in $bin_dir)"
      else
        echo -e "${YELLOW}[WARN] launchctl load failed; plist written to $plist — load manually${NC}"
      fi
      ;;
    Linux)
      # v9: prefer a systemd --user timer with Persistent=true so a
      # run missed while the laptop is off/asleep at 09:00 fires once on next
      # boot/resume — matching the macOS launchd StartCalendarInterval catch-up.
      # Plain crontab does NOT catch up missed runs, so it is now only the
      # last-resort fallback (after systemd, then anacron) for hosts without
      # a systemd --user instance.

      # Reusable crontab fallback. Uses the enclosing scope's locals
      # (sched_path/version_file/intellisense_gh_login/heartbeat_script/bin_dir) via
      # bash dynamic scoping. Idempotent: strips any prior intellisense-heartbeat line.
      _hb_install_crontab() {
        if ! command -v crontab >/dev/null 2>&1; then
          echo -e "${YELLOW}[WARN] no cron mechanism found; heartbeat will only fire on manual setup.sh runs${NC}"
          return 1
        fi
        local tmpcron cron_env
        tmpcron="$(mktemp)"
        crontab -l 2>/dev/null | grep -v 'intellisense-heartbeat' > "$tmpcron" || true
        cron_env="PATH=\"$sched_path\" HB_VERSION_FILE=\"$version_file\" INTELLISENSE_SETUP_PATH=\"$SCRIPT_DIR\" INTELLISENSE_GH_LOGIN=\"$intellisense_gh_login\""
        # Three lines, since plain crontab does NOT catch up missed runs:
        #   - daily 09:00     : the normal fire
        #   - @reboot         : recover a 09:00 missed while the host was off
        #   - hourly probe    : app-level catch-up backfills any still-missing
        #                       days; a no-op once the watermark is current
        # All carry the 'intellisense-heartbeat' marker so reinstall strips them cleanly.
        echo "0 9 * * * $cron_env /bin/bash $heartbeat_script  # intellisense-heartbeat" >> "$tmpcron"
        echo "@reboot $cron_env /bin/bash $heartbeat_script  # intellisense-heartbeat-reboot" >> "$tmpcron"
        echo "0 * * * * $cron_env /bin/bash $heartbeat_script  # intellisense-heartbeat-catchup" >> "$tmpcron"
        if crontab "$tmpcron" 2>/dev/null; then
          status_line "INSTALLED" "intellisense heartbeat crontab entries (09:00 + @reboot + hourly catch-up, runtime in $bin_dir)"
        else
          echo -e "${YELLOW}[WARN] crontab install failed${NC}"
        fi
        rm -f "$tmpcron"
      }

      # Verify the systemd --user timer is actually enabled with a future
      # trigger. enable --now can silently no-op (missing XDG_RUNTIME_DIR/user
      # bus at install) leaving the timer disabled → zero delivery.
      _hb_timer_verified() {
        local en
        en="$(systemctl --user is-enabled intellisense-heartbeat.timer 2>/dev/null)"
        [[ "$en" == "enabled" ]] || return 1
        systemctl --user list-timers intellisense-heartbeat.timer 2>/dev/null \
          | grep -q 'intellisense-heartbeat.timer' || return 1
        return 0
      }

      # True when this process is running inside a VTE terminal's transient
      # vte-spawn-*.scope (gnome-terminal, tilix, terminator, xfce4-terminal…).
      # cgroup v2 puts the path in field 3 of /proc/self/cgroup.
      _hb_in_vte_scope() {
        local cg
        cg="$(cut -d: -f3 /proc/self/cgroup 2>/dev/null | grep -m1 .)"
        case "$cg" in *vte-spawn-*.scope*) return 0 ;; *) return 1 ;; esac
      }

      # Issue a state-mutating `systemctl --user` call (daemon-reload / enable /
      # disable) from a detached session when we're inside a vte-spawn scope.
      # On systemd 254/255 such a call, issued from within that scope, makes the
      # user manager collect the scope (CollectMode=inactive-or-failed), killing
      # the interactive shell and closing the terminal window.
      # `setsid --wait` runs in a fresh session and propagates the exit code, so
      # the verify/fallback logic below is unchanged. Outside a vte scope (cron,
      # CI, non-VTE terminals, or where setsid lacks --wait) we run inline — the
      # bug can't occur there and inline keeps behavior identical.
      _hb_systemctl_user() {
        if _hb_in_vte_scope && command -v setsid >/dev/null 2>&1 \
            && setsid --wait true 2>/dev/null; then
          setsid --wait systemctl --user "$@" 2>/dev/null
        else
          systemctl --user "$@" 2>/dev/null
        fi
      }

      if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        local ud="$HOME/.config/systemd/user"
        mkdir -p "$ud"
        cat > "$ud/intellisense-heartbeat.service" <<EOF
[Unit]
Description=intellisense daily developer heartbeat

[Service]
Type=oneshot
Environment=PATH=$sched_path
Environment=HB_VERSION_FILE=$version_file
Environment=INTELLISENSE_SETUP_PATH=$SCRIPT_DIR
Environment=INTELLISENSE_GH_LOGIN=$intellisense_gh_login
ExecStart=/bin/bash $heartbeat_script
EOF
        cat > "$ud/intellisense-heartbeat.timer" <<EOF
[Unit]
Description=Run intellisense heartbeat hourly (watermark-gated; catch up if missed)

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
        # Drop any stale plain-cron line so we don't double-fire after migration.
        if command -v crontab >/dev/null 2>&1; then
          crontab -l 2>/dev/null | grep -v 'intellisense-heartbeat' | crontab - 2>/dev/null || true
        fi
        # enable-linger so the user manager (and thus the timer) runs at boot
        # before any GUI login. Best-effort: may be denied on managed hosts —
        # the timer still works whenever the user has an active session.
        loginctl enable-linger "$(id -un)" >/dev/null 2>&1 || true
        _hb_systemctl_user daemon-reload || true
        if _hb_systemctl_user enable --now intellisense-heartbeat.timer && _hb_timer_verified; then
          status_line "INSTALLED" "intellisense heartbeat systemd user timer (hourly, watermark-gated, Persistent catch-up, runtime in $bin_dir)"
        else
          # enable returned non-zero OR returned success but the timer is not
          # actually enabled/scheduled — fall back to cron rather than trust a
          # silent no-op.
          echo -e "${YELLOW}[WARN] systemd --user timer not enabled (enable failed or timer disabled); falling back to crontab${NC}"
          _hb_systemctl_user disable intellisense-heartbeat.timer || true
          rm -f "$ud/intellisense-heartbeat.timer" "$ud/intellisense-heartbeat.service"
          _hb_systemctl_user daemon-reload || true
          _hb_install_crontab || true
        fi
      elif command -v crontab >/dev/null 2>&1; then
        # Prefer crontab over anacron: the crontab fallback carries
        # hourly + @reboot + 09:00, so it's the only non-systemd path that actually
        # delivers hourly cadence. anacron has no sub-daily granularity.
        _hb_install_crontab || true
      elif [[ -d "${INTELLISENSE_ANACRON_DIR:-/etc/anacrontab.d}" ]] && [[ -w "${INTELLISENSE_ANACRON_DIR:-/etc/anacrontab.d}" ]]; then
        # DEGRADED last resort (no crontab available): anacron runs DAILY, not
        # hourly. The app-level watermark + queue still backfill missed days, but
        # transient-outage recovery is next-day here. Surfaced as a WARN so the
        # daily cadence isn't silent.
        local anadir="${INTELLISENSE_ANACRON_DIR:-/etc/anacrontab.d}"
        local af="$anadir/intellisense-heartbeat"
        echo "@daily   5   intellisense-heartbeat   /usr/bin/env PATH=\"$sched_path\" HB_VERSION_FILE=\"$version_file\" INTELLISENSE_SETUP_PATH=\"$SCRIPT_DIR\" INTELLISENSE_GH_LOGIN=\"$intellisense_gh_login\" /bin/bash $heartbeat_script" > "$af" 2>/dev/null \
          && status_line "WARN" "intellisense heartbeat anacron job ($af) is DAILY — degraded (no crontab for hourly cadence)" \
          || echo -e "${YELLOW}[WARN] anacron install failed (permissions?)${NC}"
      else
        echo -e "${YELLOW}[WARN] no crontab or anacron available; heartbeat fires only on manual setup.sh runs${NC}"
      fi
      ;;
    *)
      echo -e "${YELLOW}[WARN] unsupported platform '$platform' for cron install; manual runs only${NC}"
      ;;
  esac
}

# Take ownership of ~/.claude/CLAUDE.md. If a prior copy exists, back it up to
# $INTELLISENSE_BACKUPS_DIR/CLAUDE.bak-<ts> (no .md extension — invisible to any
# **/*.md auto-load glob), then write the generator output. Always runs,
# including on the version-match fast path, so missing/corrupted CLAUDE.md
# self-heals.
regenerate_global_claude_md() {
  if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Would regenerate ~/.claude/CLAUDE.md${NC}"
    return 0
  fi

  mkdir -p "$CLAUDE_HOME"

  if [ -f "$CLAUDE_HOME/CLAUDE.md" ]; then
    mkdir -p "$INTELLISENSE_BACKUPS_DIR"
    local BACKUP="$INTELLISENSE_BACKUPS_DIR/CLAUDE.bak-$(date +%Y%m%d%H%M%S)"
    mv "$CLAUDE_HOME/CLAUDE.md" "$BACKUP"
    status_line "UPDATED" "Backed up previous CLAUDE.md → $BACKUP"
  fi

  cat > "$CLAUDE_HOME/CLAUDE.md" << EOF
<!-- intellisense Managed — rules/skills/agents symlinked from INTELLISENSE_SETUP -->
# Global Developer CLAUDE.md

## Platform
intellisense Version: $INTELLISENSE_VERSION
INTELLISENSE_SETUP Path: $SCRIPT_DIR

## Rules Loading Strategy [intellisense]

**Baseline** (always loaded — all modes):
- rules/baseline/security.md — security boundaries, secret/PII safety, pre-commit security checks
- rules/baseline/reasoning-integrity.md — reasoning stability, anti-sycophancy, position integrity

**Operational** (source: ~/.intellisense/rules/operational/):
@~/.intellisense/rules/operational/development-workflow.md
- development-workflow.md — Phase 0/1 workflow spine; all modes (auto-loaded above)
- ~/.intellisense/rules/operational/development-workflow-impl.md — Phases 2-6; coding modes only
- ~/.intellisense/rules/operational/coding-style.md — file/function size limits, naming, structure (load_when: coding)
- ~/.intellisense/rules/operational/testing.md — full_feature and bug_fix only
- ~/.intellisense/rules/operational/git-workflow.md — commit/push/PR only
- ~/.intellisense/rules/operational/patterns.md — planning and design review
- ~/.intellisense/rules/operational/agents.md — agent orchestration, subject to mode gates

**Language-Specific** (source: ~/.intellisense/rules/language-specific/; loaded per repo):
- ~/.intellisense/rules/language-specific/go-patterns.md — Go services (Phase 2+ only)
- ~/.intellisense/rules/language-specific/angular-patterns.md — Angular apps (Phase 2+ only)
- ~/.intellisense/rules/language-specific/laravel-patterns.md — PHP/Laravel services (Phase 2+ only)

## Global Skills Available [intellisense]

All repos have access to:
- **/where-to-start** — find correct repo for a requirement (uses service-map + knowledge-base)
- **/plan** — single-repo requirement analysis
- **/multi-service-plan** — cross-service planning (Step 0 discovers affected services)
- **/tdd** — test-driven development workflow
- **/verify** — full verification suite
- **/code-review** — comprehensive quality review
- **/incident** — production incident fast path
- **/learn** — extract patterns; suggest rule or memory entries

## Routing Without Knowing the Repo

When a developer submits a requirement but doesn't know which repo:

1. **Read infrastructure/service-map.md** — which services exist, who owns what
2. **Read infrastructure/knowledge-base.md** (if /where-to-start invoked) — term ownership, DISPUTED terms
3. **Search CLAUDE.md Domain Terms** — definitions in each service
4. **Return ranked repo list** — top 3 with confidence scores (95%, 75%, 40%)
5. **If confidence <80%** — ask clarifying question, do not guess

Three-source confidence:
- All 3 sources agree → 95% confidence → Route
- 2 of 3 agree → 75% confidence → State uncertainty
- 1 of 3 or DISPUTED → Ask clarifying question

## Developer Profile

Name: $(whoami)
Email: $HOME/.claude/config.json (set by platform)
intellisense memory: durable insights go into rules (the repo's \`CLAUDE.md\` or \`.intellisense/rules/organization/\`), or into Beads memories (\`bd remember\`) when the team's tracker is Beads.
  MEMORY.md is personal and not used by intellisense workflows.
INTELLISENSE_SETUP: $SCRIPT_DIR (symlink source for rules/skills/agents)

## Critical Notes

- This file is generated by setup.sh — do NOT edit manually
- To update rules: edit files in INTELLISENSE_SETUP, then run \`git pull\` there
- Symlinks automatically resolve to updated files
- intellisense memory: durable insights go into rules (the repo's \`CLAUDE.md\` or \`.intellisense/rules/organization/\`), or into Beads memories (\`bd remember\`) when the team's tracker is Beads; any \`~/.claude/MEMORY.md\` on disk is personal and not consulted by intellisense
- Questions about intellisense system? See docs/live-mode.md in the intellisense repository
EOF
  CREATED_FILES+=("$CLAUDE_HOME/CLAUDE.md")
  status_line "CREATED" "~/.claude/CLAUDE.md (regenerated)"

  prune_claude_md_backups
}

# Create or update symlink safely, handling pre-existing real directories
# Backs up any real file/directory that exists at the destination
# Tracks created items for scoped rollback
create_symlink_safe() {
  local SRC="$1"
  local DST="$2"
  local LABEL="$3"

  if [ -L "$DST" ]; then
    # Path is already a symlink
    local CURRENT_TARGET
    CURRENT_TARGET=$(readlink "$DST")
    if [ "$CURRENT_TARGET" = "$SRC" ]; then
      status_line "SKIPPED" "$LABEL (already correct)"
    else
      rm -f "$DST"
      ln -sf "$SRC" "$DST"
      CREATED_SYMLINKS+=("$DST")
      status_line "UPDATED" "$LABEL (was: $CURRENT_TARGET)"
    fi
  elif [ -e "$DST" ]; then
    # Path exists as a real file or directory — backup and replace.
    # Backups are written to ~/.intellisense-backups/ (NOT a sibling of $DST) so they
    # never land inside ~/.claude-intellisense/, ~/.claude/, or any other path that
    # Claude Code auto-loads, where they would be read into every session.
    mkdir -p "$INTELLISENSE_BACKUPS_DIR"
    local BACKUP="$INTELLISENSE_BACKUPS_DIR/$(basename "$DST").bak-$(date +%Y%m%d%H%M%S)"
    mv "$DST" "$BACKUP"
    ln -sf "$SRC" "$DST"
    BACKED_UP_ITEMS+=("$DST|$BACKUP")
    CREATED_SYMLINKS+=("$DST")
    echo -e "  ${YELLOW}[BACKED UP]${NC}  $LABEL"
    echo -e "  ${DIM}  Original saved to: $BACKUP${NC}"
    status_line "CREATED" "$LABEL (replaced existing — review backup if needed)"
  else
    # Path doesn't exist — clean create
    ln -sf "$SRC" "$DST"
    CREATED_SYMLINKS+=("$DST")
    status_line "CREATED" "$LABEL"
  fi
}

# Detect or install code-review-graph at the pinned version (only with --code-intel code-review-graph).
#
# Semantics once the graph was chosen (HARD-FAIL at global level):
#   - Every intellisense developer must have code-review-graph==$CRG_REQUIRED_VERSION.
#   - On success, sets CRG_CMD/CRG_ARGS (consumed by configure_mcp in the SAME
#     process). Setup-repos.sh and graph-bootstrap.sh re-detect installation
#     state independently when run later — no inter-process flag is exported.
#   - On failure (all install paths exhausted), prints remediation and returns
#     non-zero. The Step 17 call site MUST exit 1 on a non-zero return.
#   - setup-repos.sh continues to enforce the per-repo graph readiness gate
#     for intellisense-managed mandatory-supported repos.
#
# Three install paths, tried in order:
#   1. Already installed at the required version → use as-is.
#   2. uv tool install (modern; replaces ad-hoc uvx serve patterns).
#   3. pipx install (canonical isolated install).
#   4. pip install --user (last-resort fallback for environments without pipx/uv).
#
# Floor pin: code-review-graph==2.3.2. Update only in coordination with:
#   - scripts/lib/intellisense-graph.sh (intellisense_graph_required_version)
#   - rules/operational/intelligence-sources.md (Provider configuration table)

CRG_CMD=""
CRG_ARGS=""
CRG_REQUIRED_VERSION="2.3.2"

# ----------------------------------------------------------------------------
# Beads (bd) pinning. Mirrors the CRG discipline: every intellisense developer runs
# the same bd version so artifact validation in the pre-push hook is consistent
# across the fleet. SHA256s sourced from the upstream
# https://github.com/gastownhall/beads/releases/download/v$BD_REQUIRED_VERSION/checksums.txt
# Update only in coordination with rules/operational that reference bd
# behavior. Do not relax the SHA check.
# ----------------------------------------------------------------------------
BD_REQUIRED_VERSION="1.0.3"
BD_SHA256_DARWIN_AMD64="6bd75ac056288a5e8bbb203750e95af5a441d5ad1d20ca5511e60cd6c813e54b"
BD_SHA256_DARWIN_ARM64="fe6e4465751f46d9f3a670c3cf656714a171e44c8bc318fe19054f513b8306ed"
BD_SHA256_LINUX_AMD64="1ef5dca818d7e81574df9e9f9fc2a16ab711da09b0fa7b822ae162d9a81c8912"
BD_SHA256_LINUX_ARM64="243a9c75012e794888fcafb957e7624b8fefdfef033d14cd03ebc9831c3bc12f"

# Helper: extract semver-shaped token from `code-review-graph --version` output.
_crg_extract_version() {
  code-review-graph --version 2>&1 | head -1 \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z0-9._-]*)?' \
    | head -1
}

# Helper: print remediation block for missing/wrong-version install.
_crg_print_remediation() {
  cat <<EOF
✗ code-review-graph could not be installed automatically.

  Code intelligence code-review-graph requires code-review-graph==$CRG_REQUIRED_VERSION (pinned).
  Setup is aborting — every intellisense developer must have this binary installed.

  Install options (any one of the four):
    1. Modern uv (recommended):
         pip install uv
         uv tool install code-review-graph==$CRG_REQUIRED_VERSION

    2. pipx (isolated Python tools):
         brew install pipx       # macOS
         pipx install code-review-graph==$CRG_REQUIRED_VERSION

    3. pip --user (last resort):
         python3 -m pip install --user code-review-graph==$CRG_REQUIRED_VERSION

    4. Brew-bootstrap (no Python runner installed yet, macOS only):
         brew install pipx       # bootstraps the Python tool runner
         pipx ensurepath
         exec "\$SHELL"          # reload PATH
         bash setup.sh           # re-run; setup.sh now picks pipx and installs CRG

  Then add ~/.local/bin to PATH (if not already), and re-run:
    bash setup.sh

  IT prerequisites: Python >= 3.10. Locked-down corporate environments may
  need IT to whitelist pip --user or install pipx system-wide.
EOF
}

# Helper: bootstrap a Python tool runner (pipx) via Homebrew when neither uv
# nor pipx is on PATH but brew is. Some macOS dev machines (especially corp-
# locked-down) ship without uv/pipx, and pip3 hits PEP 668
# externally-managed-environment errors. Brew bootstraps the runner; the
# existing Step 3 (pipx install) below then installs code-review-graph.
#
# Idempotent: returns 0 silently when a runner is already present (no
# bootstrap needed) or when brew is unavailable (no bootstrap possible).
# Returns 1 only when bootstrap was attempted and failed — caller treats
# this as a soft warning and falls through to the remaining install paths
# / remediation block.
_crg_bootstrap_runner_via_pkg_manager() {
  if command -v uv &>/dev/null || command -v pipx &>/dev/null; then
    return 0
  fi
  # Linux without brew: try the OS package manager. These paths typically
  # require sudo; if sudo is non-interactive-friendly (NOPASSWD or cached
  # credentials) they install silently. Otherwise the prompt is visible to
  # the user, who can either authorize or Ctrl-C and install pipx manually.
  # We only attempt this when uname is Linux to avoid surprising macOS users.
  if [ "$(uname -s)" = "Linux" ]; then
    if command -v apt-get &>/dev/null; then
      echo "→ Neither uv nor pipx detected. Trying apt-get install pipx..."
      if sudo -n true 2>/dev/null || [ "$EUID" = "0" ]; then
        if sudo apt-get update -y >/dev/null 2>&1 && sudo apt-get install -y pipx 2>&1 | tail -3; then
          hash -r 2>/dev/null || true
          if command -v pipx &>/dev/null; then
            echo "✓ pipx installed via apt-get."
            pipx ensurepath >/dev/null 2>&1 || true
            export PATH="$HOME/.local/bin:$PATH"
            return 0
          fi
        fi
      else
        echo "  ⚠ sudo requires a password and we're non-interactive — skipping apt-get install."
        echo "    Run manually: sudo apt-get install -y pipx"
      fi
    elif command -v dnf &>/dev/null; then
      echo "→ Neither uv nor pipx detected. Trying dnf install pipx..."
      if sudo -n true 2>/dev/null || [ "$EUID" = "0" ]; then
        if sudo dnf install -y pipx 2>&1 | tail -3; then
          hash -r 2>/dev/null || true
          if command -v pipx &>/dev/null; then
            echo "✓ pipx installed via dnf."
            pipx ensurepath >/dev/null 2>&1 || true
            export PATH="$HOME/.local/bin:$PATH"
            return 0
          fi
        fi
      else
        echo "  ⚠ sudo requires a password and we're non-interactive — skipping dnf install."
        echo "    Run manually: sudo dnf install -y pipx"
      fi
    fi
  fi
  # macOS / Linux-with-brew path: bootstrap pipx via Homebrew.
  if ! command -v brew &>/dev/null; then
    return 0
  fi
  echo "→ Neither uv nor pipx detected. Bootstrapping pipx via Homebrew..."

  # Resolve the actual brew prefix at runtime instead of hardcoding paths.
  # This makes the helper portable across:
  #   • macOS Apple Silicon  → /opt/homebrew
  #   • macOS Intel          → /usr/local
  #   • Linuxbrew (default)  → /home/linuxbrew/.linuxbrew
  #   • Custom HOMEBREW_PREFIX → whatever the user set
  # If brew is on PATH but `brew --prefix` fails (corrupted install), bail
  # out with a clear warning rather than installing into a path we can't
  # locate.
  local brew_prefix
  brew_prefix="$(brew --prefix 2>/dev/null)"
  if [ -z "$brew_prefix" ] || [ ! -d "$brew_prefix" ]; then
    echo "⚠ brew is on PATH but 'brew --prefix' did not return a usable directory."
    echo "  Falling through to remaining install paths."
    return 1
  fi

  if brew install pipx 2>&1 | tail -3; then
    hash -r 2>/dev/null || true
    # Add resolved brew prefix bin + the standard pipx user bin to PATH for
    # the rest of this setup run. ~/.local/bin is where `pipx ensurepath`
    # adds its tool shims; brew_prefix/bin is where pipx itself was
    # installed.
    export PATH="$HOME/.local/bin:$brew_prefix/bin:$PATH"
    if command -v pipx &>/dev/null; then
      echo "✓ pipx installed via Homebrew (prefix: $brew_prefix)."
      echo "  Falling through to pipx install path."
      pipx ensurepath >/dev/null 2>&1 || true
      return 0
    fi
    echo "⚠ brew install pipx ran but pipx not found at $brew_prefix/bin."
    echo "  Falling through to remaining install paths."
    return 1
  fi
  echo "⚠ brew install pipx failed. Falling through to remaining install paths."
  return 1
}

detect_or_install_code_review_graph() {
  echo "→ Checking for code-review-graph (required: ==$CRG_REQUIRED_VERSION)..."
  export PATH="$HOME/.local/bin:$PATH"

  # Step 1: already installed at the right version?
  if command -v code-review-graph &>/dev/null; then
    local actual
    actual="$(_crg_extract_version)"
    if [ "$actual" = "$CRG_REQUIRED_VERSION" ]; then
      CRG_CMD="code-review-graph"
      CRG_ARGS='["serve"]'
      echo "✓ code-review-graph $actual already installed at required version"
      return 0
    fi
    echo "⚠ code-review-graph installed at $actual; required $CRG_REQUIRED_VERSION. Will attempt upgrade."
  fi

  # Step 1.5: brew-bootstrap a Python tool runner if neither uv nor pipx is
  # present and brew is available. No-op when a runner already exists or when
  # brew is not on PATH. Soft-fail: if bootstrap fails, fall through to the
  # remaining install paths so devs with custom Python setups aren't blocked.
  _crg_bootstrap_runner_via_pkg_manager || true

  # Step 2: uv tool install (modern; preferred when uv is available)
  if command -v uv &>/dev/null; then
    echo "→ Installing via 'uv tool install'..."
    if uv tool install --force "code-review-graph==$CRG_REQUIRED_VERSION" 2>&1 | tail -5; then
      hash -r 2>/dev/null || true
      export PATH="$HOME/.local/bin:$PATH"
      if command -v code-review-graph &>/dev/null && [ "$(_crg_extract_version)" = "$CRG_REQUIRED_VERSION" ]; then
        CRG_CMD="code-review-graph"
        CRG_ARGS='["serve"]'
        echo "✓ code-review-graph $CRG_REQUIRED_VERSION installed via uv tool"
        return 0
      fi
    fi
    echo "⚠ uv tool install did not yield a working binary. Falling through."
  fi

  # Step 3: pipx install
  if command -v pipx &>/dev/null; then
    echo "→ Installing via pipx..."
    # --force replaces any other installed version.
    if pipx install --force "code-review-graph==$CRG_REQUIRED_VERSION" 2>&1 | tail -5; then
      hash -r 2>/dev/null || true
      export PATH="$HOME/.local/bin:$PATH"
      if command -v code-review-graph &>/dev/null && [ "$(_crg_extract_version)" = "$CRG_REQUIRED_VERSION" ]; then
        CRG_CMD="code-review-graph"
        CRG_ARGS='["serve"]'
        echo "✓ code-review-graph $CRG_REQUIRED_VERSION installed via pipx"
        return 0
      fi
    fi
    echo "⚠ pipx install did not yield a working binary. Falling through."
  fi

  # Step 4: pip install --user (last resort)
  local pip_cmd=""
  if command -v pip3 &>/dev/null; then
    pip_cmd="pip3"
  elif command -v pip &>/dev/null; then
    pip_cmd="pip"
  fi
  if [ -n "$pip_cmd" ]; then
    echo "→ Installing via $pip_cmd install --user..."
    if "$pip_cmd" install --user --upgrade "code-review-graph==$CRG_REQUIRED_VERSION" 2>&1 | tail -5; then
      hash -r 2>/dev/null || true
      export PATH="$HOME/.local/bin:$PATH"
      if command -v code-review-graph &>/dev/null && [ "$(_crg_extract_version)" = "$CRG_REQUIRED_VERSION" ]; then
        CRG_CMD="code-review-graph"
        CRG_ARGS='["serve"]'
        echo "✓ code-review-graph $CRG_REQUIRED_VERSION installed via $pip_cmd --user"
        return 0
      fi
    fi
    echo "⚠ $pip_cmd install --user did not yield a working binary."
  fi

  # All paths exhausted — abort. Caller must exit 1.
  _crg_print_remediation
  return 1
}

# Write MCP config only when CRG_CMD is set (i.e. a usable command was found/installed).
# Repairs stale configs (e.g., "npx" → "code-review-graph" or "uvx").
# Preserves valid existing configs (code-review-graph or uvx with "serve" arg).
configure_mcp() {
  if [ -z "$CRG_CMD" ]; then
    echo "  ℹ Skipping MCP config — code-review-graph not available"
    return 0
  fi

  local settings="$HOME/.claude/settings.json"

  if [ ! -f "$settings" ]; then
    echo '{}' > "$settings"
  fi

  if command -v jq &>/dev/null; then
    # Check if code-review-graph config exists and validate it
    local EXISTING_CMD=""
    local EXISTING_ARGS=""
    if jq -e '.mcpServers["code-review-graph"]' "$settings" &>/dev/null; then
      EXISTING_CMD=$(jq -r '.mcpServers["code-review-graph"].command' "$settings")
      EXISTING_ARGS=$(jq -r '.mcpServers["code-review-graph"].args | @json' "$settings")

      # Check if existing config is stale (uses "npx" or missing "serve")
      local IS_STALE=false
      if [ "$EXISTING_CMD" = "npx" ]; then
        IS_STALE=true
      elif [ "$EXISTING_CMD" = "code-review-graph" ] && ! echo "$EXISTING_ARGS" | grep -q "serve"; then
        IS_STALE=true
      elif [ "$EXISTING_CMD" = "uvx" ] && ! echo "$EXISTING_ARGS" | grep -q "serve"; then
        IS_STALE=true
      elif [ "$EXISTING_CMD" = "uvx" ] && [ "$CRG_CMD" = "code-review-graph" ]; then
        # verify-setup.sh's graph check requires code-review-graph directly on PATH. When the binary
        # is available at the pinned version (CRG_CMD detected as direct),
        # rewrite uvx → direct so verify agrees. If the binary isn't
        # available CRG_CMD stays "uvx" and we leave the user's config alone.
        IS_STALE=true
      fi

      # If not stale, keep existing config
      if [ "$IS_STALE" = false ]; then
        echo "✓ code-review-graph already in settings.json (command: $EXISTING_CMD, valid config)"
        return 0
      fi
      # If stale, fall through to update
    fi

    # Write or update config with PATH env var
    local tmp=$(mktemp)
    jq --arg cmd "$CRG_CMD" --argjson args "$CRG_ARGS" \
      '.mcpServers["code-review-graph"] = {
        "command": $cmd,
        "args": $args,
        "env": {
          "PATH": "'$HOME'/.local/bin:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/usr/bin:/bin"
        }
      }' \
      "$settings" > "$tmp" && mv "$tmp" "$settings"
    echo "✓ code-review-graph configured in ~/.claude/settings.json (command: $CRG_CMD)"
  else
    echo "⚠ jq not found — cannot safely merge settings.json"
    echo "  Install jq and re-run setup, or manually add:"
    printf '  { "mcpServers": { "code-review-graph": { "command": "%s", "args": %s } } }\n' "$CRG_CMD" "$CRG_ARGS"
  fi
}

# Strict verification — gates Step 17. Returns non-zero on any failure mode.
# Confirms the installed binary version exactly matches the pin.
verify_code_review_graph() {
  if [ -z "$CRG_CMD" ]; then
    echo "✗ FAILED (internal: install detection produced empty CRG_CMD)"
    return 1
  fi

  if ! command -v code-review-graph &>/dev/null; then
    echo "✗ code-review-graph not on PATH (was set up but no longer runnable; PATH issue?)"
    return 1
  fi

  local actual
  actual="$(_crg_extract_version)"
  if [ "$actual" = "$CRG_REQUIRED_VERSION" ]; then
    echo "✓ code-review-graph verified: $actual (matches the pin)"
    return 0
  elif [ -n "$actual" ]; then
    echo "✗ code-review-graph version drift: installed=$actual, required=$CRG_REQUIRED_VERSION"
    echo "  Re-run setup.sh to upgrade; or update the pin (Platform Owner action)."
    return 1
  else
    echo "✗ code-review-graph --version did not return a parseable version"
    return 1
  fi
}

# ----------------------------------------------------------------------------
# Beads (bd) install + verify. Mirrors the CRG pattern (detect → install via
# preferred path → verify pinned version), but the install paths differ
# because bd ships prebuilt OS/arch binaries rather than Python wheels.
#
# Install order:
#   1. bd already on PATH at the pinned version → use as-is.
#   2. Homebrew available (macOS / Linuxbrew) → brew install / upgrade beads.
#      Then version-check — if brew installed a different version (latest may
#      have moved past our pin), fall through to deterministic download.
#   3. Deterministic GitHub-release tarball download to ~/.local/bin/bd:
#      verifies SHA256 against the BD_SHA256_<OS>_<ARCH> pin before installing.
#      Works on Linux without brew and on locked-down corp machines (no sudo).
#   4. All paths exhausted → hard-fail with remediation block.
#
# Defense-in-depth: verify_beads() runs after install and exits non-zero if
# `bd version` does not exactly equal BD_REQUIRED_VERSION. Drift fails setup.
# ----------------------------------------------------------------------------

# Extract semver from `bd version` output (e.g. "bd version 1.0.3 (Homebrew)").
# stderr is dropped: bd writes a "Warning: multiple 'bd' binaries found in PATH"
# message to stderr when duplicates exist; merging streams (2>&1) lets that
# warning land on line 1 due to buffering order and zero out the parse. The
# version line is always on stdout.
_bd_extract_version() {
  bd version 2>/dev/null | head -1 \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z0-9._-]*)?' \
    | head -1
}

# Map uname -s / uname -m to the asset suffix used in the upstream release URL.
# Returns "" on unsupported platforms (caller hard-fails).
_bd_platform_suffix() {
  local os arch
  case "$(uname -s)" in
    Darwin) os="darwin" ;;
    Linux)  os="linux"  ;;
    *)      echo ""; return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)   arch="amd64" ;;
    arm64|aarch64)  arch="arm64" ;;
    *)              echo ""; return 1 ;;
  esac
  echo "${os}_${arch}"
}

# Look up the expected SHA256 for the current platform.
_bd_expected_sha256() {
  case "$1" in
    darwin_amd64) echo "$BD_SHA256_DARWIN_AMD64" ;;
    darwin_arm64) echo "$BD_SHA256_DARWIN_ARM64" ;;
    linux_amd64)  echo "$BD_SHA256_LINUX_AMD64"  ;;
    linux_arm64)  echo "$BD_SHA256_LINUX_ARM64"  ;;
    *)            echo ""                         ;;
  esac
}

# Compute SHA256 using whatever's available. macOS has shasum by default;
# Linux usually has sha256sum; both ship openssl. Returns "" on no tool.
_bd_compute_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 "$file" | awk '{print $NF}'
  else
    echo ""
  fi
}

_bd_print_remediation() {
  cat <<EOF
✗ bd (beads) could not be installed automatically at version $BD_REQUIRED_VERSION.

  intellisense requires bd==$BD_REQUIRED_VERSION pinned across the fleet so pre-push
  artifact validation is consistent for every developer.

  Install options (any one):
    1. Homebrew (macOS / Linuxbrew):
         brew install beads

    2. Direct binary download (Linux without brew, locked-down environments):
         mkdir -p ~/.local/bin
         curl -fsSL https://github.com/gastownhall/beads/releases/download/v$BD_REQUIRED_VERSION/beads_${BD_REQUIRED_VERSION}_\$(uname -s | tr A-Z a-z)_\$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/').tar.gz \\
           | tar -xz -C /tmp && mv /tmp/bd ~/.local/bin/bd && chmod +x ~/.local/bin/bd

    3. Upstream installer (last resort — installs latest, not the intellisense pin):
         curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | bash

  Then ensure ~/.local/bin is on PATH and re-run:
    bash setup.sh
EOF
}

detect_or_install_bd() {
  echo "→ Checking for bd (required: ==$BD_REQUIRED_VERSION)..."
  export PATH="$HOME/.local/bin:$PATH"

  # Step 1: already installed at the pinned version?
  if command -v bd >/dev/null 2>&1; then
    local actual
    actual="$(_bd_extract_version)"
    if [ "$actual" = "$BD_REQUIRED_VERSION" ]; then
      status_line "SKIPPED" "bd already at $actual (matches intellisense pin)"
      return 0
    fi
    echo "  bd installed at $actual; required $BD_REQUIRED_VERSION. Will attempt to install pinned version."
  fi

  # Step 2: Homebrew path. brew installs latest, so we still version-check
  # after install and fall through to deterministic download on mismatch.
  if command -v brew >/dev/null 2>&1; then
    local brew_log
    brew_log="$(mktemp)"
    echo "  Installing beads via Homebrew (log: $brew_log)..."
    if brew install beads >"$brew_log" 2>&1 || brew upgrade beads >>"$brew_log" 2>&1; then
      hash -r 2>/dev/null || true
      # Ensure brew's bin is reachable in this process (Apple Silicon first-run
      # gap: brew shellenv may not be loaded yet).
      local brew_prefix
      brew_prefix="$(brew --prefix 2>/dev/null)"
      if [ -n "$brew_prefix" ] && [ -d "$brew_prefix/bin" ]; then
        case ":$PATH:" in
          *":$brew_prefix/bin:"*) ;;
          *) export PATH="$brew_prefix/bin:$PATH" ;;
        esac
      fi
      if command -v bd >/dev/null 2>&1; then
        local actual
        actual="$(_bd_extract_version)"
        if [ "$actual" = "$BD_REQUIRED_VERSION" ]; then
          status_line "CREATED" "bd $actual installed via Homebrew (matches intellisense pin)"
          return 0
        fi
        echo "  ⚠ brew installed bd $actual; intellisense pin is $BD_REQUIRED_VERSION. Falling through to deterministic download."
      fi
    else
      echo "  ⚠ brew install/upgrade beads failed (last 10 lines):"
      tail -10 "$brew_log" | sed 's/^/      /'
      echo "    Falling through to deterministic download."
    fi
  fi

  # Step 3: deterministic GitHub-release tarball download with SHA256 verify.
  local suffix
  suffix="$(_bd_platform_suffix)" || true
  if [ -z "$suffix" ]; then
    echo "  ⚠ Unsupported OS/arch ($(uname -s) $(uname -m)); cannot use direct-download path."
    _bd_print_remediation
    return 1
  fi
  local expected_sha
  expected_sha="$(_bd_expected_sha256 "$suffix")"
  if [ -z "$expected_sha" ]; then
    echo "  ⚠ No SHA256 pin recorded for $suffix; cannot verify download. Update setup.sh."
    _bd_print_remediation
    return 1
  fi

  local url tmpdir tarball actual_sha
  url="https://github.com/gastownhall/beads/releases/download/v${BD_REQUIRED_VERSION}/beads_${BD_REQUIRED_VERSION}_${suffix}.tar.gz"
  tmpdir="$(mktemp -d)"
  tarball="$tmpdir/beads.tar.gz"
  echo "  Downloading bd $BD_REQUIRED_VERSION ($suffix) from upstream releases..."
  if ! curl -fsSL "$url" -o "$tarball"; then
    echo -e "  ${RED}✗ Download failed: $url${NC}"
    rm -rf "$tmpdir"
    _bd_print_remediation
    return 1
  fi
  actual_sha="$(_bd_compute_sha256 "$tarball")"
  if [ -z "$actual_sha" ]; then
    echo -e "  ${RED}✗ No SHA256 tool available (need sha256sum / shasum / openssl).${NC}"
    rm -rf "$tmpdir"
    return 1
  fi
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo -e "  ${RED}✗ SHA256 mismatch — refusing to install unverified binary.${NC}"
    echo "    expected: $expected_sha"
    echo "    actual:   $actual_sha"
    echo "    url:      $url"
    rm -rf "$tmpdir"
    return 1
  fi
  if ! tar -xzf "$tarball" -C "$tmpdir"; then
    echo -e "  ${RED}✗ tar extraction failed${NC}"
    rm -rf "$tmpdir"
    return 1
  fi
  local extracted_bd="$tmpdir/bd"
  if [ ! -f "$extracted_bd" ]; then
    # Some releases nest the binary inside a versioned dir. Probe for it.
    extracted_bd="$(find "$tmpdir" -maxdepth 3 -name bd -type f -perm -u+x 2>/dev/null | head -1)"
  fi
  if [ -z "$extracted_bd" ] || [ ! -f "$extracted_bd" ]; then
    echo -e "  ${RED}✗ Could not locate 'bd' binary inside the tarball.${NC}"
    rm -rf "$tmpdir"
    return 1
  fi
  mkdir -p "$HOME/.local/bin"
  mv "$extracted_bd" "$HOME/.local/bin/bd"
  chmod +x "$HOME/.local/bin/bd"
  rm -rf "$tmpdir"
  hash -r 2>/dev/null || true
  export PATH="$HOME/.local/bin:$PATH"

  if ! command -v bd >/dev/null 2>&1; then
    echo -e "  ${RED}✗ bd installed at $HOME/.local/bin/bd but not on PATH.${NC}"
    echo "    Add to your shell init: export PATH=\"\$HOME/.local/bin:\$PATH\""
    return 1
  fi
  local actual
  actual="$(_bd_extract_version)"
  if [ "$actual" = "$BD_REQUIRED_VERSION" ]; then
    status_line "CREATED" "bd $actual installed via deterministic download (SHA256 verified, intellisense pin)"
    return 0
  fi
  echo -e "  ${RED}✗ Installed bd reports version '$actual'; expected '$BD_REQUIRED_VERSION'.${NC}"
  _bd_print_remediation
  return 1
}

# Strict verification — gates the Step 16 chain. Returns non-zero on drift.
verify_beads() {
  if ! command -v bd >/dev/null 2>&1; then
    echo "✗ bd not on PATH after install (PATH issue?)"
    return 1
  fi
  local actual
  actual="$(_bd_extract_version)"
  if [ "$actual" = "$BD_REQUIRED_VERSION" ]; then
    echo "✓ bd verified: $actual (matches intellisense pin)"
    return 0
  elif [ -n "$actual" ]; then
    echo "✗ bd version drift: installed=$actual, required=$BD_REQUIRED_VERSION"
    echo "  Re-run setup.sh to upgrade; or update the pin (Platform Owner action)."
    return 1
  else
    echo "✗ bd version could not be parsed"
    return 1
  fi
}

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  intellisense Setup — Developer Global Configuration${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  ${DIM}INTELLISENSE_SETUP : $SCRIPT_DIR${NC}"
echo -e "  ${DIM}Claude Home: $CLAUDE_HOME${NC}"
echo ""

echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│  What intellisense will create:                                  │${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│  ~/.claude/                                                 │${NC}"
echo -e "${CYAN}│    rules/baseline/      → symlink → INTELLISENSE_SETUP/rules/       │${NC}"
echo -e "${CYAN}│    skills/              → symlink → INTELLISENSE_SETUP/skills/      │${NC}"
echo -e "${CYAN}│    agents/              → symlink → INTELLISENSE_SETUP/agents/      │${NC}"
echo -e "${CYAN}│    templates/           → symlink → INTELLISENSE_SETUP/templates/   │${NC}"
echo -e "${CYAN}│    infrastructure/      → symlink → INTELLISENSE_SETUP/infra/       │${NC}"
echo -e "${CYAN}│    service-map.md       → symlink                           │${NC}"
echo -e "${CYAN}│    CLAUDE.md            → generated (unique per developer)  │${NC}"
echo -e "${CYAN}│    MEMORY.md            → deprecation stub (intellisense memory now in beads) │${NC}"
echo -e "${CYAN}│    config.json          → generated                         │${NC}"
echo -e "${CYAN}│    INTELLISENSE_README.md    → intellisense marker/legend             │${NC}"
echo -e "${CYAN}│    .intellisense-initialized → setup marker                      │${NC}"
echo -e "${CYAN}│  ~/.intellisense/rules/                                  │${NC}"
echo -e "${CYAN}│    language-specific/ + operational/               → symlinks│${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}│  Required tools (installed/verified — hard-fail if missing):│${NC}"
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│  beads (bd)              → task tracking + pre-push gating  │${NC}"
echo -e "${CYAN}│                            (Homebrew install if absent)     │${NC}"
echo -e "${CYAN}│  code-review-graph $CRG_REQUIRED_VERSION → graph-native code intelligence (MCP) │${NC}"
echo -e "${CYAN}│                            (uv / pipx / pip — pinned)       │${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""

# Handle --refresh-global-claude flag (early exit if set)
if [ "$REFRESH_GLOBAL_CLAUDE" = true ]; then
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  Updating Rules Loading Strategy${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  if [ ! -f "$CLAUDE_HOME/CLAUDE.md" ]; then
    echo -e "${RED}ERROR: ~/.claude/CLAUDE.md not found. Run full setup first.${NC}"
    exit 1
  fi

  # Write content to temporary file
  CONTENT_TEMP_FILE=$(mktemp)
  generate_rules_loading_strategy > "$CONTENT_TEMP_FILE"

  # Try to update using managed markers
  if update_managed_block "$CLAUDE_HOME/CLAUDE.md" "rules-loading-strategy" "$CONTENT_TEMP_FILE"; then
    echo -e "  ${GREEN}[UPDATED]${NC} Rules Loading Strategy (using managed markers)"
  else
    # First migration — markers don't exist yet, add them
    echo -e "  ${YELLOW}[FIRST-MIGRATION]${NC} Adding managed markers to Rules Loading Strategy"
    replace_section_with_markers "$CLAUDE_HOME/CLAUDE.md" "## Rules Loading Strategy" "## Global Skills Available" "$CONTENT_TEMP_FILE"
    echo -e "  ${GREEN}[UPDATED]${NC} Rules Loading Strategy (markers inserted for future updates)"
  fi

  rm -f "$CONTENT_TEMP_FILE"
  echo ""
  echo -e "${GREEN}✓ Rules Loading Strategy updated in ~/.claude/CLAUDE.md${NC}"
  echo ""
  exit 0
fi

if $INTERACTIVE; then
  read -p "Proceed? (yes/no) [yes]: " CONFIRM_SETUP
  CONFIRM_SETUP=${CONFIRM_SETUP:-yes}
  if [ "$CONFIRM_SETUP" != "yes" ]; then
    echo -e "${YELLOW}Setup cancelled.${NC}"
    exit 0
  fi
fi
echo ""

# Check version and determine if we can skip setup steps
echo -e "${BLUE}→ Version Check${NC}"
check_version
if [ "$VERSION_MISMATCH" = true ] && $INTERACTIVE; then
  echo -e "${YELLOW}Proceeding with upgrade. Use --force in non-interactive mode to skip confirmation.${NC}"
  SKIP_SETUP_STEPS=false
fi
echo ""

# Skip remaining setup if version matches and user confirms
if [ "$SKIP_SETUP_STEPS" = true ]; then
  echo -e "${GREEN}✓ Setup already complete at v$INTELLISENSE_VERSION${NC}"
  echo -e "${DIM}Running validation only...${NC}"
  # Run only validation steps (14-16), skip steps 1-13
  SKIP_TO_VALIDATION=true
fi


# Steps 1-13: Skip if version matches (incremental setup)
if [ "$SKIP_TO_VALIDATION" = true ]; then
  echo -e "${DIM}Skipping steps 1-13 (version match). Proceeding to validation...${NC}"
  # intellisense owns ~/.claude/CLAUDE.md — regenerate even on the version-match path
  # so a missing/corrupted file self-heals. The function backs up any prior
  # copy to $INTELLISENSE_BACKUPS_DIR/CLAUDE.bak-<ts> and prunes to the newest 3.
  echo -e "${BLUE}→ Refresh global CLAUDE.md${NC}"
  regenerate_global_claude_md
  # Also refresh settings.json on the version-match path: the template can gain
  # hook entries between releases that share the same VERSION.
  echo -e "${BLUE}→ Refresh ~/.claude/settings.json (merge intellisense keys)${NC}"
  regenerate_settings_json
  # NOTE: heartbeat token + cron are refreshed unconditionally by the heartbeat step
  # (below, after this if/else closes), which runs on BOTH the fast path and
  # the full install. Do NOT add an install_heartbeat_* call here: the install
  # (and its interactive "GitHub username:" prompt) would fire twice. The
  # heartbeat step enforces the required token via its own `exit 1`.
else
  # Step 1: Create base ~/.claude directory
  echo -e "${BLUE}→ Step 1: Create ~/.claude directory${NC}"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Would create ~/.claude${NC}"
  else
    mkdir -p "$CLAUDE_HOME"
    status_line "CREATED" "~/.claude"
    fi

  echo -e "${BLUE}→ Step 2: Generate config.json${NC}"
  if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}[DRY-RUN] Would create ~/.claude/config.json${NC}"
  else
    cat > "$CLAUDE_HOME/config.json" << EOF
{
  "intellisense_setup_path": "$SCRIPT_DIR",
  "intellisense_home_path": "$HOME/.intellisense",
  "home": "$HOME",
  "version": "$INTELLISENSE_VERSION",
  "created": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "managed_by": "intellisense",
  "managed_dirs": ["rules/baseline", "skills", "agents", "templates", "infrastructure"],
  "repos_base": "",
  "note": "This stores the path to INTELLISENSE_SETUP master repo. All rules/skills/agents are symlinked from there."
}
EOF
    CREATED_FILES+=("$CLAUDE_HOME/config.json")
    status_line "CREATED" "~/.claude/config.json"
  fi

  echo -e "${BLUE}→ Step 2b: Generate or merge settings.json from template${NC}"
  regenerate_settings_json

  echo -e "${BLUE}→ Step 3: Create symlinks to rules${NC}"
  INTELLISENSE_HOME="$HOME/.intellisense"

  # ~/.claude/rules/ — ONLY baseline (auto-loaded by Claude Code)
  [ -d "$SCRIPT_DIR/rules/baseline" ] || { echo -e "${RED}ERROR: source $SCRIPT_DIR/rules/baseline missing${NC}"; exit 1; }
  mkdir -p "$CLAUDE_HOME/rules"

  create_symlink_safe "$SCRIPT_DIR/rules/baseline" "$CLAUDE_HOME/rules/baseline" "~/.claude/rules/baseline"

  # ~/.intellisense/rules/ — on-demand rules (NOT auto-loaded by Claude Code)
  [ -d "$SCRIPT_DIR/rules/language-specific" ] || { echo -e "${RED}ERROR: source $SCRIPT_DIR/rules/language-specific missing${NC}"; exit 1; }
  [ -d "$SCRIPT_DIR/rules/operational" ] || { echo -e "${RED}ERROR: source $SCRIPT_DIR/rules/operational missing${NC}"; exit 1; }
  mkdir -p "$INTELLISENSE_HOME/rules"

  for RULE_DIR in language-specific operational; do
    create_symlink_safe "$SCRIPT_DIR/rules/$RULE_DIR" "$INTELLISENSE_HOME/rules/$RULE_DIR" "~/.intellisense/rules/$RULE_DIR"
  done

  echo -e "${BLUE}→ Step 4: Create symlink to skills${NC}"
  [ -d "$SCRIPT_DIR/skills" ] || { echo -e "${RED}ERROR: source $SCRIPT_DIR/skills missing${NC}"; exit 1; }
  create_symlink_safe "$SCRIPT_DIR/skills" "$CLAUDE_HOME/skills" "~/.claude/skills"

  echo -e "${BLUE}→ Step 5: Create symlink to agents${NC}"
  [ -d "$SCRIPT_DIR/agents" ] || { echo -e "${RED}ERROR: source $SCRIPT_DIR/agents missing${NC}"; exit 1; }
  create_symlink_safe "$SCRIPT_DIR/agents" "$CLAUDE_HOME/agents" "~/.claude/agents"

  echo -e "${BLUE}→ Step 6: Create symlink to templates${NC}"
  [ -d "$SCRIPT_DIR/templates" ] || { echo -e "${RED}ERROR: source $SCRIPT_DIR/templates missing${NC}"; exit 1; }
  create_symlink_safe "$SCRIPT_DIR/templates" "$CLAUDE_HOME/templates" "~/.claude/templates"

  echo -e "${BLUE}→ Step 7: Create symlink to service-map.md${NC}"
  [ -f "$SCRIPT_DIR/infrastructure/service-map.md" ] || { echo -e "${RED}ERROR: source $SCRIPT_DIR/infrastructure/service-map.md missing${NC}"; exit 1; }
  create_symlink_safe "$SCRIPT_DIR/infrastructure/service-map.md" "$CLAUDE_HOME/service-map.md" "~/.claude/service-map.md"

  echo -e "${BLUE}→ Step 8: Create symlink to infrastructure${NC}"
  [ -d "$SCRIPT_DIR/infrastructure" ] || { echo -e "${RED}ERROR: source $SCRIPT_DIR/infrastructure missing${NC}"; exit 1; }
  create_symlink_safe "$SCRIPT_DIR/infrastructure" "$CLAUDE_HOME/infrastructure" "~/.claude/infrastructure"

  echo -e "${BLUE}→ Step 9: Create local-only directories${NC}"
  mkdir -p "$CLAUDE_HOME/teams"
  mkdir -p "$CLAUDE_HOME/projects"
  status_line "CREATED" "~/.claude/teams"
  status_line "CREATED" "~/.claude/projects"

  echo -e "${BLUE}→ Step 10: Generate global CLAUDE.md${NC}"
  regenerate_global_claude_md

  echo -e "${BLUE}→ Step 11: intellisense memory (rules, or Beads memories; not MEMORY.md)${NC}"
  # Durable team knowledge lives in rules (repo CLAUDE.md, .intellisense/rules/organization/), or in Beads
  # memories when the tracker is Beads. intellisense never reads or writes MEMORY.md. We do NOT touch an
  # existing ~/.claude/MEMORY.md — it is the developer's. If none exists, a short note says where knowledge goes.
  if [ ! -f "$CLAUDE_HOME/MEMORY.md" ]; then
    cat > "$CLAUDE_HOME/MEMORY.md" << EOF
# MEMORY.md — not used by intellisense

intellisense does NOT read this file. Knowledge the team should share goes where every session and every agent
sees it:

- A rule for one repository: its \`CLAUDE.md\`, or \`.intellisense/rules/organization/<topic>.md\`
- With the Beads tracker: \`bd remember "insight"\` (read back with \`bd prime\` / \`bd memories <keyword>\`)

Personal notes are fine to keep below.

---

Stub written by setup.sh on $(date)
intellisense Version: $INTELLISENSE_VERSION
EOF
    CREATED_FILES+=("$CLAUDE_HOME/MEMORY.md")
    status_line "CREATED" "~/.claude/MEMORY.md (note on where team knowledge goes)"
  else
    status_line "SKIPPED" "~/.claude/MEMORY.md (exists; left untouched)"
  fi

  echo -e "${BLUE}→ Step 12: Set file permissions${NC}"
  chmod 755 "$CLAUDE_HOME/teams" 2>/dev/null || true
  chmod 644 "$CLAUDE_HOME/MEMORY.md" 2>/dev/null || true
  chmod 644 "$CLAUDE_HOME/config.json" 2>/dev/null || true
  status_line "CREATED" "File permissions set"

  # Step 13 (INTELLISENSE_README.md) moved outside the Steps 1-13 block so the
  # version-match fast path also self-heals a missing/deleted README. See
  # the unconditional block immediately after this fi.
  :
fi  # End of Steps 1-13 conditional block

# Self-heal INTELLISENSE_README.md on every setup.sh run (mirrors the
# regenerate_global_claude_md pattern at line ~1942). Without this,
# a developer who deleted the README would FAIL verify-setup.sh's
# B1 check with no path to heal it — re-running setup.sh would skip
# Step 13 on the version-match fast path.
echo -e "${BLUE}→ Step 13: Generate INTELLISENSE_README.md (self-heal)${NC}"
if [ ! -f "$CLAUDE_HOME/INTELLISENSE_README.md" ]; then
  cat > "$CLAUDE_HOME/INTELLISENSE_README.md" << EOF
# intellisense — Live mode

This ~/.claude/ directory is co-managed by **intellisense**.

## What intellisense Manages (symlinked from INTELLISENSE_SETUP)

| Item               | Purpose                                          |
|--------------------|--------------------------------------------------|
| rules/baseline/    | Coding standards, auto-loaded by Claude Code     |
| skills/            | intellisense slash commands (/plan, /tdd, /verify...) |
| agents/            | go-backend, laravel-backend, frontend agents     |
| templates/         | CLAUDE.md templates for service repos            |
| infrastructure/    | Service map and knowledge base                   |
| service-map.md     | Alias to infrastructure/service-map.md           |

## What is Native to Claude Code (NOT intellisense)

| Item              | Owned By                        |
|-------------------|---------------------------------|
| settings.json     | Claude Code native config       |
| CLAUDE.md         | Generated by intellisense, then yours|
| MEMORY.md         | Personal only — not read by intellisense        |
| projects/         | Developer-local                 |
| teams/            | Developer-local                 |

## Update intellisense Rules and Skills

    cd $SCRIPT_DIR && git pull
    (symlinks auto-resolve — no re-run needed)

Initialized: $(date) | Developer: $(whoami) | Version: 1.0
EOF
  CREATED_FILES+=("$CLAUDE_HOME/INTELLISENSE_README.md")
  status_line "CREATED" "~/.claude/INTELLISENSE_README.md"
else
  status_line "SKIPPED" "~/.claude/INTELLISENSE_README.md (already exists)"
fi

echo -e "${BLUE}→ Step 14: Verify symlinks${NC}"
SYMLINK_COUNT=0
for LINK in rules/baseline skills agents templates infrastructure service-map.md; do
    if [ -L "$CLAUDE_HOME/$LINK" ]; then
        status_line "CREATED" "$LINK"
        SYMLINK_COUNT=$((SYMLINK_COUNT + 1))
    else
        status_line "FAILED" "$LINK"
    fi
done

# Also verify intellisense symlinks
for LINK in language-specific operational; do
    if [ -L "$INTELLISENSE_HOME/rules/$LINK" ]; then
        status_line "CREATED" "~/.intellisense/rules/$LINK"
        SYMLINK_COUNT=$((SYMLINK_COUNT + 1))
    else
        status_line "FAILED" "~/.intellisense/rules/$LINK"
    fi
done

echo -e "${BLUE}→ Step 14.5: Clean up broken symlinks in all managed directories${NC}"
# Detect and remove broken symlinks in all symlinked directories
# (occurs when files/dirs are deleted in new intellisense versions)
BROKEN_COUNT=0
SYMLINKED_DIRS=(
  "$CLAUDE_HOME/rules/baseline"
  "$CLAUDE_HOME/skills"
  "$CLAUDE_HOME/agents"
  "$CLAUDE_HOME/templates"
  "$CLAUDE_HOME/infrastructure"
  "$INTELLISENSE_HOME/rules/operational"
  "$INTELLISENSE_HOME/rules/language-specific"
)

for CHECK_DIR in "${SYMLINKED_DIRS[@]}"; do
  if [ -d "$CHECK_DIR" ]; then
    # Find all symlinks that point to non-existent targets
    while IFS= read -r broken_link; do
      if [ -n "$broken_link" ]; then
        rm -f "$broken_link"
        status_line "UPDATED" "Removed broken symlink: $(basename "$broken_link")"
        BROKEN_COUNT=$((BROKEN_COUNT + 1))
      fi
    done < <(find "$CHECK_DIR" -type l ! -exec test -e {} \; -print 2>/dev/null)
  fi
done

if [ $BROKEN_COUNT -eq 0 ]; then
  status_line "SKIPPED" "No broken symlinks found in managed directories"
fi

echo -e "${BLUE}→ Step 15: Mark intellisense setup complete${NC}"
printf "intellisense Initialized: $(date)\nINTELLISENSE_SETUP_PATH=%s\nSetup by: %s\n" \
  "$SCRIPT_DIR" "$(whoami)" > "$CLAUDE_HOME/.intellisense-initialized"
CREATED_FILES+=("$CLAUDE_HOME/.intellisense-initialized")
status_line "CREATED" "~/.claude/.intellisense-initialized"

echo -e "${BLUE}→ Step 15.5: Write version tracking file${NC}"
cat > "$CLAUDE_HOME/.intellisense-version" << EOF
INTELLISENSE_VERSION=$INTELLISENSE_VERSION
INSTALLED_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
INTELLISENSE_SETUP_PATH=$SCRIPT_DIR
UPDATED_BY=$(whoami)
EOF
CREATED_FILES+=("$CLAUDE_HOME/.intellisense-version")
status_line "CREATED" "~/.claude/.intellisense-version (v$INTELLISENSE_VERSION)"

# ─── Optional integrations: ask once, record the answer ──────────────────────
if [ -z "$TRACKER" ]; then
  if $INTERACTIVE; then
    read -p "Task tracker for task references (none/github/jira/linear/beads — beads installs the bd CLI) [none]: " TRACKER
  fi
  TRACKER="${TRACKER:-none}"
fi
if [ -z "$CODE_INTEL" ]; then
  if $INTERACTIVE; then
    read -p "Code intelligence (none/code-review-graph — installs a Python tool) [none]: " CODE_INTEL
  fi
  CODE_INTEL="${CODE_INTEL:-none}"
fi
case "$TRACKER" in none|beads|github|jira|linear) ;; *) echo -e "${RED}❌ --tracker must be none, beads, github, jira or linear (got $TRACKER)${NC}"; exit 1 ;; esac
case "$CODE_INTEL" in none|code-review-graph) ;; *) echo -e "${RED}❌ --code-intel must be none or code-review-graph (got $CODE_INTEL)${NC}"; exit 1 ;; esac
if [[ "$DRY_RUN" != true ]]; then
  mkdir -p "$HOME/.intellisense"
  printf 'INTELLISENSE_TRACKER=%s\nINTELLISENSE_CODE_INTEL=%s\n' "$TRACKER" "$CODE_INTEL" > "$HOME/.intellisense/integrations.env"
fi
status_line "CONFIGURED" "tracker: $TRACKER · code intelligence: $CODE_INTEL (~/.intellisense/integrations.env)"

# ─── The engine: the Go binary every hook asks for tiers ─────────────────────
# Preference: $INTELLISENSE_BIN (set by `intellisense live install`), an `intellisense` on PATH, else build it
# from this checkout when Go is available. Without it the push hook blocks with the install command.
ENGINE_LINK="$HOME/.intellisense/bin/intellisense"
ENGINE_SRC="${INTELLISENSE_BIN:-}"
if [ -n "$ENGINE_SRC" ] && [ "$ENGINE_SRC" = "$ENGINE_LINK" ] && [ -x "$ENGINE_LINK" ]; then
  status_line "SKIPPED" "engine already linked at $ENGINE_LINK"
elif [[ "$DRY_RUN" != true ]]; then
  mkdir -p "$HOME/.intellisense/bin"
  [ -n "$ENGINE_SRC" ] && [ -x "$ENGINE_SRC" ] || ENGINE_SRC="$(command -v intellisense 2>/dev/null || true)"
  if [ -n "$ENGINE_SRC" ] && [ -x "$ENGINE_SRC" ]; then
    ln -sf "$ENGINE_SRC" "$ENGINE_LINK"
    status_line "LINKED" "$ENGINE_LINK → $ENGINE_SRC"
  elif command -v go >/dev/null 2>&1 && [ -f "$SCRIPT_DIR/go.mod" ] && (cd "$SCRIPT_DIR" && go build -o "$ENGINE_LINK" ./cmd/intellisense) 2>/dev/null; then
    status_line "BUILT" "$ENGINE_LINK from this checkout"
  else
    echo -e "${YELLOW}⚠️  intellisense engine not found: hooks will refuse pushes until it is installed.${NC}"
    echo "   Install: brew install soupler-oss/tap/intellisense   (then re-run this setup)"
  fi
fi

if [ "$TRACKER" != "beads" ]; then
echo -e "${BLUE}→ Step 16: Beads not selected (tracker: $TRACKER) — skipped${NC}"
else
echo -e "${BLUE}→ Step 16: Install / verify Beads + chain intellisense pre-push${NC}"

# Beads step 1: ensure bd is on PATH at the intellisense-pinned version. Install order is
# brew → deterministic SHA256-verified download → hard-fail. See
# detect_or_install_bd() at the top of this script for details. The verifier
# below treats version drift as a hard failure (same discipline as CRG).
if ! detect_or_install_bd; then
  echo -e "${RED}❌ bd install failed — see remediation above${NC}"
  exit 1
fi
if ! verify_beads; then
  echo -e "${RED}❌ bd verification failed — see message above${NC}"
  exit 1
fi

# Beads step 2: ensure .beads/ is gitignored BEFORE bd init.
# bd is a per-laptop task tracker; issues are not shared via git. The gitignore
# entry prevents bd's auto-commit on init and silences subsequent auto-export
# attempts. Auto-export is also disabled below as a belt-and-suspenders.
GITIGNORE="$SCRIPT_DIR/.gitignore"
if [ -f "$GITIGNORE" ] && ! grep -qE '^\.beads/?$' "$GITIGNORE"; then
  echo ".beads/" >> "$GITIGNORE"
  status_line "UPDATED" "$GITIGNORE — added .beads/ (must precede bd init)"
elif [ ! -f "$GITIGNORE" ]; then
  echo ".beads/" > "$GITIGNORE"
  status_line "CREATED" "$GITIGNORE with .beads/"
fi

# Beads step 3: bd init for INTELLISENSE_SETUP (only if no Dolt config marker exists).
if [ ! -f "$SCRIPT_DIR/.beads/config.yaml" ]; then
  echo "  Initializing Beads database for INTELLISENSE_SETUP..."
  if ! ( cd "$SCRIPT_DIR" && bd init --skip-agents --non-interactive --role maintainer ); then
    echo -e "${RED}❌ bd init failed for INTELLISENSE_SETUP${NC}"
    echo "    Investigate: cd $SCRIPT_DIR && bd init --skip-agents --non-interactive --role maintainer"
    exit 1
  fi
  # Disable auto-export — issues.jsonl is gitignored; auto-export's git-add
  # call would emit "auto-export: git add failed" on every bd write. Silent
  # failure is fine but noisy in dev terminals.
  ( cd "$SCRIPT_DIR" && bd config set export.auto false >/dev/null 2>&1 ) || true
  status_line "CREATED" ".beads/ initialized for INTELLISENSE_SETUP (auto-export disabled)"
else
  status_line "SKIPPED" ".beads/config.yaml exists in INTELLISENSE_SETUP (preserved)"
fi

# Beads step 4: install/refresh intellisense chain block in .beads/hooks/pre-push.
# bd init writes its own pre-push with BEGIN/END BEADS INTEGRATION markers.
# Append (or replace) an intellisense-managed block to chain into the real intellisense hook.
BEADS_PREPUSH="$SCRIPT_DIR/.beads/hooks/pre-push"
if [ -f "$BEADS_PREPUSH" ]; then
  if grep -q '^# --- BEGIN intellisense INTEGRATION ---$' "$BEADS_PREPUSH"; then
    sed -i.intellisensebak '/^# --- BEGIN intellisense INTEGRATION ---$/,/^# --- END intellisense INTEGRATION ---$/d' "$BEADS_PREPUSH"
    rm -f "$BEADS_PREPUSH.intellisensebak"
  fi
  cat >> "$BEADS_PREPUSH" <<EOF

# --- BEGIN intellisense INTEGRATION ---
# Managed by intellisense setup scripts. Chains intellisense's tier-validation pre-push.
# Fail-safe: missing or non-executable hook BLOCKS the push (no silent bypass).
INTELLISENSE_HOOK="$SCRIPT_DIR/hooks/pre-push"
if [ ! -f "\$INTELLISENSE_HOOK" ]; then
  echo "❌ intellisense pre-push hook missing at \$INTELLISENSE_HOOK" >&2
  echo "   Re-run: bash $SCRIPT_DIR/setup.sh" >&2
  exit 1
fi
if [ ! -x "\$INTELLISENSE_HOOK" ]; then
  echo "❌ intellisense pre-push hook not executable at \$INTELLISENSE_HOOK" >&2
  echo "   Fix: chmod +x \$INTELLISENSE_HOOK" >&2
  exit 1
fi
"\$INTELLISENSE_HOOK" "\$@"
_intellisense_exit=\$?
if [ \$_intellisense_exit -ne 0 ]; then exit \$_intellisense_exit; fi
# --- END intellisense INTEGRATION ---
EOF
  status_line "UPDATED" "$BEADS_PREPUSH — intellisense chain block refreshed (BEADS block preserved)"
else
  echo -e "${RED}❌ Expected $BEADS_PREPUSH after bd init, not found${NC}"
  exit 1
fi
fi  # tracker = beads

# Phases E and F wire the commit hooks into this platform folder's own repository, for people working on
# intellisense itself. An unpacked install (`intellisense live install`) is not a git checkout: skip them.
if ! git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  status_line "SKIPPED" "platform folder is not a git checkout — no self-hooks (onboarded repos get theirs from setup-repos.sh)"
else
# install/refresh intellisense chain block in prepare-commit-msg.
# Resolve the active hooks dir instead of hardcoding
# .beads/hooks/ — handles repos where core.hooksPath is unset or custom.
# resolve_hooks_dir is sourced from scripts/lib/hooks.sh at the top.
HOOKS_DIR_FOR_SELF="$(resolve_hooks_dir "$SCRIPT_DIR")"
BEADS_PCM="$HOOKS_DIR_FOR_SELF/prepare-commit-msg"
if [ -f "$BEADS_PCM" ]; then
  # Existing hook path: append (or refresh) the intellisense
  # INTEGRATION block. Wrapper now PROPAGATES the
  # intellisense hook's exit code instead of swallowing it with `|| echo`. prepare-commit-msg uses
  # exit 1 specifically for cursor-corruption blocks that MUST stop the
  # commit; pilot-mode trailer drift exits 0 inside prepare-commit-msg itself.
  rm -f "$BEADS_PCM.intellisense-new"
  if grep -q '^# --- BEGIN intellisense INTEGRATION ---$' "$BEADS_PCM"; then
    sed -i.intellisensebak '/^# --- BEGIN intellisense INTEGRATION ---$/,/^# --- END intellisense INTEGRATION ---$/d' "$BEADS_PCM"
    rm -f "$BEADS_PCM.intellisensebak"
  fi
  cat >> "$BEADS_PCM" <<EOF

# --- BEGIN intellisense INTEGRATION ---
# Managed by intellisense setup scripts. Chains intellisense's commit-msg trailer
# injector. prepare-commit-msg internally decides pilot-vs-block:
#   - exit 0 = success or pilot-mode warning (commit proceeds)
#   - exit 1 = block (cursor corruption, jq missing, etc. — commit MUST stop)
# Propagate the exit code; do NOT swallow it.
INTELLISENSE_HOOK="$SCRIPT_DIR/hooks/prepare-commit-msg"
if [ -x "\$INTELLISENSE_HOOK" ]; then
  "\$INTELLISENSE_HOOK" "\$@"
  _intellisense_rc=\$?
  if [ \$_intellisense_rc -ne 0 ]; then
    exit \$_intellisense_rc
  fi
fi
# --- END intellisense INTEGRATION ---
EOF
  status_line "UPDATED" "$BEADS_PCM — intellisense chain block refreshed (BEADS block preserved)"
else
  # No existing hook → write a fresh wrapper, so trailer injection works even
  # where Beads has not pre-created the file.
  cat > "$BEADS_PCM" <<EOF
#!/usr/bin/env sh
# Managed by intellisense setup scripts. Fresh-install wrapper —
# no prior Beads-managed hook to chain through.
INTELLISENSE_HOOK="$SCRIPT_DIR/hooks/prepare-commit-msg"
if [ -x "\$INTELLISENSE_HOOK" ]; then
  "\$INTELLISENSE_HOOK" "\$@"
  _intellisense_rc=\$?
  if [ \$_intellisense_rc -ne 0 ]; then
    exit \$_intellisense_rc
  fi
fi
EOF
  chmod +x "$BEADS_PCM"
  status_line "INSTALLED" "$BEADS_PCM — prepare-commit-msg fresh wrapper written (no prior hook present)"
fi

# install intellisense post-commit hook.
# Use resolve_hooks_dir, not hardcoded .beads/hooks.
# Beads does NOT ship its own post-commit, so we write the file fresh.
BEADS_POSTCOMMIT="$HOOKS_DIR_FOR_SELF/post-commit"
mkdir -p "$(dirname "$BEADS_POSTCOMMIT")" 2>/dev/null
cat > "$BEADS_POSTCOMMIT" <<EOF
#!/usr/bin/env sh
# Managed by intellisense setup scripts. Phase 2 of the two-phase token
# cursor. Promotes pending_cursor → committed_cursor after commit success.
# Fail-soft: missing intellisense hook is a no-op (commit already succeeded; cursor
# attribution merely won't advance until next setup.sh re-run).
INTELLISENSE_HOOK="$SCRIPT_DIR/hooks/post-commit"
if [ -x "\$INTELLISENSE_HOOK" ]; then
  "\$INTELLISENSE_HOOK" "\$@" 2>/dev/null || true
fi
EOF
chmod +x "$BEADS_POSTCOMMIT"
status_line "INSTALLED" "$BEADS_POSTCOMMIT — post-commit post-commit cursor promotion wired"

fi  # platform folder is a git checkout

# Heartbeat: heartbeat token + daily cron + fire once.
# Telemetry is optional: it runs only when a collector token is available. Without one, setup continues with
# the heartbeat off (the same as --no-heartbeat) and says how to turn it on later.
echo -e "${BLUE}→ Heartbeat: intellisense heartbeat (token + daily cron)${NC}"
if [[ "$NO_HEARTBEAT" != true ]] && ! install_heartbeat_token; then
  echo -e "${YELLOW}⚠️  No heartbeat token: usage telemetry stays off. Turn it on later with: bash setup.sh --rotate-token${NC}" >&2
  NO_HEARTBEAT=true
fi
install_heartbeat_cron
# Fire once immediately after install so the dashboard sees the dev within
# seconds. Best-effort and time-bounded: queues silently on failure (no token,
# no network) and never blocks setup if the heartbeat is slow (see below).
# INTELLISENSE_GH_LOGIN is exported by install_heartbeat_cron (resolved once, same
# value baked into the cron) so this first run reports the correct handle
# rather than re-resolving to the email local-part.
# >>> INTELLISENSE-HEARTBEAT-FIRE-ONCE (extracted verbatim by tests/test_heartbeat_fire_once_nonblocking.sh)
if [[ "$NO_HEARTBEAT" != true && "$DRY_RUN" != true && -f "$HOME/.intellisense/heartbeat-token" ]]; then
  # Prefer the installed runtime path (install_heartbeat_cron copies the script
  # to ~/.intellisense/bin); fall back to the in-repo source if absent.
  _hb_fire="$HOME/.intellisense/bin/intellisense-heartbeat.sh"
  [[ -x "$_hb_fire" ]] || _hb_fire="$SCRIPT_DIR/scripts/intellisense-heartbeat.sh"
  # P2 hang fix: the first heartbeat can git-fetch prices, parse transcripts, and
  # POST to the API. Bound it and log its output instead of discarding it, so a
  # slow/hanging run can never make setup appear to freeze right after the heartbeat step.
  _hb_log="$HOME/.claude-intellisense/heartbeat-setup.log"
  mkdir -p "$(dirname "$_hb_log")" 2>/dev/null || true
  if command -v timeout >/dev/null 2>&1; then
    INTELLISENSE_GH_LOGIN="${INTELLISENSE_GH_LOGIN:-}" timeout 30s bash "$_hb_fire" >>"$_hb_log" 2>&1 || true
  elif command -v gtimeout >/dev/null 2>&1; then
    INTELLISENSE_GH_LOGIN="${INTELLISENSE_GH_LOGIN:-}" gtimeout 30s bash "$_hb_fire" >>"$_hb_log" 2>&1 || true
  else
    # No timeout binary (stock macOS): run detached so setup never blocks on it.
    ( INTELLISENSE_GH_LOGIN="${INTELLISENSE_GH_LOGIN:-}" bash "$_hb_fire" >>"$_hb_log" 2>&1 & )
  fi
  unset _hb_fire _hb_log
fi
# <<< INTELLISENSE-HEARTBEAT-FIRE-ONCE

if [ "$CODE_INTEL" != "code-review-graph" ]; then
  echo -e "${BLUE}→ Step 17: code-review-graph not selected (code intelligence: $CODE_INTEL) — skipped${NC}"
else
echo -e "${BLUE}→ Step 17: Install code-review-graph MCP${NC}"
if ! detect_or_install_code_review_graph; then
  echo -e "${RED}❌ code-review-graph install failed — see remediation above${NC}"
  exit 1
fi
configure_mcp
if ! verify_code_review_graph; then
  echo -e "${RED}❌ code-review-graph verification failed — see message above${NC}"
  exit 1
fi
fi  # code intelligence = code-review-graph

# ============================================
# LAYER 2 COMPLETE — Now offer Layer 3 setup
# ============================================

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  intellisense Layer 2 Setup Complete ✓${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Compute smart default: try saved repos_base, else parent of $SCRIPT_DIR
SAVED_REPOS_BASE=""
if [ -f "$CLAUDE_HOME/config.json" ] && [ -z "$DRY_RUN" ]; then
    SAVED_REPOS_BASE=$(python3 -c "import json,sys; d=json.load(open('$CLAUDE_HOME/config.json')); print(d.get('repos_base',''))" 2>/dev/null || true)
fi
REPOS_BASE_DEFAULT="${SAVED_REPOS_BASE}"
if [ -z "$REPOS_BASE_DEFAULT" ]; then
    REPOS_BASE_DEFAULT="$(dirname "$SCRIPT_DIR")"
fi

# ============================================
# LAYER 3 — Per-Service Repository Setup
# ============================================
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Layer 3 Setup — Per-Service Repositories${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Step 17: Ask about auto-detection using smart default (skip if not interactive)
if $INTERACTIVE; then
  read -p "Auto-detect repos in $REPOS_BASE_DEFAULT? (yes/no) [yes]: " AUTO_DETECT
  AUTO_DETECT=${AUTO_DETECT:-yes}
else
  AUTO_DETECT=no
  echo -e "${YELLOW}[Non-interactive mode] Skipping Layer 3 setup (repos auto-detection disabled)${NC}"
fi

LAYER3_SKIP=false

if [ "$AUTO_DETECT" = "yes" ]; then
    REPOS_BASE="$REPOS_BASE_DEFAULT"
    echo "Searching for repos in: $REPOS_BASE"
elif $INTERACTIVE; then
    read -p "Enter base path for repos: " REPOS_BASE
    REPOS_BASE="${REPOS_BASE/#\~/$HOME}"  # expand ~ if user typed it
else
    echo -e "${YELLOW}[Non-interactive mode] No explicit repos path provided; skipping Layer 3${NC}"
    LAYER3_SKIP=true
fi

if [ ! -d "$REPOS_BASE" ] && [ "$LAYER3_SKIP" = false ]; then
    echo -e "${YELLOW}✗ Directory not found: $REPOS_BASE${NC}"
    echo ""
    # Ask for manual path since auto-detect failed (only in interactive mode)
    if $INTERACTIVE; then
        read -p "Enter base path for repos: " REPOS_BASE
        REPOS_BASE="${REPOS_BASE/#\~/$HOME}"  # expand ~ if user typed it
    fi

    if [ ! -d "$REPOS_BASE" ]; then
        echo -e "${RED}✗ Directory not found: $REPOS_BASE${NC}"
        echo -e "${YELLOW}  Skipping Layer 3 repo setup. You can run setup-repos.sh manually for each repo.${NC}"
        LAYER3_SKIP=true
    fi
fi

if [ "$LAYER3_SKIP" = false ] && [ -d "$REPOS_BASE" ]; then
    echo -e "${GREEN}✓ Using repos directory: $REPOS_BASE${NC}"
    echo ""

    # Find potential repos (directories with git)
    POTENTIAL_REPOS=()
    if [ -e "$REPOS_BASE/.git" ] && [ "$REPOS_BASE" != "$SCRIPT_DIR" ]; then
        # Developer entered the repo path itself, not a parent dir — treat as single repo
        POTENTIAL_REPOS+=("$(basename "$REPOS_BASE")")
        REPOS_BASE="$(dirname "$REPOS_BASE")"
    else
        for dir in "$REPOS_BASE"/*; do
            if [ -e "$dir/.git" ]; then
                repo_name=$(basename "$dir")
                [ "$dir" = "$SCRIPT_DIR" ] && continue  # skip INTELLISENSE_SETUP itself
                POTENTIAL_REPOS+=("$repo_name")
            fi
        done
    fi

    if [ ${#POTENTIAL_REPOS[@]} -eq 0 ]; then
        echo -e "${YELLOW}✗ No git repos found in: $REPOS_BASE${NC}"
        if $INTERACTIVE; then
            read -p "  Enter a specific repo path to add manually, or press Enter to skip: " MANUAL_REPO_PATH
            MANUAL_REPO_PATH="${MANUAL_REPO_PATH/#\~/$HOME}"  # expand ~ if user typed it

            if [ -n "$MANUAL_REPO_PATH" ] && [ -d "$MANUAL_REPO_PATH/.git" ]; then
                POTENTIAL_REPOS+=("$(basename "$MANUAL_REPO_PATH")")
                REPOS_BASE="$(dirname "$MANUAL_REPO_PATH")"
                echo -e "${GREEN}✓ Added: $MANUAL_REPO_PATH${NC}"
            elif [ -n "$MANUAL_REPO_PATH" ] && [ -d "$MANUAL_REPO_PATH" ]; then
                echo -e "${YELLOW}✗ Not a git repo (no .git found): $MANUAL_REPO_PATH — skipping${NC}"
            else
                echo -e "${YELLOW}  No repo provided. Skipping Layer 3 repo setup.${NC}"
            fi
        else
            echo -e "${YELLOW}[Non-interactive mode] Cannot prompt for manual repo path; skipping Layer 3${NC}"
        fi
    fi

    if [ ${#POTENTIAL_REPOS[@]} -gt 0 ]; then
        echo "Found ${#POTENTIAL_REPOS[@]} repo(s):"
        for repo in "${POTENTIAL_REPOS[@]}"; do
            echo "  • $repo"
        done
        echo ""

        # Create repos manifest (Track for scoped rollback)
        MANIFEST="$CLAUDE_HOME/repos-manifest.json"
        CREATED_FILES+=("$MANIFEST")
        echo "{" > "$MANIFEST"
        echo "  \"base_path\": \"$REPOS_BASE\"," >> "$MANIFEST"
        echo "  \"repos\": [" >> "$MANIFEST"

        FIRST=true
        SETUP_COUNT=0

        for repo_name in "${POTENTIAL_REPOS[@]}"; do
            REPO_PATH="$REPOS_BASE/$repo_name"

            # BEGIN: stack-detection
            # Self-contained block: given $REPO_PATH, sets $STACK to one of
            # go|python|php|angular|node|react|unknown. Sourced by
            # tests/test_setup.sh — keep dependency-free (no external helpers).
            STACK="unknown"
            _intellisense_detect_stack_at() {
                # Echoes detected stack for $1 (a repo path). "unknown" if none.
                local _p="$1"
                if [ -f "$_p/go.mod" ]; then
                    echo "go"
                elif [ -f "$_p/pyproject.toml" ] || [ -f "$_p/requirements.txt" ]; then
                    echo "python"
                elif [ -f "$_p/composer.json" ]; then
                    echo "php"
                elif [ -f "$_p/pom.xml" ] || [ -f "$_p/build.gradle" ] || [ -f "$_p/build.gradle.kts" ]; then
                    echo "java"
                elif [ -f "$_p/pubspec.yaml" ]; then
                    echo "flutter"
                elif [ -f "$_p/package.json" ]; then
                    if grep -q '"@angular/core"' "$_p/package.json" 2>/dev/null; then
                        echo "angular"
                    elif grep -qE '"(express|fastify|@nestjs/[^"]+|prisma|typeorm|sequelize|knex)"' "$_p/package.json" 2>/dev/null; then
                        echo "node"
                    elif grep -qE '"(react|react-dom|next|vite)"' "$_p/package.json" 2>/dev/null; then
                        echo "react"
                    else
                        echo "angular"
                    fi
                else
                    echo "unknown"
                fi
            }
            STACK=$(_intellisense_detect_stack_at "$REPO_PATH")

            # Monorepo fallback: if root has no manifest, scan first-level
            # subdirectories. Adopt the result ONLY if exactly one distinct
            # stack is found — refuse to guess in polyglot layouts.
            # Skip common noise dirs that legitimately carry package.json files
            # (node_modules, vendor) or build artifacts (dist, build, target).
            if [ "$STACK" = "unknown" ] && [ -d "$REPO_PATH" ]; then
                _intellisense_subdir_stacks=""
                for _sub in "$REPO_PATH"/*/; do
                    [ -d "$_sub" ] || continue
                    _base="${_sub%/}"; _base="${_base##*/}"
                    case "$_base" in
                        .*|node_modules|vendor|dist|build|target|out|coverage|tmp) continue ;;
                    esac
                    _s=$(_intellisense_detect_stack_at "$_sub")
                    if [ "$_s" != "unknown" ]; then
                        case " $_intellisense_subdir_stacks " in
                            *" $_s "*) ;;
                            *) _intellisense_subdir_stacks="${_intellisense_subdir_stacks}${_intellisense_subdir_stacks:+ }$_s" ;;
                        esac
                    fi
                done
                # Exactly one unique stack across subdirs → adopt it.
                if [ -n "$_intellisense_subdir_stacks" ] \
                   && [ "$(printf '%s\n' $_intellisense_subdir_stacks | wc -l | tr -d ' ')" = "1" ]; then
                    STACK="$_intellisense_subdir_stacks"
                fi
                unset _intellisense_subdir_stacks _sub _base _s
            fi
            unset -f _intellisense_detect_stack_at 2>/dev/null || true
            # END: stack-detection

            # Ask to setup this repo (CLAUDE.md handling lives in setup-repos.sh)
            echo "─────────────────────────────────────────"
            echo "Repo: $repo_name (Stack: $STACK)"

            # Version-aware advisory for CLAUDE.md handling.
            # Decision tree:
            #   • version match + CLAUDE.md exists → silent (setup-repos.sh skips)
            #   • version mismatch / missing version → setup-repos.sh runs
            #     analyze-and-propose; default action is inject/adopt/skip, never
            #     replace unless user passes --claude-md-action replace.
            # setup.sh itself never mutates CLAUDE.md — it delegates to
            # setup-repos.sh which has the safe analyze-and-propose flow.
            if [ -f "$REPO_PATH/CLAUDE.md" ]; then
                _existing_version_path=$(intellisense_state_path "$REPO_PATH" version)
                _stored_version=""
                if [ -f "$_existing_version_path" ]; then
                    _stored_version=$(grep 'INTELLISENSE_VERSION=' "$_existing_version_path" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
                fi
                if [ -n "$_stored_version" ] && [ "$_stored_version" = "$INTELLISENSE_VERSION" ]; then
                    : # version match — setup-repos.sh will skip; no message needed
                else
                    echo "  ℹ CLAUDE.md exists; setup-repos.sh will analyze and choose action."
                    echo "    Default: preserve existing file (inject/adopt/skip). Pass --claude-md-action replace to overwrite."
                fi
                unset _existing_version_path _stored_version
            fi

            if $INTERACTIVE; then
                read -p "  Setup $repo_name? (yes/no) [yes]: " SETUP_THIS
                SETUP_THIS=${SETUP_THIS:-yes}
            else
                SETUP_THIS="yes"
            fi

            if [ "$SETUP_THIS" = "no" ]; then
                echo "  ⊘ Skipping $repo_name"
                continue
            fi

            # Run setup-repos.sh (guards the stack fallback prompt)
            if [ "$STACK" = "unknown" ]; then
                echo "  ⚠ Could not auto-detect stack for $repo_name."
                if $INTERACTIVE; then
                    STACK_VALID=false
                    while [ "$STACK_VALID" = false ]; do
                        read -p "  Enter stack (go/php/angular/python/node/react/java/flutter/rust/csharp/ruby/swift/cpp): " MANUAL_STACK
                        case "$MANUAL_STACK" in
                            go|php|angular|python|node|react|java|flutter|rust|csharp|ruby|swift|cpp)
                                STACK="$MANUAL_STACK"
                                STACK_VALID=true
                                ;;
                            *)
                                echo "  ✗ Invalid stack. Must be: go, php, angular, python, node, react, java, flutter, rust, csharp, ruby, swift, or cpp"
                                ;;
                        esac
                    done
                else
                    echo -e "${RED}ERROR: Non-interactive mode requires auto-detected stack.${NC}"
                    echo "  Cannot proceed with $repo_name — stack is required."
                    echo "  Add one of: go.mod (go), pom.xml/build.gradle/build.gradle.kts (java), pyproject.toml/requirements.txt (python), composer.json (php), package.json (angular/react/node — distinguished by @angular/core, react/next/vite, or express/fastify/nestjs), or pubspec.yaml (flutter)"
                    echo "  Monorepos: a manifest one level deep is also accepted."
                    exit 1
                fi
            fi

            echo "  Setting up $repo_name ($STACK)..."
            bash "$SCRIPT_DIR/setup-repos.sh" --repo "$REPO_PATH" --stack "$STACK"

            if [ $? -eq 0 ]; then
                SETUP_COUNT=$((SETUP_COUNT + 1))
                echo "  ✓ Setup complete for $repo_name"

                # Ask about document generation (interactive only)
                if $INTERACTIVE; then
                    read -p "  Generate documentation now? (yes/defer-to-ci) [defer-to-ci]: " GEN_DOCS
                    GEN_DOCS=${GEN_DOCS:-defer-to-ci}

                    if [ "$GEN_DOCS" = "yes" ]; then
                        echo "  Generating documentation (this may take a minute)..."
                        echo "  (Document-service would run here — skill invocation pending)"
                    fi

                    # Ask about git commit (interactive only)
                    read -p "  Git commit setup changes? (yes/no) [no]: " GIT_COMMIT
                    GIT_COMMIT=${GIT_COMMIT:-no}

                    if [ "$GIT_COMMIT" = "yes" ]; then
                        cd "$REPO_PATH"
                        git add CLAUDE.md knowledge-base/ .intellisense/ .github/workflows/refresh-docs.yml 2>/dev/null || true
                        git commit -m "chore(intellisense): initialize intellisense setup with CLAUDE.md, docs, and CI workflow" || true
                        cd - > /dev/null
                        echo "  ✓ Changes committed"
                    fi
                fi
            else
                echo "  ✗ Setup failed for $repo_name"
            fi

            # Add to manifest
            if [ "$FIRST" = false ]; then
                echo "," >> "$MANIFEST"
            fi
            echo "    {" >> "$MANIFEST"
            echo "      \"name\": \"$repo_name\"," >> "$MANIFEST"
            echo "      \"path\": \"$REPO_PATH\"," >> "$MANIFEST"
            echo "      \"stack\": \"$STACK\"," >> "$MANIFEST"
            echo "      \"setup_time\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" >> "$MANIFEST"
            echo "    }" >> "$MANIFEST"
            FIRST=false
        done

        # Close manifest JSON
        echo "" >> "$MANIFEST"
        echo "  ]" >> "$MANIFEST"
        echo "}" >> "$MANIFEST"

        echo ""
        echo "✓ Manifest saved: $MANIFEST"
    fi
fi

# Save repos_base to config.json for future runs
if [ "$LAYER3_SKIP" = false ] && [ -d "$REPOS_BASE" ]; then
    if [ "$DRY_RUN" = false ]; then
        # Update config.json with the repos_base path (portable across macOS and Linux)
        sed -i.bak "s|\"repos_base\": \"\"|\"repos_base\": \"$REPOS_BASE\"|g" "$CLAUDE_HOME/config.json" 2>/dev/null || true
        rm -f "$CLAUDE_HOME/config.json.bak"
    fi
fi

# Final summary
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  intellisense Setup Complete ✓${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BOLD}What was created:${NC}"
echo ""
echo -e "  ~/.claude/  ${DIM}[intellisense managed]${NC}"
echo -e "  ├── rules/"
echo -e "  │   └── baseline/          → symlink"
echo -e "  ├── skills/                 → symlink"
echo -e "  ├── agents/                 → symlink"
echo -e "  ├── templates/              → symlink"
echo -e "  ├── infrastructure/         → symlink"
echo -e "  ├── service-map.md          → symlink"
echo -e "  ├── ${GREEN}CLAUDE.md${NC}               → generated (unique per developer)"
echo -e "  ├── ${GREEN}MEMORY.md${NC}               → deprecation stub (intellisense memory now in beads)"
echo -e "  ├── ${GREEN}config.json${NC}             → generated"
echo -e "  ├── ${GREEN}INTELLISENSE_README.md${NC}       → intellisense legend"
echo -e "  ├── ${GREEN}.intellisense-initialized${NC}    → setup marker"
echo -e "  ├── teams/                 → local directory"
echo -e "  └── projects/              → local directory"
echo ""
echo -e "  ~/.intellisense/rules/  ${DIM}[intellisense managed]${NC}"
echo -e "  ├── language-specific/      → symlink"
echo -e "  └── operational/            → symlink"
echo ""
echo -e "  Symlinks verified: $SYMLINK_COUNT/9"
echo ""
echo -e "${BOLD}Required tools installed:${NC}"
echo ""
BD_VERSION_LINE="$(command -v bd >/dev/null 2>&1 && bd version 2>/dev/null | head -1 || echo 'not found')"
CRG_VERSION_LINE="$(command -v code-review-graph >/dev/null 2>&1 && _crg_extract_version || echo 'not found')"
echo -e "  ${GREEN}beads (bd)${NC}              ${DIM}→ $BD_VERSION_LINE${NC}"
echo -e "  ${GREEN}code-review-graph${NC}       ${DIM}→ $CRG_VERSION_LINE (required: $CRG_REQUIRED_VERSION)${NC}"
echo -e "  ${DIM}(both are mandatory at the global level — re-run setup.sh if either is missing)${NC}"
echo ""
echo -e "${BOLD}Next Steps:${NC}"
echo -e "  1. /where-to-start 'balance deduction'  — test routing"
echo -e "  2. /plan [your requirement]             — start working"
echo -e "  3. cat ${SCRIPT_DIR}/QUICK_START.md"
echo ""
echo -e "  To update rules/skills: ${CYAN}cd INTELLISENSE_SETUP && git pull${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
