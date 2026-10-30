#!/bin/bash

# intellisense Restore Script
# Removes intellisense symlinks from ~/.claude/ and restores original files from backups.
# Usage: ./restore.sh [OPTIONS]
#
# Options:
#   --non-interactive  Run without prompts (requires --yes to proceed)
#   --yes              Auto-confirm all actions (with --non-interactive)
#   --dry-run          Show what would be done without making changes
#
# Examples:
#   ./restore.sh                                    (interactive mode)
#   ./restore.sh --dry-run                          (preview changes)
#   ./restore.sh --non-interactive --yes            (automated restore)

set -e

# Color constants
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

CLAUDE_HOME="$HOME/.claude"
INTELLISENSE_HOME="$HOME/.intellisense"
# Where setup.sh writes its backups.
INTELLISENSE_BACKUPS_DIR="${INTELLISENSE_BACKUPS_DIR:-$HOME/.intellisense-backups}"

# Source per-repo intellisense metadata path resolver (.intellisense/ layout)
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/intellisense-paths.sh"

# Parse arguments
INTERACTIVE=true
if [ ! -t 0 ]; then
  INTERACTIVE=false
fi
DRY_RUN=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --non-interactive)
      INTERACTIVE=false
      shift
      ;;
    --yes)
      AUTO_YES=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      exit 1
      ;;
  esac
done

# Read INTELLISENSE_SETUP_DIR from config.json so we only remove symlinks that point into INTELLISENSE_SETUP
INTELLISENSE_SETUP_DIR=$(grep '"intellisense_setup_path"' "$CLAUDE_HOME/config.json" 2>/dev/null | sed 's/.*": "\(.*\)".*/\1/')
# Fallback: this script lives in INTELLISENSE_SETUP, so use its own directory
[ -z "$INTELLISENSE_SETUP_DIR" ] && INTELLISENSE_SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RESTORED_COUNT=0
REMOVED_COUNT=0
SKIPPED_COUNT=0

status_line() {
  local STATUS="$1"
  local ITEM="$2"
  local PREFIX=""
  [ "$DRY_RUN" = true ] && PREFIX="[DRY-RUN] "
  case "$STATUS" in
    RESTORED) echo -e "  ${GREEN}[RESTORED]${NC}  ${PREFIX}$ITEM" ; ((++RESTORED_COUNT)) ;;
    REMOVED)  echo -e "  ${YELLOW}[REMOVED]${NC}   ${PREFIX}$ITEM" ; ((++REMOVED_COUNT)) ;;
    SKIPPED)  echo -e "  ${DIM}[SKIPPED]${NC}   ${PREFIX}$ITEM" ; ((++SKIPPED_COUNT)) ;;
    WARN)     echo -e "  ${YELLOW}[WARN]${NC}     ${PREFIX}$ITEM" ;;
  esac
}

# List every backup for $1 in ~/.intellisense-backups/. Echoed lines are bare paths,
# unsorted. Globs that don't match are filtered out.
list_backups_for() {
  local DST="$1"
  local base
  base="$(basename "$DST")"
  local p
  for p in "$INTELLISENSE_BACKUPS_DIR/${base}.bak-"*; do
    [ -e "$p" ] && echo "$p"
  done
}

# Remove an intellisense symlink and restore from .bak-TIMESTAMP backup if one exists.
# Backups are looked up in ~/.intellisense-backups/. Skips paths that are not intellisense-managed symlinks.
restore_symlink() {
  local DST="$1"
  local LABEL="$2"
  [ -n "$DEBUG" ] && echo "[DEBUG] restore_symlink called with DST=$DST" >&2

  if [ ! -L "$DST" ]; then
    [ -n "$DEBUG" ] && echo "[DEBUG] Not a symlink, returning" >&2
    [ -e "$DST" ] && status_line "SKIPPED" "$LABEL (not a symlink — untouched)" || true
    return
  fi

  local TARGET
  TARGET=$(readlink "$DST")
  [ -n "$DEBUG" ] && echo "[DEBUG] Target=$TARGET, INTELLISENSE_SETUP_DIR=$INTELLISENSE_SETUP_DIR" >&2
  if [[ "$TARGET" != *"$INTELLISENSE_SETUP_DIR"* ]]; then
    [ -n "$DEBUG" ] && echo "[DEBUG] Not an intellisense symlink, skipping" >&2
    status_line "SKIPPED" "$LABEL (not an intellisense symlink — points to: $TARGET)"
    return
  fi
  [ -n "$DEBUG" ] && echo "[DEBUG] Is an intellisense symlink, proceeding" >&2

  if [ "$DRY_RUN" = false ]; then
    [ -n "$DEBUG" ] && echo "[DEBUG] About to remove: rm -f \"$DST\"" >&2 || true
    rm -f "$DST"
    [ -n "$DEBUG" ] && echo "[DEBUG] After rm -f, symlink still exists: [ -L \"$DST\" ] = $([ -L "$DST" ] && echo true || echo false)" >&2 || true
  fi

  # Oldest backup = the original from before intellisense
  # (YYYYMMDDHHMMSS suffix sorts lexicographically when basenames are compared).
  local OLDEST_BAK
  OLDEST_BAK=$(list_backups_for "$DST" | awk -F/ '{print $NF"\t"$0}' | sort | head -1 | cut -f2-)

  if [ -n "$OLDEST_BAK" ]; then
    [ -n "$DEBUG" ] && echo "[DEBUG] Found backup: $OLDEST_BAK" >&2
    if [ "$DRY_RUN" = false ]; then
      mv "$OLDEST_BAK" "$DST"
      # Clean up any extra backups left from repeated setup runs
      local extra
      while IFS= read -r extra; do
        [ -n "$extra" ] && [ -e "$extra" ] && rm -rf "$extra"
      done < <(list_backups_for "$DST")
    fi
    status_line "RESTORED" "$LABEL  ← $(basename "$OLDEST_BAK")"
  else
    [ -n "$DEBUG" ] && echo "[DEBUG] No backup found, marking as removed" >&2
    status_line "REMOVED" "$LABEL (no backup — was not present before intellisense)"
  fi
  [ -n "$DEBUG" ] && echo "[DEBUG] restore_symlink returning for $DST" >&2 || true
}

# ─────────────────────────────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  intellisense Restore — Remove intellisense and Recover Original Setup${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${DIM}INTELLISENSE_SETUP : $INTELLISENSE_SETUP_DIR${NC}"
echo -e "  ${DIM}Claude Home: $CLAUDE_HOME${NC}"
echo ""

echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
if [ "$DRY_RUN" = true ]; then
  echo -e "${CYAN}│  [DRY-RUN] What restore WOULD do:                           │${NC}"
else
  echo -e "${CYAN}│  What restore will do:                                      │${NC}"
fi
echo -e "${CYAN}├─────────────────────────────────────────────────────────────┤${NC}"
echo -e "${CYAN}│  Remove intellisense symlinks from ~/.claude/                       │${NC}"
echo -e "${CYAN}│  Restore original dirs/files from .bak-* backups if found  │${NC}"
echo -e "${CYAN}│  Delete intellisense-generated files (config.json, markers, etc.)  │${NC}"
echo -e "${CYAN}│  Per repo (interactive only): ASK before deleting           │${NC}"
echo -e "${CYAN}│    intellisense-installed CLAUDE.md (restores the original if kept) │${NC}"
echo -e "${CYAN}│    intellisense-installed knowledge-base/                           │${NC}"
echo -e "${CYAN}│                                                             │${NC}"
echo -e "${CYAN}│  Restore ~/.claude/CLAUDE.md from oldest CLAUDE.bak-<ts>    │${NC}"
echo -e "${CYAN}│    (pre-intellisense developer copy, if any) — intellisense-owned now      │${NC}"
echo -e "${CYAN}│  Will NOT touch: ~/.claude/{MEMORY.md,                      │${NC}"
echo -e "${CYAN}│                  teams/, applications/}                     │${NC}"
echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
echo ""

if $INTERACTIVE; then
  read -p "Proceed? (yes/no) [no]: " CONFIRM
  CONFIRM=${CONFIRM:-no}
else
  if [ "$AUTO_YES" = true ]; then
    CONFIRM="yes"
  else
    CONFIRM="no"
  fi
fi

if [ "$CONFIRM" != "yes" ]; then
  if $INTERACTIVE || [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}Restore cancelled.${NC}"
  else
    echo -e "${RED}ERROR: --non-interactive requires --yes to proceed${NC}"
  fi
  exit 0
fi
echo ""

# ─────────────────────────────────────────────────────────────
echo -e "${BLUE}→ Restoring ~/.claude/ symlinks${NC}" >&1
[ -n "$DEBUG" ] && echo "[DEBUG] About to restore baseline" >&2 || true

restore_symlink "$CLAUDE_HOME/rules/baseline"   "~/.claude/rules/baseline"
[ -n "$DEBUG" ] && echo "[DEBUG] After baseline symlink" >&2 || true

restore_symlink "$CLAUDE_HOME/skills"           "~/.claude/skills"
[ -n "$DEBUG" ] && echo "[DEBUG] After skills symlink" >&2 || true
restore_symlink "$CLAUDE_HOME/agents"           "~/.claude/agents"
[ -n "$DEBUG" ] && echo "[DEBUG] After agents symlink" >&2 || true
restore_symlink "$CLAUDE_HOME/templates"        "~/.claude/templates"
[ -n "$DEBUG" ] && echo "[DEBUG] After templates symlink" >&2 || true
restore_symlink "$CLAUDE_HOME/infrastructure"   "~/.claude/infrastructure"
[ -n "$DEBUG" ] && echo "[DEBUG] After infrastructure symlink" >&2 || true
restore_symlink "$CLAUDE_HOME/service-map.md"   "~/.claude/service-map.md"
[ -n "$DEBUG" ] && echo "[DEBUG] After service-map.md symlink" >&2 || true

echo ""
echo -e "${BLUE}→ Restoring ~/.intellisense/rules/ symlinks${NC}"

restore_symlink "$INTELLISENSE_HOME/rules/language-specific" "~/.intellisense/rules/language-specific"
[ -n "$DEBUG" ] && echo "[DEBUG] After language-specific symlink" >&2 || true
restore_symlink "$INTELLISENSE_HOME/rules/operational"       "~/.intellisense/rules/operational"
[ -n "$DEBUG" ] && echo "[DEBUG] After operational symlink" >&2 || true

echo ""
# Capture repo paths from repos-manifest.json BEFORE the rm loop below deletes
# it. Without this, the per-repo cleanup further down sees "manifest already
# removed" and silently skips every repo.
REPO_PATHS=""
if [ -f "$CLAUDE_HOME/repos-manifest.json" ]; then
  REPO_PATHS=$(grep -o '"path": "[^"]*"' "$CLAUDE_HOME/repos-manifest.json" 2>/dev/null | cut -d'"' -f4 | sort -u)
fi

[ -n "$DEBUG" ] && echo "[DEBUG] About to remove intellisense-generated files" >&2 || true
echo -e "${BLUE}→ Removing intellisense-generated files${NC}"

for f in \
  "$CLAUDE_HOME/config.json" \
  "$CLAUDE_HOME/.intellisense-initialized" \
  "$CLAUDE_HOME/repos-manifest.json" \
  "$CLAUDE_HOME/INTELLISENSE_README.md" \
  "$CLAUDE_HOME/.intellisense-version"
do
  [ -n "$DEBUG" ] && echo "[DEBUG] Checking file: $f (exists: $([ -f "$f" ] && echo true || echo false))" >&2 || true
  if [ -f "$f" ]; then
    [ -n "$DEBUG" ] && echo "[DEBUG] About to remove: rm -f \"$f\"" >&2 || true
    if [ "$DRY_RUN" = false ]; then
      rm -f "$f"
    fi
    [ -n "$DEBUG" ] && echo "[DEBUG] After rm, file exists: $([ -f "$f" ] && echo true || echo false)" >&2 || true
    status_line "REMOVED" "$(echo "$f" | sed "s|$HOME|~|")"
  fi
done

# Restore ~/.claude/CLAUDE.md. Under the intellisense-owned model
# setup.sh writes a fresh CLAUDE.md on every run and parks any prior copy at
# $INTELLISENSE_BACKUPS_DIR/CLAUDE.bak-<ts>. The OLDEST .bak is the developer's
# pre-intellisense original; restore that, then clean up the rest. If no .bak exists,
# the file was created by intellisense itself — just remove it.
echo ""
echo -e "${BLUE}→ Restoring ~/.claude/CLAUDE.md (intellisense-owned)${NC}"
CLAUDE_MD="$CLAUDE_HOME/CLAUDE.md"
OLDEST_CLAUDE_BAK=""
if [ -d "$INTELLISENSE_BACKUPS_DIR" ]; then
  # Filenames carry sortable YYYYMMDDhhmmss timestamps → lexicographic sort
  # is chronological. Take the first (oldest = pre-intellisense original).
  OLDEST_CLAUDE_BAK=$(ls -1 "$INTELLISENSE_BACKUPS_DIR/CLAUDE.bak-"* 2>/dev/null | sort | head -1)
fi

if [ -n "$OLDEST_CLAUDE_BAK" ]; then
  if [ "$DRY_RUN" = false ]; then
    rm -f "$CLAUDE_MD"
    mv "$OLDEST_CLAUDE_BAK" "$CLAUDE_MD"
    # Discard any remaining (intermediate) rotations — they don't represent
    # developer authorship, just past intellisense-generated snapshots.
    rm -f "$INTELLISENSE_BACKUPS_DIR/CLAUDE.bak-"*
  fi
  status_line "RESTORED" "~/.claude/CLAUDE.md  ← $(basename "$OLDEST_CLAUDE_BAK")"
elif [ -f "$CLAUDE_MD" ]; then
  if [ "$DRY_RUN" = false ]; then
    rm -f "$CLAUDE_MD"
  fi
  status_line "REMOVED" "~/.claude/CLAUDE.md (intellisense-installed, no pre-intellisense backup)"
else
  status_line "SKIPPED" "~/.claude/CLAUDE.md (already absent)"
fi

# Clean up ~/.intellisense/rules/ if now empty
if [ -d "$INTELLISENSE_HOME/rules" ] && [ -z "$(ls -A "$INTELLISENSE_HOME/rules" 2>/dev/null)" ]; then
  if [ "$DRY_RUN" = false ]; then
    rm -rf "$INTELLISENSE_HOME/rules"
  fi
  status_line "REMOVED" "~/.intellisense/rules/ (now empty)"
fi

# ─── Heartbeat TCC-safe runtime ──────────────────────
# Remove the copied heartbeat runtime + VERSION written by setup.sh's
# install_heartbeat_cron(). DO NOT touch:
#   - $INTELLISENSE_HOME/heartbeat-token  (per-dev secret)
#   - $INTELLISENSE_HOME  (parent dir — may be empty after this, but never
#     remove it from here; that's the rules cleanup block's job)
echo ""
echo -e "${BLUE}→ Removing TCC-safe heartbeat runtime install${NC}"

HEARTBEAT_BIN="$INTELLISENSE_HOME/bin"
HEARTBEAT_VERSION="$INTELLISENSE_HOME/VERSION"

if [ -d "$HEARTBEAT_BIN" ]; then
  if [ "$DRY_RUN" = false ]; then
    rm -rf "$HEARTBEAT_BIN"
  fi
  status_line "REMOVED" "~/.intellisense/bin/ (heartbeat runtime + manifest)"
fi

if [ -f "$HEARTBEAT_VERSION" ]; then
  if [ "$DRY_RUN" = false ]; then
    rm -f "$HEARTBEAT_VERSION"
  fi
  status_line "REMOVED" "~/.intellisense/VERSION (heartbeat-side copy)"
fi

# ─── Remove the heartbeat scheduler ────────────────────────
# Linux uses a systemd --user timer, or a plain crontab line where systemd is unavailable. Tear down whichever
# exists. macOS launchd teardown is
# handled elsewhere / by re-running setup.sh --no-heartbeat.
#
# Unit-file removal is unconditional: when restore runs over SSH / without an
# active user-bus session, `systemctl --user` is unusable but the unit files
# (written by setup.sh as plain files) would otherwise leak. We rm them
# regardless, and only run the live systemctl/loginctl calls when a usable
# user systemd instance is present.
if [ -f "$HOME/.config/systemd/user/intellisense-heartbeat.timer" ] || \
   [ -f "$HOME/.config/systemd/user/intellisense-heartbeat.service" ]; then
  if [ "$DRY_RUN" = false ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
      systemctl --user disable --now intellisense-heartbeat.timer 2>/dev/null || true
    fi
    rm -f "$HOME/.config/systemd/user/intellisense-heartbeat.timer" \
          "$HOME/.config/systemd/user/intellisense-heartbeat.service"
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
      systemctl --user daemon-reload 2>/dev/null || true
    fi
    # setup.sh enabled linger for the install user; undo it so restore leaves
    # no lingering user manager behind. Best-effort (may be denied/already off).
    command -v loginctl >/dev/null 2>&1 && loginctl disable-linger "$(id -un)" >/dev/null 2>&1 || true
  fi
  status_line "REMOVED" "systemd user timer intellisense-heartbeat.{timer,service}"
fi
if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'intellisense-heartbeat'; then
  if [ "$DRY_RUN" = false ]; then
    crontab -l 2>/dev/null | grep -v 'intellisense-heartbeat' | crontab - 2>/dev/null || true
  fi
  status_line "REMOVED" "crontab intellisense-heartbeat entry"
fi

# Explicitly preserve the heartbeat token — surface it so the user knows
if [ -f "$INTELLISENSE_HOME/heartbeat-token" ]; then
  status_line "KEPT" "~/.intellisense/heartbeat-token (per-dev secret — never auto-removed)"
fi

# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}→ Files kept (developer-owned — review manually if needed)${NC}"

[ -f "$CLAUDE_HOME/MEMORY.md"  ] && status_line "WARN" "~/.claude/MEMORY.md  still exists — contains your session memory"

# Notify about .intellisense-new candidate files that may exist in repos
echo ""
echo -e "${BLUE}→ Checking for .intellisense-new candidate files in repos${NC}"

if [ -n "$REPO_PATHS" ]; then
  # Iterate the snapshot we captured before repos-manifest.json was deleted.
  CANDIDATE_COUNT=0
  while IFS= read -r repo_path; do
    if [ -d "$repo_path" ]; then
      # Read manifest BEFORE per-key cleanup deletes it. Components tells us
      # whether intellisense actually installed CLAUDE.md / knowledge-base/ in this
      # repo — so we don't offer to delete pre-existing developer work that
      # intellisense simply left alone.
      manifest_path=$(intellisense_state_path "$repo_path" manifest)
      intellisense_components=""
      if [ -f "$manifest_path" ]; then
        intellisense_components=$(grep -oE '"(claude-md|knowledge-base|hooks|github-actions)"' "$manifest_path" 2>/dev/null | tr -d '"' | sort -u)
      fi

      # Scoped cleanup: remove intellisense-managed files but preserve .intellisense/local.json
      # (dev-machine state — saves redundant identity checks on re-install) and
      # any .intellisense/.backup/ (the repository's original CLAUDE.md).
      for key in version manifest stubs-status kb-status existing-knowledge-report; do
        state_path=$(intellisense_state_path "$repo_path" "$key")
        if [ -f "$state_path" ]; then
          [ "$DRY_RUN" = false ] && rm -f "$state_path"
          status_line "REMOVED" "$(basename "$repo_path")/.intellisense/$(basename "$state_path")"
        fi
      done

      # Offer to delete intellisense-installed CLAUDE.md and knowledge-base/. Only
      # prompted in interactive mode — non-interactive runs leave repo
      # artifacts untouched (they may have been customized by the developer).
      # CLAUDE.md is restored from .intellisense/.backup/CLAUDE.md.original
      # when present (mirrors the symlink-restore pattern used above).
      if $INTERACTIVE; then
        has_claude_md=false
        has_kb=false
        if echo "$intellisense_components" | grep -qx "claude-md" && [ -f "$repo_path/CLAUDE.md" ]; then
          has_claude_md=true
        fi
        if echo "$intellisense_components" | grep -qx "knowledge-base" && [ -d "$repo_path/knowledge-base" ]; then
          has_kb=true
        fi

        if $has_claude_md || $has_kb; then
          artifacts_list=""
          $has_claude_md && artifacts_list+="CLAUDE.md " || true
          $has_kb        && artifacts_list+="knowledge-base/" || true
          echo ""
          echo -e "  ${CYAN}$(basename "$repo_path")${NC}: intellisense-installed → ${artifacts_list}"
          # Outer while-loop has stdin redirected to grep output, so prompt
          # must read from /dev/tty.
          read -p "  Delete these? (yes/no) [no]: " REPO_ARTIFACT_ANSWER < /dev/tty
          REPO_ARTIFACT_ANSWER=${REPO_ARTIFACT_ANSWER:-no}

          if [ "$REPO_ARTIFACT_ANSWER" = "yes" ]; then
            if $has_claude_md; then
              orig_claude_md="$repo_path/.intellisense/.backup/CLAUDE.md.original"
              if [ -f "$orig_claude_md" ]; then
                [ "$DRY_RUN" = false ] && mv "$orig_claude_md" "$repo_path/CLAUDE.md"
                status_line "RESTORED" "$(basename "$repo_path")/CLAUDE.md  ← .backup/CLAUDE.md.original"
              else
                [ "$DRY_RUN" = false ] && rm -f "$repo_path/CLAUDE.md"
                status_line "REMOVED" "$(basename "$repo_path")/CLAUDE.md (intellisense-installed, no original kept)"
              fi
              if [ "$DRY_RUN" = false ] && [ -d "$repo_path/.intellisense/.backup" ]; then
                rmdir "$repo_path/.intellisense/.backup" 2>/dev/null || true
              fi
            fi
            if $has_kb; then
              [ "$DRY_RUN" = false ] && rm -rf "$repo_path/knowledge-base"
              status_line "REMOVED" "$(basename "$repo_path")/knowledge-base/"
            fi
          else
            if $has_claude_md; then
              status_line "SKIPPED" "$(basename "$repo_path")/CLAUDE.md (developer kept)"
            fi
            if $has_kb; then
              status_line "SKIPPED" "$(basename "$repo_path")/knowledge-base/ (developer kept)"
            fi
          fi
        fi
      fi

      # Try to rmdir .intellisense/ — silent fail if local.json or .backup remain.
      if [ -d "$repo_path/.intellisense" ] && [ "$DRY_RUN" = false ]; then
        rmdir "$repo_path/.intellisense" 2>/dev/null || true
      fi

      # Check for .intellisense-new candidate files
      for candidate in "$repo_path"/.git/hooks/*.intellisense-new "$repo_path"/.github/workflows/*.intellisense-new; do
        if [ -f "$candidate" ]; then
          status_line "WARN" "$(basename "$repo_path")/$(basename "$candidate") — review and delete if not needed"
          ((CANDIDATE_COUNT++))
        fi
      done
    fi
  done <<< "$REPO_PATHS"

  if [ "$CANDIDATE_COUNT" -gt 0 ]; then
    echo "  Tip: ${YELLOW}find . -name '*.intellisense-new' -type f${NC} to locate all candidates"
  fi
else
  status_line "SKIPPED" "no repos-manifest.json found — per-repo cleanup skipped"
fi

# ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [ "$DRY_RUN" = true ]; then
  echo -e "${BOLD}  intellisense Restore [DRY-RUN] Complete${NC}"
else
  echo -e "${BOLD}  intellisense Restore Complete${NC}"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${GREEN}Restored${NC} : $RESTORED_COUNT  (original files recovered from backup)"
echo -e "  ${YELLOW}Removed${NC}  : $REMOVED_COUNT  (intellisense symlinks/files deleted, no backup)"
echo -e "  ${DIM}Skipped${NC}  : $SKIPPED_COUNT  (non-intellisense paths left untouched)"
echo ""
if [ "$DRY_RUN" = true ]; then
  echo -e "  ${YELLOW}Dry-run completed.${NC} To proceed with actual restore: ${CYAN}bash restore.sh${NC}"
else
  echo -e "  To re-install intellisense later: ${CYAN}intellisense live install${NC}  (or ${CYAN}bash setup.sh${NC} from a checkout)"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
