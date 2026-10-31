#!/bin/bash

# setup-repos.sh — Initialize per-repo documentation generation
# Usage: ./setup-repos.sh --repo /path/to/service-repo --stack go|php|angular|python|flutter [OPTIONS]
#
# Required:
#   --repo PATH            Repository path
#   --stack STACK          Stack: go, php, or angular
#
# Options:
#   --skip-claude-md       Skip copying CLAUDE.md template (if already exists)
#   --auto-commit          (NOT YET IMPLEMENTED) Auto-commit setup changes to git
#   --claude-md-action     Set CLAUDE.md action: replace|inject|skip (for non-interactive mode)
#   --force                Force overwrite of hooks (create .bak backups)
#
# This script:
# 1. Validates repo and stack
# 2. Copies/injects/replaces CLAUDE.md template
# 3. Creates knowledge-base/ directory with stub files
# 4. Safely installs pre-push hook for fork workflow
# 5. Provides instructions for /document-service
#
# Example:
#   ./setup-repos.sh --repo ~/projects/orders-service --stack go
#   ./setup-repos.sh --repo ~/projects/invoicing-service --stack php --auto-commit
#   ./setup-repos.sh --repo ~/projects/billing --stack go --claude-md-action inject --force
#

set -euo pipefail

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

# Defaults
REPO_PATH=""
STACK=""
SKIP_CLAUDE_MD=false
SKIP_CI=false
AUTO_COMMIT=false
FORCE_INSTALL=false
# Opt-in flag — when true, call scripts/apply-merge-policy.sh
# at end of onboarding to set rebase-only merge policy on the upstream repo.
# Off by default because (a) the operator may not have GH admin on upstream;
# (b) rollout should be deliberate, not a side-effect of running setup.
APPLY_MERGE_POLICY=false
CLAUDE_MD_ACTION=""
CLAUDE_ACTION="inject"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLISENSE_SETUP_DIR=""

# Source intellisense path helpers — ensures ~/.local/bin and /opt/homebrew/bin are on
# PATH before any tool-existence check (bd, code-review-graph). Without this,
# graph-bootstrap.sh and bd init silently fail when the inherited shell PATH
# does not include the user-tool install dirs (pipx / pip --user / uv tool /
# Homebrew).
source "$SCRIPT_DIR/scripts/lib/intellisense-paths.sh"
_ensure_local_bin_on_path

# Graph-bootstrap flags (used with --code-intel code-review-graph)
MIGRATE=false
REPAIR=false
GRAPH_EXCEPTION=""
GRAPH_EXC_OWNER=""
GRAPH_EXC_EXPIRES=""
MIN_NODES_OVERRIDE=""

# Source shared hooks resolution library
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/hooks.sh"
# Source per-repo intellisense metadata path resolver (.intellisense/ layout)
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/intellisense-paths.sh"
# Source graph integration helpers
source "$(dirname "${BASH_SOURCE[0]}")/scripts/lib/intellisense-graph.sh"

# Interactive mode detection
INTERACTIVE=true
if [ ! -t 0 ]; then
  INTERACTIVE=false
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo)
      REPO_PATH="$2"
      shift 2
      ;;
    --stack)
      STACK="$2"
      shift 2
      ;;
    --skip-claude-md)
      SKIP_CLAUDE_MD=true
      shift
      ;;
    --skip-ci)
      SKIP_CI=true
      shift
      ;;
    --auto-commit)
      AUTO_COMMIT=true
      shift
      ;;
    --claude-md-action)
      CLAUDE_MD_ACTION="$2"
      shift 2
      ;;
    --force)
      FORCE_INSTALL=true
      shift
      ;;
    --intellisense-setup)
      INTELLISENSE_SETUP_DIR="$2"
      shift 2
      ;;
    --non-interactive)
      INTERACTIVE=false
      shift
      ;;
    --tracker)
      # Task tracker: none, beads, github, jira, linear. Only beads initialises anything in the repo (.beads/).
      TRACKER="$2"
      shift 2
      ;;
    --code-intel)
      # none or code-review-graph. Only code-review-graph builds the per-repo graph.
      CODE_INTEL="$2"
      shift 2
      ;;
    --apply-merge-policy)
      # Opt-in: after onboarding, run scripts/apply-merge-policy.sh
      # against the upstream remote to enforce rebase-only merges.
      APPLY_MERGE_POLICY=true
      shift
      ;;
    # ----- graph-bootstrap flags -----
    --migrate)
      MIGRATE=true
      shift
      ;;
    --repair)
      REPAIR=true
      shift
      ;;
    --graph-exception)
      GRAPH_EXCEPTION="$2"
      shift 2
      ;;
    --graph-exception-owner|--owner)
      GRAPH_EXC_OWNER="$2"
      shift 2
      ;;
    --graph-exception-expires|--expires)
      GRAPH_EXC_EXPIRES="$2"
      shift 2
      ;;
    --min-nodes)
      MIN_NODES_OVERRIDE="$2"
      shift 2
      ;;
    # NOTE: there is no --unmanage flag: un-managing a repo is a deliberate manual step.
    # NOTE: there is no --skip-graph-build flag either. The
    # only legitimate ways to avoid a graph build (with the graph chosen) are:
    #   - --graph-exception (audited opt-out for unsupported / weak / incident)
    #   - mandatory-supported stack with binary missing → setup-repos.sh exits
    #     and the user runs `bash setup.sh` first.
    # An ungated bypass would defeat the mandatory-stack policy.
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      exit 1
      ;;
  esac
done

# Default INTELLISENSE_SETUP_DIR to SCRIPT_DIR if not provided
[ -z "$INTELLISENSE_SETUP_DIR" ] && INTELLISENSE_SETUP_DIR="$SCRIPT_DIR"

# Read intellisense version
INTELLISENSE_VERSION=$(cat "$INTELLISENSE_SETUP_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')
[ -z "$INTELLISENSE_VERSION" ] && INTELLISENSE_VERSION="1.0.1"

# Set CLAUDE_ACTION to skip if --skip-claude-md was specified and no explicit action given
if [ "$SKIP_CLAUDE_MD" = true ] && [ -z "$CLAUDE_MD_ACTION" ]; then
  CLAUDE_ACTION="skip"
fi

# Version tracking flags
SKIP_CLAUDE_MD_SETUP=false
SKIP_DOCS_SETUP=false
KB_TYPE=""

# Component tracking for manifest
INSTALLED_COMPONENTS=()

# True iff this run wrote a template-generated CLAUDE.md (fresh copy or
# explicit replace). Gates placeholder filling so inject/adopt/skip paths
# never mutate human-owned content.
CLAUDE_TEMPLATE_WRITTEN=false

# Ask whether to regenerate a team-enriched artifact on a version bump.
# Default = preserve (return 1). Returns 0 ONLY when the user explicitly
# types y/yes at an interactive TTY. Non-TTY runs (CI, piped stdin) and the
# CI=true env var auto-default to preserve — never hang automation.
#
# Honored env override for tests / scripted re-onboarding:
#   INTELLISENSE_REGEN_ANSWER=yes  → behave as if the user typed yes
#   INTELLISENSE_REGEN_ANSWER=no   → behave as if the user typed no (same as default)
_intellisense_prompt_regenerate() {
  local what="$1"
  local new_version="$2"

  # Scripted answer wins over both TTY and CI.
  case "${INTELLISENSE_REGEN_ANSWER:-}" in
    y|Y|yes|YES) return 0 ;;
    n|N|no|NO)   return 1 ;;
  esac

  # Non-interactive (CI, pipe, no controlling terminal, or explicit
  # --non-interactive CLI flag) → safe default = no. The $INTERACTIVE global
  # is the canonical signal: it's set false by both the TTY check at the top
  # of this script AND by the --non-interactive flag (see arg parser).
  # Reading it here keeps the prompt consistent with every other interactive
  # path in setup-repos.sh (e.g. the CLAUDE.md action prompt at line ~845).
  if [ "${INTERACTIVE:-true}" = false ] || [ "${CI:-false}" = "true" ]; then
    echo -e "  ${DIM}(non-interactive — defaulting to 'no', preserving $what)${NC}" >&2
    return 1
  fi

  local reply
  printf '%b' "  ${YELLOW}?${NC} ${what} already exists with team-enriched content. Regenerate from intellisense v${new_version} templates? [y/N]: " >&2
  IFS= read -r reply || true
  reply=$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')
  case "$reply" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

check_repo_version() {
  local version_path
  version_path=$(intellisense_state_path "$REPO_PATH" version)

  # When .intellisense/version is absent this is a first-time install — skip the
  # preservation block entirely so the templates get laid down.
  if [ ! -f "$version_path" ]; then
    return 1
  fi

  # File-existence preservation. Applies on BOTH version-match and version-bump
  # paths: once a repo has been onboarded, the team enriches CLAUDE.md and the
  # knowledge-base/ stubs with service-specific content. A later intellisense version
  # bump must not rewrite or candidate-conflict over that content (no
  # `.intellisense-new.md` files, no regenerated risk-register.md / Step 2.5
  # bootstrap). The escape hatch is `rm .intellisense/version` (forces fresh install) — not --force,
  # which intentionally does NOT override these preservation flags.
  if [ -f "$REPO_PATH/CLAUDE.md" ]; then
    SKIP_CLAUDE_MD_SETUP=true
  fi
  if [ -d "$REPO_PATH/knowledge-base" ]; then
    if [ -f "$REPO_PATH/knowledge-base/00-system-context.md" ] || [ -f "$REPO_PATH/knowledge-base/00-system-architecture.md" ] || [ -f "$REPO_PATH/knowledge-base/02-api-contracts.md" ]; then
      SKIP_DOCS_SETUP=true
    fi
  elif [ -f "$(intellisense_state_path "$REPO_PATH" kb-status)" ]; then
    SKIP_DOCS_SETUP=true
  fi

  STORED_VERSION=$(grep 'INTELLISENSE_VERSION=' "$version_path" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')
  if [ "$STORED_VERSION" = "$INTELLISENSE_VERSION" ]; then
    echo -e "  ${GREEN}[OK]${NC} Version check: $REPO_PATH at v$INTELLISENSE_VERSION (current)"
    return 0
  fi

  echo -e "  ${YELLOW}[WARN]${NC} Version mismatch: v$STORED_VERSION → v$INTELLISENSE_VERSION (upgrade)"

  # Per-artifact prompt before regenerating anything teams may have edited.
  # Default answer is NO (preserve). The user must opt in to regeneration on
  # every version bump — silent overwrite of team-owned content is not OK.
  if [ "$SKIP_CLAUDE_MD_SETUP" = true ]; then
    if _intellisense_prompt_regenerate "CLAUDE.md" "$INTELLISENSE_VERSION"; then
      echo -e "  ${YELLOW}↳ Regenerate CLAUDE.md confirmed — Step 1 will refresh from template${NC}"
      SKIP_CLAUDE_MD_SETUP=false
    else
      echo -e "  ${DIM}↳ Preserving existing CLAUDE.md (Step 1 skipped — team edits kept)${NC}"
    fi
  fi
  if [ "$SKIP_DOCS_SETUP" = true ]; then
    if _intellisense_prompt_regenerate "knowledge-base/" "$INTELLISENSE_VERSION"; then
      echo -e "  ${YELLOW}↳ Regenerate knowledge-base/ confirmed — Step 2 will refresh stubs + risk-register${NC}"
      SKIP_DOCS_SETUP=false
    else
      echo -e "  ${DIM}↳ Preserving existing knowledge-base/ + risk-register.md + Step 2.5 bootstrap (Step 2 skipped)${NC}"
    fi
  fi
  return 1
}

# Helper functions
#
# install_file_safe semantics:
#   - dst missing                                 → copy in (silent install)
#   - dst identical to src                        → no-op (silent skip)
#   - dst differs, --force                        → overwrite + .bak backup
#   - dst differs, not --force, interactive       → prompt: write .intellisense-new
#                                                   candidate? default = NO
#   - dst differs, not --force, non-interactive   → skip silently, log notice
#
# The prompt enforces the same "ask first, default no" policy that gates
# CLAUDE.md / knowledge-base regeneration. Without the prompt, every version
# bump silently sprinkled <file>.intellisense-new candidates next to team-owned
# files — exactly the behavior we want to eliminate. Re-uses
# _intellisense_prompt_regenerate so the env override (INTELLISENSE_REGEN_ANSWER) and
# non-TTY/--non-interactive defaulting are shared with the KB path.
# _rule_pointers LANG_RULE — the managed CLAUDE.md block's rule lines, layered platform → repository:
#   - the language rule from the repository's own .intellisense/rules/ when it has a copy (vendored by
#     `intellisense init`, possibly edited: the repository's override), else the platform's;
#   - nothing for a rule the repository disabled (rules.disable in .intellisense.yml);
#   - the repository's operational rules that differ from the platform's (its overrides), and every
#     organization rule it keeps in .intellisense/rules/organization/.
_rule_pointers() {
  local lang_rule="$1" disabled="" engine f rel
  engine="${INTELLISENSE_BIN:-$HOME/.intellisense/bin/intellisense}"
  [ -x "$engine" ] || engine="$(command -v intellisense 2>/dev/null || true)"
  if [ -n "$engine" ] && [ -f "$REPO_PATH/.intellisense.yml" ]; then
    disabled=" $("$engine" policy get --dir "$REPO_PATH" rules_disable 2>/dev/null) "
  fi
  if [ -n "$lang_rule" ] && [[ "$disabled" != *" language-specific/${lang_rule%.md} "* ]]; then
    if [ -f "$REPO_PATH/.intellisense/rules/language-specific/$lang_rule" ]; then
      printf '@.intellisense/rules/language-specific/%s\n' "$lang_rule"
    else
      printf '@~/.intellisense/rules/language-specific/%s\n' "$lang_rule"
    fi
  fi
  for f in "$REPO_PATH"/.intellisense/rules/operational/*.md; do
    [ -f "$f" ] || continue
    rel="operational/$(basename "$f")"
    [[ "$disabled" == *" ${rel%.md} "* ]] && continue
    if ! diff -q "$f" "$INTELLISENSE_SETUP_DIR/rules/$rel" >/dev/null 2>&1; then
      printf '@.intellisense/rules/%s   (this repository'"'"'s version of ~/.intellisense/rules/%s: follow it where they differ)\n' "$rel" "$rel"
    fi
  done
  for f in "$REPO_PATH"/.intellisense/rules/organization/*.md; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "README.md" ] && continue
    printf '@.intellisense/rules/organization/%s\n' "$(basename "$f")"
  done
}

# _record_template SRC DST — note in .intellisense/templates.json which platform file DST came from and the
# checksum of what was written, so `intellisense live templates update` can later refresh an unedited copy and
# keep an edited one. Best-effort: no jq or no hasher → no record (the update then judges by content).
_record_template() {
  local src="$1" dst="$2" rec="$REPO_PATH/.intellisense/templates.json" sum rel_src rel_dst tmp
  command -v jq >/dev/null 2>&1 || return 0
  # shellcheck source=scripts/lib/hash.sh
  type hb_sha256 >/dev/null 2>&1 || . "$INTELLISENSE_SETUP_DIR/scripts/lib/hash.sh" 2>/dev/null || return 0
  sum="$(hb_sha256 "$dst" 2>/dev/null)" || return 0
  rel_src="${src#"$INTELLISENSE_SETUP_DIR"/}"
  rel_dst="${dst#"$REPO_PATH"/}"
  mkdir -p "$(dirname "$rec")"
  [ -s "$rec" ] || echo '{}' > "$rec"
  tmp="$(mktemp)" || return 0
  if jq --arg d "$rel_dst" --arg s "$rel_src" --arg h "$sum" '.[$d] = {source: $s, sha256: $h}' "$rec" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$rec"
  else
    rm -f "$tmp"
  fi
}

install_file_safe() {
  local SRC="$1" DST="$2" LABEL="$3"
  if [ ! -f "$DST" ]; then
    cp "$SRC" "$DST"
    _record_template "$SRC" "$DST"
    echo -e "${GREEN}✓ INSTALLED${NC} $LABEL"
  elif diff -q "$SRC" "$DST" > /dev/null 2>&1; then
    _record_template "$SRC" "$DST"
    echo -e "${DIM}⊘ SKIPPED${NC} $LABEL (identical — no change needed)"
  elif [ "${FORCE_INSTALL:-false}" = true ]; then
    local BAK="${DST}.bak-$(date +%Y%m%d%H%M%S)"
    cp "$DST" "$BAK"
    cp "$SRC" "$DST"
    _record_template "$SRC" "$DST"
    echo -e "${GREEN}✓ UPDATED${NC} $LABEL (backup: $(basename "$BAK"))"
  else
    if _intellisense_prompt_regenerate "$LABEL ($(basename "$DST"))" "${INTELLISENSE_VERSION:-current}"; then
      cp "$SRC" "${DST}.intellisense-new"
      echo -e "${YELLOW}→ CANDIDATE${NC} $LABEL → ${DST##*/}.intellisense-new (review and apply manually)"
    else
      echo -e "${DIM}⊘ SKIPPED${NC} $LABEL (differs from new template — preserving existing; rerun with --force or accept the prompt to refresh)"
    fi
  fi
}

# Capture the repository's own CLAUDE.md, from before intellisense, as a single canonical original under
# .intellisense/.backup/. Write-once: never overwrites an existing capture, so re-runs by other developers are
# no-ops, and nothing is written at the repository root.
_capture_claude_md_original() {
  local repo="$1"
  local src="$repo/CLAUDE.md"
  [ -f "$src" ] || return 0
  local backup_dir
  backup_dir="$(intellisense_state_dir "$repo")/.backup"
  mkdir -p "$backup_dir"
  local target="$backup_dir/CLAUDE.md.original"
  if [ -e "$target" ]; then
    echo "  ✓ Original CLAUDE.md already preserved at .intellisense/.backup/CLAUDE.md.original (write-once)"
    return 0
  fi
  cp -p "$src" "$target"
  echo "  ✓ Original CLAUDE.md preserved: .intellisense/.backup/CLAUDE.md.original"
}

# Fill deterministic placeholders in a freshly-written CLAUDE.md template.
# Reuses ONLY variables setup-repos.sh already computes — no new parsing,
# no inference. Substitutes:
#   {{SERVICE_NAME}}  → basename of repo (raw, no title-casing)
#   {{STACK_VERSION}} → $GO_VERSION / $PY_VERSION / $PHP_VERSION /
#                       $NG_VERSION / $NODE_VERSION / $REACT_VERSION /
#                       $FLUTTER_SDK
#                       per current $STACK; if empty, falls back to
#                       literal "[version]" (preserving the original human
#                       prompt — never leaves implementation syntax).
#   {{DART_VERSION}}  → $DART_SDK (Flutter only); else "[version]"
# Idempotent: running twice on the same file is a no-op (tokens consumed
# on first call). Portable: uses awk (avoids sed -i flag drift between
# BSD/GNU). Safe for service names containing /, &, spaces, hyphens.
_fill_claude_md_placeholders() {
  local repo="$1" stack="$2"
  local target="$repo/CLAUDE.md"
  [ -f "$target" ] || return 0

  local service_name
  service_name="$(basename "$repo")"

  # Pick the already-computed stack version variable per stack. If empty,
  # fall back to literal "[version]" so the final text reads e.g. "Go [version]"
  # instead of leaving raw "{{STACK_VERSION}}" implementation syntax.
  local stack_version=""
  case "$stack" in
    go)      stack_version="${GO_VERSION:-}" ;;
    python)  stack_version="${PY_VERSION:-}" ;;
    php)     stack_version="${PHP_VERSION:-}" ;;
    angular) stack_version="${NG_VERSION:-}" ;;
    node)    stack_version="${NODE_VERSION:-}" ;;
    react)   stack_version="${REACT_VERSION:-}" ;;
    flutter) stack_version="${FLUTTER_SDK:-}" ;;
  esac
  [ -z "$stack_version" ] && stack_version="[version]"

  # Flutter-only placeholder; falls back to "[version]" when unset
  local dart_version="${DART_SDK:-}"
  [ -z "$dart_version" ] && dart_version="[version]"

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/claude-md-fill.XXXXXX")"
  awk -v sn="$service_name" -v sv="$stack_version" -v dv="$dart_version" '
    {
      gsub(/\{\{SERVICE_NAME\}\}/, sn)
      gsub(/\{\{STACK_VERSION\}\}/, sv)
      gsub(/\{\{DART_VERSION\}\}/, dv)
      print
    }
  ' "$target" > "$tmp" && mv "$tmp" "$target"
}

prepare_path_as_dir() {
  local path="$1" label="$2"
  if [ -f "$path" ]; then
    if [ "${CI:-false}" = "true" ]; then
      echo -e "${RED}✗ ERROR: '$label' path '$path' is a file, not a directory. Cannot continue in CI.${NC}"
      echo -e "  Remove or rename it before running setup."
      exit 1
    fi
    local backup="${path}.backup.$(date +%Y%m%d%H%M%S)"
    echo -e "${YELLOW}⚠ WARNING: '$label' exists as a FILE, not a directory.${NC}"
    echo -e "  Original:  $path"
    echo -e "  Backed up: $backup"
    mv "$path" "$backup"
  fi
}

classify_kb() {
  local kb_path="$REPO_PATH/knowledge-base"

  if [ ! -d "$kb_path" ]; then
    KB_TYPE="new"
    return
  fi

  if [ -f "$(intellisense_state_path "$REPO_PATH" stubs-status)" ]; then
    if [ "$SKIP_DOCS_SETUP" = "true" ]; then
      KB_TYPE="intellisense-current"
    else
      KB_TYPE="intellisense-old"
    fi
    return
  fi

  if grep -rql "<!-- intellisense:" "$kb_path"/ 2>/dev/null; then
    KB_TYPE="intellisense-old"
    return
  fi

  KB_TYPE="non-intellisense"
}

step_risk_scan() {
  local REPO="$1" STACK="$2"
  local KB_FILE="$REPO/risk-register.md"

  # Check if risk-register.md already exists and was auto-generated
  if [ -f "$KB_FILE" ]; then
    if grep -q "Auto-generated by setup-repos.sh" "$KB_FILE" 2>/dev/null; then
      :
    else
      KB_FILE="$REPO/risk-register.intellisense-new.md"
      echo -e "${YELLOW}  ⚠ risk-register.md appears human-edited — wrote risk-register.intellisense-new.md instead${NC}"
    fi
  fi

  # Migration count (fast, always works)
  MIGRATION_COUNT=0
  PROTECTED_ROWS=""
  for migdir in "database/migrations" "db/migrations" "migrations"; do
    if [ -d "$REPO/$migdir" ]; then
      count=$(find "$REPO/$migdir" -type f 2>/dev/null | wc -l)
      [ "$count" -gt 0 ] && PROTECTED_ROWS="${PROTECTED_ROWS}| $migdir | $count files | [SCANNED-PROTECTED] |"$'\n' && MIGRATION_COUNT=$count
    fi
  done
  [ -z "$PROTECTED_ROWS" ] && PROTECTED_ROWS="| [No migration dirs found] | 0 | [OK] |"
  MIGRATION_COUNT=$(echo "$MIGRATION_COUNT" | xargs)  # Trim whitespace

  # Financial/Large file stubs (TODO — full scan deferred)
  FINANCIAL_ROWS="| [TODO — run \`/scan-repo\` for financial keyword audit] | - | [TODO] |"
  LARGE_ROWS="| [TODO — run \`/scan-repo\` for large file analysis] | - | [TODO] |"

  # Write risk-register.md
  cat > "$KB_FILE" << ENDKB
# Risk Register

<!-- Auto-generated by setup-repos.sh. Review and update. -->

## High-Risk Files (financial keywords)
| File | Hits | Tag |
|------|------|-----|
$FINANCIAL_ROWS

## Large Files (>500 lines)
| File | Lines | Tag |
|------|-------|-----|
$LARGE_ROWS

## Protected Paths
| Path | Type | Tag |
|------|------|-----|
$PROTECTED_ROWS

## Migration Count
$MIGRATION_COUNT migration files found.

## Next Steps
- Run \`/scan-repo\` skill to complete financial and large-file audits
- Update this register with findings and review before proceeding
ENDKB

  echo -e "${GREEN}✓ Risk register stub created: $(basename "$KB_FILE")${NC}"
}

# Optional manifest fields teams may add by hand (not written here to avoid
# spurious diffs on re-run — see the preserve-byte-for-byte note above):
#   "policy_minimum_tier": 0|1|2   — repo-level tier floor (effective-tier.sh)
#   "integration_ref": "<remote>/<branch>"
#       The branch this repo's work merges INTO, for the branch-freshness sync
#       gate (scripts/lib/sync-ref.sh). REQUIRED when you integrate into a
#       NON-DEFAULT branch — e.g. a release branch "upstream/release/2.4".
#       Without it the gate infers the upstream default (main/master) and a
#       release-branch repo would be measured against the wrong branch. Must be
#       a real remote/branch that passes `git check-ref-format`.
write_manifest() {
  local repo="$1"
  local stack="$2"
  local components_json="$3"

  ensure_intellisense_state_dir "$repo"
  cat > "$(intellisense_state_path "$repo" manifest)" << EOF
{
  "intellisense_manifest_version": "1",
  "stack": "$stack",
  "components": $components_json
}
EOF
}

# Ensure the repo's .gitignore lists ALL per-developer intellisense state files. Without
# this, a team lead running `setup-repos.sh` followed by `git add . && git push`
# would leak their session uuids, classification.json, usage.json, token cursor,
# and various status reports into the repo's history — and cloning devs would
# inherit them, breaking the heartbeat (sees the team lead's files as their own).
#
# Existing setup wrote only `.beads/` (line 1711), `.code-review-graph/` and
# `.intellisense/graph-status.json` (scripts/lib/intellisense-graph.sh). This function fills
# the gap with the remaining .intellisense/* per-dev paths. Idempotent — re-runs add
# nothing if the entry is already present.
intellisense_ensure_repo_gitignore() {
  local repo="$1"
  local gi="$repo/.gitignore"
  [ -f "$gi" ] || touch "$gi"

  # All intellisense per-dev paths that must never be committed.
  # NOTE: .intellisense/MANAGED, .intellisense/version, .intellisense/manifest.json are team-shared and
  # NOT listed here — they intentionally do travel via git.
  local needed=(
    ".intellisense/session/"
    ".intellisense/local.json"
    ".intellisense/kb-status.md"
    ".intellisense/stubs-status.json"
    ".intellisense/existing-knowledge-report.md"
  )

  local missing=()
  local e
  for e in "${needed[@]}"; do
    # Match exact line (anchored), tolerating leading/trailing whitespace
    local pattern
    pattern=$(printf '%s' "$e" | sed 's/[][\\.^$*]/\\&/g')
    if ! grep -qE "^[[:space:]]*${pattern}[[:space:]]*$" "$gi" 2>/dev/null; then
      missing+=("$e")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    {
      # Only add the comment header on first time the block is appended —
      # detected by checking whether ANY intellisense per-dev marker comment is already
      # present (handles the case of a partial earlier setup).
      if ! grep -qE '^# ── intellisense: per-developer state' "$gi" 2>/dev/null; then
        echo ""
        echo "# ── intellisense: per-developer state (never committed) ──"
      fi
      printf '%s\n' "${missing[@]}"
    } >> "$gi"
    echo -e "  ${GREEN}[UPDATED]${NC} $gi — added ${#missing[@]} intellisense per-dev entry(ies)"
  fi
}

write_local() {
  local repo="$1"
  local intellisense_path="$2"
  local version="$3"
  local date_now

  date_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  ensure_intellisense_state_dir "$repo"
  cat > "$(intellisense_state_path "$repo" local)" << EOF
{
  "intellisense_setup_path": "$intellisense_path",
  "installed_by": "$(whoami)",
  "installed_date": "$date_now",
  "intellisense_version": "$version"
}
EOF
}

# Validation
if [ -z "$REPO_PATH" ]; then
  echo -e "${RED}ERROR: --repo path required${NC}"
  echo "Usage: $0 --repo /path/to/repo --stack go|php|angular|python|node|react|java|flutter|rust|csharp|ruby|swift|cpp [--skip-claude-md] [--skip-ci] [--auto-commit]"
  exit 1
fi

if [ -z "$STACK" ]; then
  echo -e "${RED}ERROR: --stack go|php|angular|python|node|react|java|flutter|rust|csharp|ruby|swift|cpp required${NC}"
  exit 1
fi

# Resolve to absolute path
REPO_PATH=$(cd "$REPO_PATH" && pwd)

if [ ! -d "$REPO_PATH" ]; then
  echo -e "${RED}ERROR: Repository not found: $REPO_PATH${NC}"
  exit 1
fi

if [ ! -e "$REPO_PATH/.git" ]; then
  echo -e "${RED}ERROR: Not a git repository: $REPO_PATH${NC}"
  exit 1
fi

# Validate stack
# Includes graph-'unsupported' stacks (vue) so users can reach the graph
# bootstrap exception flow documented in @rules/operational/graph-supported-stacks.md.
# When STACK is unsupported, the template/docs/CI steps are auto-skipped (see below)
# and the graph bootstrap section either errors with the standard
# remediation (no --graph-exception) or writes the exception JSON + readiness=skipped.
case "$STACK" in
  go|php|angular|python|node|react|vue|java|flutter|rust|csharp|ruby|swift|cpp)
    ;;
  *)
    echo -e "${RED}ERROR: Invalid stack. Must be one of: go, php, angular, python, node, react, vue, java, flutter, rust, csharp, ruby, swift, cpp${NC}"
    echo -e "  See @rules/operational/graph-supported-stacks.md for classification."
    echo -e "  Other languages: use Core mode's custom_stacks (intellisense init), or file an issue to add a template."
    exit 1
    ;;
esac

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}setup-repos.sh — Initialize Documentation${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "Repository: $REPO_PATH"
echo "Stack:      $STACK"
echo "intellisense:       v$INTELLISENSE_VERSION"
echo ""
echo -e "${DIM}This script will (in addition to docs/CI):${NC}"
echo -e "${DIM}  • chain intellisense's pre-push hook (and initialize .beads/ when the tracker is beads)${NC}"
echo -e "${DIM}  • bootstrap code-review-graph per the stack's classification (when code intelligence is code-review-graph)${NC}"
echo -e "${DIM}    (mandatory-supported = hard-fail; weak/candidate = best-effort;${NC}"
echo -e "${DIM}     unsupported = declined without --graph-exception).${NC}"
echo -e "${DIM}  Stack classifications: rules/operational/graph-supported-stacks.md${NC}"
echo ""

# Check version and determine what to skip
# Capture the result: VERSION_MATCH is the canonical signal that this repo
# is already configured at the current intellisense version. Downstream blocks
# (especially the tracked-file writes at the bottom of the script) need
# this signal directly, not via the SKIP_CLAUDE_MD_SETUP flag — that flag
# is also gated on CLAUDE.md existing on disk, which can be false when
# --skip-claude-md was passed even on a version-matched repo.
VERSION_MATCH=false
if check_repo_version; then
  VERSION_MATCH=true
fi

# Graph-unsupported-stack auto-skip: stacks classified 'unsupported' (currently vue)
# don't have CLAUDE.md/CI templates and aren't expected to. Auto-skip those steps so
# the script can reach the graph bootstrap section, which either errors with
# the standard remediation (when --graph-exception is missing) or writes the
# exception JSON + readiness=skipped (when --graph-exception is provided).
if [ "$(intellisense_graph_stack_support "$STACK")" = "unsupported" ]; then
  echo -e "${YELLOW}ℹ Stack '$STACK' is classified 'unsupported' for graph use.${NC}"
  echo -e "  Skipping template/knowledge-base/CI steps — routing to graph bootstrap."
  SKIP_CLAUDE_MD_SETUP=true
  SKIP_DOCS_SETUP=true
  SKIP_CI=true
fi
echo ""

# Step 1: Handle existing CLAUDE.md. Skipped silently on version-match.
# On version-bump the user is prompted by check_repo_version() with default=no;
# if they decline, SKIP_CLAUDE_MD_SETUP stays true and we land here.
if [ "$SKIP_CLAUDE_MD_SETUP" = true ]; then
  echo -e "${BLUE}→ Step 1: Handle existing CLAUDE.md${NC}"
  echo -e "  ${DIM}[SKIPPED] CLAUDE.md already present — preserving team edits${NC}"
  echo -e "  ${DIM}To regenerate, accept the prompt on the next version bump,${NC}"
  echo -e "  ${DIM}or set INTELLISENSE_REGEN_ANSWER=yes for the next run.${NC}"
  # Bookkeeping: on a re-run the manifest is rebuilt from
  # INSTALLED_COMPONENTS. We're skipping work because the component is already
  # installed, so record it here — otherwise the rebuilt manifest would
  # claim claude-md is missing.
  INSTALLED_COMPONENTS+=("claude-md")
  echo ""
elif [ ! -f "$REPO_PATH/CLAUDE.md" ]; then
  if [ "$SKIP_CLAUDE_MD" = true ]; then
    echo -e "${YELLOW}⚠️  CLAUDE.md not found (--skip-claude-md set, skipping)${NC}"
  else
    echo -e "${BLUE}→ Step 1: Copy intellisense CLAUDE.md template ($STACK stack)${NC}"

    # Determine template path
    TEMPLATE_PATH="$INTELLISENSE_SETUP_DIR/templates/CLAUDE.md.${STACK}.template"

    if [ ! -f "$TEMPLATE_PATH" ]; then
      echo -e "${RED}ERROR: Template not found: $TEMPLATE_PATH${NC}"
      exit 1
    fi

    cp "$TEMPLATE_PATH" "$REPO_PATH/CLAUDE.md"
    echo -e "${GREEN}✓ CLAUDE.md copied (placeholders will be filled after stack detection)${NC}"
    INSTALLED_COMPONENTS+=("claude-md")
    CLAUDE_TEMPLATE_WRITTEN=true
  fi
else
  # Analyze existing CLAUDE.md to suggest appropriate action
  HAS_INTELLISENSE_RULES=false
  HAS_LANG_RULES=false
  HAS_WORKFLOW_RULES=false

  if grep -q "intellisense:BEGIN\|@.*rules/.*" "$REPO_PATH/CLAUDE.md"; then
    HAS_INTELLISENSE_RULES=true
  fi
  if grep -q "go-patterns\|laravel-patterns\|angular-patterns\|python-patterns" "$REPO_PATH/CLAUDE.md"; then
    HAS_LANG_RULES=true
  fi
  if grep -Eq '^@.*rules/operational/development-workflow[.]md[[:space:]]*$' "$REPO_PATH/CLAUDE.md"; then
    HAS_WORKFLOW_RULES=true
  fi

  # Skip maturity scoring for intellisense source repo
  CANONICAL_REPO=$(realpath "$REPO_PATH" 2>/dev/null || echo "$REPO_PATH")
  CANONICAL_INTELLISENSE=$(realpath "${INTELLISENSE_SETUP_DIR:-.}" 2>/dev/null || echo "${INTELLISENSE_SETUP_DIR:-.}")
  if [[ "$CANONICAL_REPO" == "$CANONICAL_INTELLISENSE" ]]; then
    echo -e "${YELLOW}  ⚠ Skipping maturity scoring for INTELLISENSE_SETUP source repo — scorecard applies to target service repos only.${NC}"
    MATURITY_LEVEL="platform"  # sentinel, not numeric
  else
    # Compute maturity level from heading count
    HEADING_COUNT=$(grep -c '^## ' "$REPO_PATH/CLAUDE.md" 2>/dev/null || echo 0)
    if [ "$HEADING_COUNT" -lt 10 ]; then
      MATURITY_LEVEL=1
    elif [ "$HEADING_COUNT" -lt 30 ]; then
      MATURITY_LEVEL=2
    else
      MATURITY_LEVEL=3
    fi
  fi

  echo -e "${BLUE}→ Step 1: Handle existing CLAUDE.md${NC}"
  echo "  Analyzing existing CLAUDE.md..."
  echo "    • intellisense rules block: $([ "$HAS_INTELLISENSE_RULES" = true ] && echo "present" || echo "not found")"
  echo "    • Language-specific rules: $([ "$HAS_LANG_RULES" = true ] && echo "present" || echo "missing")"
  echo "    • Workflow rules: $([ "$HAS_WORKFLOW_RULES" = true ] && echo "present" || echo "missing")"
  echo ""

  # Determine recommendation (maturity-aware).
  # MATURITY_LEVEL is either 1/2/3 (numeric) or the sentinel "platform" for the
  # intellisense source repo. Match the platform sentinel before any numeric comparison
  # so [ "platform" -ge 3 ] never runs (would error under set -e).
  if [ "$HAS_INTELLISENSE_RULES" = true ] && [ "$HAS_LANG_RULES" = true ] && [ "$HAS_WORKFLOW_RULES" = true ]; then
    RECOMMENDED="skip"
    REASON="All intellisense rules already present"
  elif [ "$MATURITY_LEVEL" = "platform" ]; then
    RECOMMENDED="skip"
    REASON="intellisense source repo — recommendation N/A (scorecard applies to service repos only)"
  elif [ "$MATURITY_LEVEL" -ge 3 ]; then
    RECOMMENDED="inject"
    REASON="Mature repo ($HEADING_COUNT headings) — defaulting to inject to preserve native rules"
  elif [ "$MATURITY_LEVEL" -eq 2 ] && [ "$HAS_INTELLISENSE_RULES" = false ]; then
    RECOMMENDED="adopt"
    REASON="Medium complexity repo ($HEADING_COUNT headings) — adopt will extract protocol sections and inject intellisense"
  elif [ "$MATURITY_LEVEL" -eq 1 ]; then
    RECOMMENDED="inject"
    REASON="Thin CLAUDE.md ($HEADING_COUNT headings) — inject will add intellisense rules"
  else
    RECOMMENDED="inject"
    REASON="Some intellisense rules missing; inject will add missing blocks"
  fi

  if [ "$MATURITY_LEVEL" != "platform" ] && [ "$MATURITY_LEVEL" -ge 3 ] && [ "$RECOMMENDED" = "inject" ]; then
    echo -e "${YELLOW}  ⚠ Mature repo detected (Level 3+, $HEADING_COUNT headings). Defaulting to 'inject' to preserve repo-native rules.${NC}"
  fi

  echo "  Suggestion: $RECOMMENDED — $REASON"

  if [ -n "$CLAUDE_MD_ACTION" ]; then
    CLAUDE_ACTION="$CLAUDE_MD_ACTION"
  elif $INTERACTIVE; then
    read -p "  Choose action? (replace/inject/adopt/skip) [$RECOMMENDED]: " CLAUDE_ACTION
    CLAUDE_ACTION=${CLAUDE_ACTION:-$RECOMMENDED}
  elif [ "$SKIP_CLAUDE_MD" = true ]; then
    CLAUDE_ACTION="skip"
  else
    CLAUDE_ACTION="$RECOMMENDED"
  fi

  if [ "$CLAUDE_ACTION" = "replace" ]; then
    _capture_claude_md_original "$REPO_PATH"
    rm "$REPO_PATH/CLAUDE.md"

    # Copy fresh template
    TEMPLATE_PATH="$INTELLISENSE_SETUP_DIR/templates/CLAUDE.md.${STACK}.template"
    if [ ! -f "$TEMPLATE_PATH" ]; then
      echo -e "${RED}ERROR: Template not found: $TEMPLATE_PATH${NC}"
      exit 1
    fi
    cp "$TEMPLATE_PATH" "$REPO_PATH/CLAUDE.md"
    echo -e "${GREEN}✓ CLAUDE.md replaced with intellisense template (placeholders filled after stack detection)${NC}"
    INSTALLED_COMPONENTS+=("claude-md")
    CLAUDE_TEMPLATE_WRITTEN=true
  elif [ "$CLAUDE_ACTION" = "inject" ]; then
    if grep -q "intellisense:BEGIN" "$REPO_PATH/CLAUDE.md"; then
      # Update existing intellisense block on re-run — preserve everything outside markers
      echo "  ℹ intellisense rules block already present (updating inside markers)"

      # Map stack to language-specific rule file
      case "$STACK" in
        go)      LANG_RULE="go-patterns.md" ;;
        php)     LANG_RULE="laravel-patterns.md" ;;
        angular) LANG_RULE="angular-patterns.md" ;;
        python)  LANG_RULE="python-patterns.md" ;;
        node)    LANG_RULE="node-patterns.md" ;;
        react)   LANG_RULE="react-patterns.md" ;;
        java)    LANG_RULE="java-patterns.md" ;;
        flutter) LANG_RULE="flutter-patterns.md" ;;
        rust)    LANG_RULE="rust-patterns.md" ;;
        csharp)  LANG_RULE="csharp-patterns.md" ;;
        ruby)    LANG_RULE="ruby-patterns.md" ;;
        swift)   LANG_RULE="swift-patterns.md" ;;
        cpp)     LANG_RULE="cpp-patterns.md" ;;
        *)       LANG_RULE="" ;;
      esac

      # Extract content before and after markers
      BEFORE_MARKER=$(sed '/<!-- intellisense:BEGIN -->/,$d' "$REPO_PATH/CLAUDE.md")
      AFTER_MARKER=$(sed '1,/<!-- intellisense:END -->/d' "$REPO_PATH/CLAUDE.md")

      # Generate fresh intellisense block
      INTELLISENSE_BLOCK=$(
        printf '<!-- intellisense:BEGIN -->\n'
        printf '## intellisense Rule Pointers\n\n'
        _rule_pointers "$LANG_RULE"
        printf '<!-- intellisense:END -->'
      )

      # Reconstruct file: before + markers + after
      {
        printf '%s' "$BEFORE_MARKER"
        printf '\n%s\n' "$INTELLISENSE_BLOCK"
        printf '%s' "$AFTER_MARKER"
      } > "$REPO_PATH/CLAUDE.md"

      echo -e "${GREEN}✓ intellisense rules block updated inside markers${NC}"
      INSTALLED_COMPONENTS+=("claude-md")
    else
      # First run — inject new block
      # Map stack to language-specific rule file
      case "$STACK" in
        go)      LANG_RULE="go-patterns.md" ;;
        php)     LANG_RULE="laravel-patterns.md" ;;
        angular) LANG_RULE="angular-patterns.md" ;;
        python)  LANG_RULE="python-patterns.md" ;;
        node)    LANG_RULE="node-patterns.md" ;;
        react)   LANG_RULE="react-patterns.md" ;;
        java)    LANG_RULE="java-patterns.md" ;;
        flutter) LANG_RULE="flutter-patterns.md" ;;
        rust)    LANG_RULE="rust-patterns.md" ;;
        csharp)  LANG_RULE="csharp-patterns.md" ;;
        ruby)    LANG_RULE="ruby-patterns.md" ;;
        swift)   LANG_RULE="swift-patterns.md" ;;
        cpp)     LANG_RULE="cpp-patterns.md" ;;
        *)       LANG_RULE="" ;;
      esac
      {
        printf '\n\n<!-- intellisense:BEGIN -->\n'
        printf '## intellisense Rule Pointers\n\n'
        _rule_pointers "$LANG_RULE"
        printf '<!-- intellisense:END -->\n'
      } >> "$REPO_PATH/CLAUDE.md"
      echo -e "${GREEN}✓ intellisense rules block injected into existing CLAUDE.md${NC}"
      INSTALLED_COMPONENTS+=("claude-md")
    fi
  elif [ "$CLAUDE_ACTION" = "adopt" ]; then
    echo "  Starting adoption workflow..."

    # Preserve original CLAUDE.md once at .intellisense/.backup/CLAUDE.md.original
    # (write-once; never overwrites). adopt rewrites the file in place but
    # does NOT trigger placeholder filling — content is human-authored, not
    # template-generated.
    _capture_claude_md_original "$REPO_PATH"

    # Create knowledge-base/ directory if not present
    mkdir -p "$REPO_PATH/knowledge-base"

    # Define protocol headings that intellisense should manage
    PROTOCOL_HEADINGS=(
      "Execution Mode"
      "Change Contract"
      "Mandatory Execution Phases"
      "Agent Pipeline"
      "Dev Protocol"
      "Write Protection"
      "Risk & Confidence"
      "QA Mode"
      "PR Review Mode"
    )

    # Headings that are ambiguous — could be protocol or domain knowledge
    UNCERTAIN_HEADINGS=(
      "Phase"
      "Gate"
      "Contract"
      "Protocol"
      "Rule"
      "Mode"
      "Pipeline"
      "Guard"
      "Execution"
    )

    # Extract protocol sections to migration-review.md (repo root — not KB)
    MIGRATION_FILE="$REPO_PATH/migration-review.md"
    if [ ! -f "$MIGRATION_FILE" ]; then
      {
        echo "# CLAUDE.md Migration Review"
        echo ""
        echo "This file contains sections extracted from the original CLAUDE.md during intellisense adoption."
        echo "Review each extracted section and decide whether to:"
        echo "- Keep it in knowledge-base/ (move to appropriate KB file)"
        echo "- Delete it (already covered by intellisense protocol)"
        echo "- Archive it in REPO_CONTEXT (domain knowledge)"
        echo ""
        echo "---"
        echo ""
      } > "$MIGRATION_FILE"
    fi

    # Extract protocol sections
    in_protocol_section=0
    in_uncertain_section=0
    current_section=""
    uncertain_section_buf=""

    while IFS= read -r line; do
      # Check if line starts with ## heading
      if [[ $line =~ ^##\ (.+)$ ]]; then
        heading="${BASH_REMATCH[1]}"
        is_protocol=0
        is_uncertain=0

        for protocol in "${PROTOCOL_HEADINGS[@]}"; do
          if [[ "$heading" == *"$protocol"* ]]; then
            is_protocol=1
            break
          fi
        done

        if [ $is_protocol -eq 0 ]; then
          for uncertain in "${UNCERTAIN_HEADINGS[@]}"; do
            if [[ "$heading" == *"$uncertain"* ]]; then
              is_uncertain=1
              break
            fi
          done
        fi

        if [ $is_protocol -eq 1 ]; then
          current_section="$heading"
          echo "" >> "$MIGRATION_FILE"
          echo "## $heading" >> "$MIGRATION_FILE"
          echo "<!-- TODO: Review extracted section during adoption -->" >> "$MIGRATION_FILE"
          echo "" >> "$MIGRATION_FILE"
          in_protocol_section=1
          in_uncertain_section=0
          uncertain_section_buf=""
          continue
        elif [ $is_uncertain -eq 1 ]; then
          in_protocol_section=0
          in_uncertain_section=1
          uncertain_section_buf="$heading"
          continue
        else
          # Flush uncertain buffer — write to migration-review.md as UNCERTAIN
          if [ -n "$uncertain_section_buf" ]; then
            echo "" >> "$MIGRATION_FILE"
            echo "## $uncertain_section_buf" >> "$MIGRATION_FILE"
            echo "<!-- UNCERTAIN: May be protocol or domain knowledge — review before deleting -->" >> "$MIGRATION_FILE"
            echo "" >> "$MIGRATION_FILE"
            uncertain_section_buf=""
          fi
          in_protocol_section=0
          in_uncertain_section=0
        fi
      fi

      if [ $in_protocol_section -eq 1 ]; then
        echo "$line" >> "$MIGRATION_FILE"
      elif [ $in_uncertain_section -eq 1 ]; then
        # Check for financial/security keywords — preserve in REPO_CONTEXT instead
        if echo "$line" | grep -qiE 'payment|account|invoice|balance|tax|refund|security|auth'; then
          in_uncertain_section=0
          uncertain_section_buf=""
        fi
      fi
    done < "$REPO_PATH/CLAUDE.md"

    # Flush remaining uncertain buffer
    if [ -n "$uncertain_section_buf" ]; then
      echo "" >> "$MIGRATION_FILE"
      echo "## $uncertain_section_buf" >> "$MIGRATION_FILE"
      echo "<!-- UNCERTAIN: May be protocol or domain knowledge — review before deleting -->" >> "$MIGRATION_FILE"
      echo "" >> "$MIGRATION_FILE"
    fi

    # Rewrite CLAUDE.md with intellisense and REPO_CONTEXT markers
    TEMP_CLAUDE=$(mktemp)

    # Copy domain sections (not protocol sections) into REPO_CONTEXT block
    {
      echo "<!-- REPO_CONTEXT:BEGIN — Original domain knowledge from service repo -->"
      echo ""

      in_protocol=0
      in_uncertain_ctx=0
      uncertain_buf_ctx=""
      uncertain_lines_ctx=()
      while IFS= read -r line; do
        if [[ $line =~ ^##\ (.+)$ ]]; then
          heading="${BASH_REMATCH[1]}"
          is_protocol=0
          is_uncertain_ctx=0

          for protocol in "${PROTOCOL_HEADINGS[@]}"; do
            if [[ "$heading" == *"$protocol"* ]]; then
              is_protocol=1
              break
            fi
          done

          if [ $is_protocol -eq 0 ]; then
            for uncertain in "${UNCERTAIN_HEADINGS[@]}"; do
              if [[ "$heading" == *"$uncertain"* ]]; then
                is_uncertain_ctx=1
                break
              fi
            done
          fi

          if [ $is_protocol -eq 1 ]; then
            # Flush any accumulated uncertain lines — they become REPO_CONTEXT if financial
            if [ ${#uncertain_lines_ctx[@]} -gt 0 ]; then
              echo ""
              echo "## $uncertain_buf_ctx"
              echo "<!-- PRESERVED: financial/security domain knowledge -->"
              for ul in "${uncertain_lines_ctx[@]}"; do echo "$ul"; done
            fi
            uncertain_buf_ctx=""
            uncertain_lines_ctx=()
            in_protocol=1
            in_uncertain_ctx=0
            continue
          elif [ $is_uncertain_ctx -eq 1 ]; then
            # Flush previous uncertain if any
            if [ -n "$uncertain_buf_ctx" ] && [ ${#uncertain_lines_ctx[@]} -gt 0 ]; then
              echo ""
              echo "## $uncertain_buf_ctx"
              echo "<!-- PRESERVED: financial/security domain knowledge -->"
              for ul in "${uncertain_lines_ctx[@]}"; do echo "$ul"; done
            fi
            in_protocol=0
            in_uncertain_ctx=1
            uncertain_buf_ctx="$heading"
            uncertain_lines_ctx=()
            continue
          else
            # Flush uncertain buffer — only emit if financial/security keywords found
            if [ -n "$uncertain_buf_ctx" ] && [ ${#uncertain_lines_ctx[@]} -gt 0 ]; then
              echo ""
              echo "## $uncertain_buf_ctx"
              echo "<!-- PRESERVED: financial/security domain knowledge -->"
              for ul in "${uncertain_lines_ctx[@]}"; do echo "$ul"; done
            fi
            uncertain_buf_ctx=""
            uncertain_lines_ctx=()
            in_protocol=0
            in_uncertain_ctx=0
            echo ""
          fi
        fi

        if [ $in_protocol -eq 0 ] && [ $in_uncertain_ctx -eq 0 ]; then
          echo "$line"
        elif [ $in_uncertain_ctx -eq 1 ]; then
          # Only keep uncertain lines that contain financial/security keywords
          if echo "$line" | grep -qiE 'payment|account|invoice|balance|tax|refund|security|auth'; then
            uncertain_lines_ctx+=("$line")
          fi
        fi
      done < "$REPO_PATH/CLAUDE.md"

      # Flush any remaining uncertain buffer
      if [ -n "$uncertain_buf_ctx" ] && [ ${#uncertain_lines_ctx[@]} -gt 0 ]; then
        echo ""
        echo "## $uncertain_buf_ctx"
        echo "<!-- PRESERVED: financial/security domain knowledge -->"
        for ul in "${uncertain_lines_ctx[@]}"; do echo "$ul"; done
      fi

      echo ""
      echo "<!-- REPO_CONTEXT:END -->"
      echo ""

      # Add intellisense block (v4.0 format)
      echo ""
      echo "## intellisense Rule Pointers"
      echo ""
      echo "All execution protocol is governed by intellisense global rules. This file does NOT restate them."
      echo ""
      echo "**Always loaded** (via symlink, no action needed):"
      echo "- \`~/.claude/rules/baseline/security.md\` — Security checks, PII rules, pre-commit checklist"
      echo "- \`~/.intellisense/rules/operational/development-workflow.md\` — Mode detection, Phase 0-1"
      echo ""
      echo "**Loaded when coding (Phase 2+ only)**:"
      echo "- \`~/.intellisense/rules/operational/development-workflow-impl.md\` — Phases 2-6, gates, TDD, commits, PRs"

      case "$STACK" in
        go)      LANG_RULE="go-patterns.md" ;;
        php)     LANG_RULE="laravel-patterns.md" ;;
        angular) LANG_RULE="angular-patterns.md" ;;
        python)  LANG_RULE="python-patterns.md" ;;
        node)    LANG_RULE="node-patterns.md" ;;
        react)   LANG_RULE="react-patterns.md" ;;
        java)    LANG_RULE="java-patterns.md" ;;
        flutter) LANG_RULE="flutter-patterns.md" ;;
        rust)    LANG_RULE="rust-patterns.md" ;;
        csharp)  LANG_RULE="csharp-patterns.md" ;;
        ruby)    LANG_RULE="ruby-patterns.md" ;;
        swift)   LANG_RULE="swift-patterns.md" ;;
        cpp)     LANG_RULE="cpp-patterns.md" ;;
        *)       LANG_RULE="" ;;
      esac

      if [ -n "$LANG_RULE" ]; then
        echo "- \`~/.intellisense/rules/language-specific/$LANG_RULE\` — Naming, patterns, framework rules"
      fi
      echo ""
      echo "> This file does not describe phases, gates, approval flows, naming conventions, or security rules."
      echo "> Those live in the files above and are applied automatically."
    } > "$TEMP_CLAUDE"

    mv "$TEMP_CLAUDE" "$REPO_PATH/CLAUDE.md"
    echo -e "${GREEN}✓ CLAUDE.md rewritten with intellisense/REPO_CONTEXT markers${NC}"
    echo -e "${GREEN}✓ Protocol sections extracted to: migration-review.md${NC}"
  else
    echo "  ℹ Keeping existing CLAUDE.md unchanged (proceeding with knowledge-base/CI setup)"
  fi
fi

echo ""

# Guard: knowledge-base must be a directory (not a file) before any step runs
prepare_path_as_dir "$REPO_PATH/knowledge-base" "knowledge-base"

# Classify existing knowledge-base state for Step 2 behavior
classify_kb
echo -e "  ${DIM}KB classification: $KB_TYPE${NC}"

# Step 2: Create knowledge-base/ directory with stub files. Skipped silently
# on version-match. On version-bump the user is prompted by check_repo_version()
# with default=no; if they decline, SKIP_DOCS_SETUP stays true and Step 2.5
# (CLAUDE.md bootstrap) + risk-register auto-write also short-circuit since
# they live inside this same else branch.
if [ "$SKIP_DOCS_SETUP" = true ]; then
  echo -e "${BLUE}→ Step 2: Create knowledge-base/ directory with documentation stubs${NC}"
  echo -e "  ${DIM}[SKIPPED] knowledge-base/ already populated — preserving team-enriched files${NC}"
  echo -e "  ${DIM}To regenerate, accept the prompt on the next version bump,${NC}"
  echo -e "  ${DIM}or set INTELLISENSE_REGEN_ANSWER=yes for the next run.${NC}"
  # Bookkeeping: see Step 1 SKIP comment — record component so upgrade-time
  # manifest rewrite stays accurate.
  INSTALLED_COMPONENTS+=("knowledge-base")
  echo ""
else
  echo -e "${BLUE}→ Step 2: Create knowledge-base/ directory with documentation stubs${NC}"
  mkdir -p "$REPO_PATH/knowledge-base"
  echo -e "${GREEN}✓ knowledge-base/ directory ready${NC}"
  INSTALLED_COMPONENTS+=("knowledge-base")

  # Copy stub files to show what will be generated
  STUB_DIR="$INTELLISENSE_SETUP_DIR/templates/knowledge-base"

if [ -d "$STUB_DIR" ]; then
  [ "$KB_TYPE" = "non-intellisense" ] && \
    echo -e "  ${YELLOW}⚠ Non-intellisense knowledge-base detected — adding intellisense files conservatively${NC}"
  for stub_file in "$STUB_DIR"/*.stub.md; do
    if [ -f "$stub_file" ]; then
      stub_name=$(basename "$stub_file" .stub.md)
      target_file="$REPO_PATH/knowledge-base/${stub_name}.md"

      if [ -f "$target_file" ] && ! grep -q "<!-- intellisense:" "$target_file" 2>/dev/null; then
        if [ "${FORCE_INSTALL:-false}" = true ]; then
          # --force: overwrite marker-less stubs with the current templates
          cp "$stub_file" "$target_file"
          echo -e "  ${GREEN}✓ OVERWRITE${NC} ${stub_name}.md (--force, added intellisense marker)"
        else
          # Existing non-intellisense file: write candidate, never overwrite
          cp "$stub_file" "${target_file%.md}.intellisense-new.md"
          echo -e "  ${YELLOW}→ CONFLICT${NC} ${stub_name}.md has no intellisense marker — wrote ${stub_name}.intellisense-new.md"
        fi
      elif [ ! -f "$target_file" ] || grep -q '{{.*}}' "$target_file" 2>/dev/null; then
        cp "$stub_file" "$target_file"
      fi
    fi
  done
  echo "  Documentation stubs created:"
  echo "    • source-tree-analysis.md      (directory tree + structural analysis)"
  echo "    • 00-system-context.md          (tables, endpoints, patterns — auto-loaded)"
  echo "    • 02-api-contracts.md           (endpoint catalog)"
  echo "    • architecture-overview.md      (component diagrams + data flow)"
else
  echo -e "${YELLOW}⚠️  Stub templates not found in: $STUB_DIR${NC}"
fi

  # Scan repo for risk indicators and generate risk-register.md
  step_risk_scan "$REPO_PATH" "$STACK"

echo ""

# Step 2.5: Bootstrap CLAUDE.md with scanned repo structure
echo -e "${BLUE}→ Step 2.5: Bootstrap CLAUDE.md with scanned repo data${NC}"
BOOTSTRAP_FILE="$REPO_PATH/.intellisense-bootstrap.md"
TODAY=$(date +%Y-%m-%d)

# Detect stack version and ORM
STACK_DETECTED=""
ORM_DETECTED=""
MIGRATION_TOOL=""
DIRS_FOUND=""
KEY_FILES=""
DEPS_FOUND=""

# Count source files matching find primaries; never recurses past caller's -maxdepth.
scan_dir_count() {
  local dir="$1"; shift
  find "$dir" "$@" -type f 2>/dev/null | wc -l | tr -d ' '
}

# Emit "<relpath><TAB><lines>" for the largest matching file under $dir, or nothing.
# Keeps the full path so subdir matches (Python -maxdepth 2) don't get mis-resolved.
# Uses sed to strip "<spaces><count><spaces>" prefix from `wc -l` output instead
# of awk '{print $2}' so paths containing spaces survive extraction.
scan_dir_largest() {
  local repo="$1" dir="$2"; shift 2
  local path lines
  path=$(find "$dir" "$@" -type f -exec wc -l {} \; 2>/dev/null \
    | sort -rn | head -1 | sed -E 's/^[[:space:]]*[0-9]+[[:space:]]+//')
  [ -n "$path" ] && [ -f "$path" ] || return 0
  lines=$(wc -l < "$path" 2>/dev/null || echo 0)
  printf '%s\t%s\n' "${path#$repo/}" "$lines"
}

# Run the two stack scans given dir lists and find primaries.
# $1=repo root, $2=space-separated scan dirs, $3=space-separated largest dirs (may be empty),
# $4+=find primaries (e.g. -maxdepth 1 -name "*.go" ! -name "*_test.go").
run_stack_scans() {
  local repo="$1" scan_dirs="$2" largest_dirs="$3"; shift 3
  local dir count rel lines result
  for dir in $scan_dirs; do
    [ -d "$repo/$dir" ] || continue
    count=$(scan_dir_count "$repo/$dir" "$@")
    [ "$count" -gt 0 ] && DIRS_FOUND="${DIRS_FOUND}[SCANNED 95%] $dir/ — $count files (source: ls)\n"
  done
  for dir in $largest_dirs; do
    [ -d "$repo/$dir" ] || continue
    result=$(scan_dir_largest "$repo" "$repo/$dir" "$@") || continue
    [ -n "$result" ] || continue
    rel="${result%	*}"
    lines="${result##*	}"
    KEY_FILES="${KEY_FILES}[SCANNED 65%] $rel — $lines lines (source: file inspection)\n"
  done
}

if [ "$STACK" = "go" ] && [ -f "$REPO_PATH/go.mod" ]; then
  # Tolerate go.mod files without a 'go N.M' directive (some hand-crafted or
  # very old modules lack it). Without `|| true`, set -o pipefail propagates
  # grep's exit-1 from a no-match through the command substitution and trips
  # set -e, aborting Step 2.5 silently.
  GO_VERSION=$(grep "^go " "$REPO_PATH/go.mod" 2>/dev/null | awk '{print $2}' || true)
  STACK_DETECTED="[SCANNED 95%] Go ${GO_VERSION:-1.x}"

  if grep -q "gorm.io/gorm" "$REPO_PATH/go.sum" 2>/dev/null; then
    ORM_DETECTED="[SCANNED 80%] ORM: GORM (source: go.sum → gorm.io/gorm)"
  fi
  if grep -q "gobuffalo/pop" "$REPO_PATH/go.sum" 2>/dev/null; then
    [ -n "$ORM_DETECTED" ] && ORM_DETECTED="${ORM_DETECTED} + Pop"
    [ -z "$ORM_DETECTED" ] && ORM_DETECTED="[SCANNED 80%] ORM: Pop/Buffalo (source: go.sum → gobuffalo/pop)"
  fi

  run_stack_scans "$REPO_PATH" \
    "handlers services models repository middleware jobs tests cmd" \
    "handlers services models repository" \
    -maxdepth 1 -name "*.go" ! -name "*_test.go"

elif [ "$STACK" = "php" ] && [ -f "$REPO_PATH/composer.json" ]; then
  PHP_VERSION=$(grep '"php"' "$REPO_PATH/composer.json" 2>/dev/null | head -1 | grep -o '[0-9][0-9.^~|]*' | head -1 || true)
  STACK_DETECTED="[SCANNED 95%] PHP ${PHP_VERSION:-8.x} with Laravel"

  run_stack_scans "$REPO_PATH" \
    "app/Http/Controllers app/Services app/Models app/Repositories app/Jobs tests" \
    "app/Http/Controllers app/Services app/Models app/Repositories" \
    -maxdepth 1 -name "*.php"

elif [ "$STACK" = "angular" ] && [ -f "$REPO_PATH/package.json" ]; then
  NG_VERSION=$(grep '"@angular/core"' "$REPO_PATH/package.json" 2>/dev/null | head -1 | grep -o '[0-9][0-9.^~]*' | head -1 || true)
  STACK_DETECTED="[SCANNED 95%] Angular ${NG_VERSION:-[version]}"

  run_stack_scans "$REPO_PATH" \
    "src/app/core src/app/shared src/app/features src/assets src/environments" \
    "" \
    -maxdepth 1 \( -name "*.ts" -o -name "*.html" \)

elif [ "$STACK" = "python" ] && { [ -f "$REPO_PATH/pyproject.toml" ] || [ -f "$REPO_PATH/requirements.txt" ]; }; then
  # Extract Python version from pyproject.toml (Poetry: python = "^3.x") or fall back
  PY_VERSION=""
  if [ -f "$REPO_PATH/pyproject.toml" ]; then
    PY_VERSION=$(grep -E '^python\s*=' "$REPO_PATH/pyproject.toml" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
  fi
  [ -z "$PY_VERSION" ] && [ -f "$REPO_PATH/.python-version" ] && PY_VERSION=$(cat "$REPO_PATH/.python-version" 2>/dev/null | tr -d '[:space:]')

  # Detect framework from pyproject.toml or requirements.txt
  FRAMEWORK_DETECTED=""
  for marker in "$REPO_PATH/pyproject.toml" "$REPO_PATH/requirements.txt"; do
    [ -f "$marker" ] || continue
    if grep -qE '(^|[^a-z])fastapi([^a-z]|$)' "$marker" 2>/dev/null; then
      FRAMEWORK_DETECTED="FastAPI"; break
    elif grep -qE '(^|[^a-z])django([^a-z]|$)' "$marker" 2>/dev/null; then
      FRAMEWORK_DETECTED="Django"; break
    elif grep -qE '(^|[^a-z])flask([^a-z]|$)' "$marker" 2>/dev/null; then
      FRAMEWORK_DETECTED="Flask"; break
    fi
  done
  [ -z "$FRAMEWORK_DETECTED" ] && FRAMEWORK_DETECTED="stdlib"

  STACK_DETECTED="[SCANNED 95%] Python ${PY_VERSION:-3.x} with ${FRAMEWORK_DETECTED}"

  # Detect ORM (SQLAlchemy / Tortoise ORM) — Django ORM is implied by framework
  if [ -f "$REPO_PATH/pyproject.toml" ] || [ -f "$REPO_PATH/requirements.txt" ]; then
    for marker in "$REPO_PATH/pyproject.toml" "$REPO_PATH/requirements.txt"; do
      [ -f "$marker" ] || continue
      if grep -qE '(^|[^a-z])sqlalchemy([^a-z]|$)' "$marker" 2>/dev/null; then
        ORM_DETECTED="[SCANNED 80%] ORM: SQLAlchemy (source: $(basename "$marker"))"
        break
      elif grep -qE '(^|[^a-z])tortoise-orm([^a-z]|$)' "$marker" 2>/dev/null; then
        ORM_DETECTED="[SCANNED 80%] ORM: Tortoise (source: $(basename "$marker"))"
        break
      fi
    done
    [ -z "$ORM_DETECTED" ] && [ "$FRAMEWORK_DETECTED" = "Django" ] && ORM_DETECTED="[SCANNED 80%] ORM: Django ORM (implied by framework)"
  fi

  run_stack_scans "$REPO_PATH" \
    "src app handlers services repository models middleware tests migrations" \
    "handlers services repository models app" \
    -maxdepth 2 -name "*.py" ! -name "test_*.py" ! -name "*_test.py"

elif [ "$STACK" = "java" ] && { [ -f "$REPO_PATH/pom.xml" ] || [ -f "$REPO_PATH/build.gradle" ] || [ -f "$REPO_PATH/build.gradle.kts" ]; }; then
  # Build-tool detection from manifest file presence.
  BUILD_TOOL="unknown"
  [ -f "$REPO_PATH/pom.xml" ] && BUILD_TOOL="Maven"
  [ -f "$REPO_PATH/build.gradle" ] && BUILD_TOOL="Gradle"
  [ -f "$REPO_PATH/build.gradle.kts" ] && BUILD_TOOL="Gradle (Kotlin DSL)"

  # Java version — best-effort: Maven <java.version> / <maven.compiler.source>, then Gradle sourceCompatibility.
  JAVA_VERSION=""
  if [ -f "$REPO_PATH/pom.xml" ]; then
    JAVA_VERSION=$(grep -oE '<java\.version>[^<]+</java\.version>' "$REPO_PATH/pom.xml" 2>/dev/null | sed -E 's/<[^>]+>//g' | head -1 || true)
    [ -z "$JAVA_VERSION" ] && JAVA_VERSION=$(grep -oE '<maven\.compiler\.source>[^<]+' "$REPO_PATH/pom.xml" 2>/dev/null | sed -E 's/<[^>]+>//g' | head -1 || true)
  fi
  if [ -z "$JAVA_VERSION" ] && { [ -f "$REPO_PATH/build.gradle" ] || [ -f "$REPO_PATH/build.gradle.kts" ]; }; then
    JAVA_VERSION=$(grep -hE "sourceCompatibility|targetCompatibility|JavaLanguageVersion\.of" "$REPO_PATH"/build.gradle* 2>/dev/null | grep -oE "['\"]?[0-9]+(\.[0-9]+)?['\"]?" | head -1 | tr -d "'\"" || true)
  fi

  # Spring Boot version — best-effort: Maven parent or Gradle plugin.
  SB_VERSION=""
  if [ -f "$REPO_PATH/pom.xml" ]; then
    SB_VERSION=$(grep -A1 'spring-boot-starter-parent' "$REPO_PATH/pom.xml" 2>/dev/null | grep -oE '<version>[^<]+' | head -1 | sed -E 's/<version>//' || true)
  fi
  if [ -z "$SB_VERSION" ] && { [ -f "$REPO_PATH/build.gradle" ] || [ -f "$REPO_PATH/build.gradle.kts" ]; }; then
    SB_VERSION=$(grep -hE "org\.springframework\.boot|spring-boot" "$REPO_PATH"/build.gradle* 2>/dev/null | grep -oE "[0-9]+\.[0-9]+\.[0-9]+" | head -1 || true)
  fi

  STACK_DETECTED="[SCANNED 95%] Java ${JAVA_VERSION:-x} with Spring Boot ${SB_VERSION:-x.x} (${BUILD_TOOL})"

  # ORM detection — Spring Data JPA / MyBatis (parallels Go's GORM/Pop detection).
  if grep -q "spring-boot-starter-data-jpa" "$REPO_PATH/pom.xml" 2>/dev/null \
     || grep -q "spring-boot-starter-data-jpa" "$REPO_PATH"/build.gradle* 2>/dev/null; then
    ORM_DETECTED="[SCANNED 80%] ORM: Spring Data JPA + Hibernate"
  fi
  if grep -q "mybatis-spring-boot-starter" "$REPO_PATH/pom.xml" 2>/dev/null \
     || grep -q "mybatis-spring-boot-starter" "$REPO_PATH"/build.gradle* 2>/dev/null; then
    [ -n "$ORM_DETECTED" ] && ORM_DETECTED="${ORM_DETECTED} + MyBatis"
    [ -z "$ORM_DETECTED" ] && ORM_DETECTED="[SCANNED 80%] ORM: MyBatis"
  fi

  # Migration tool detection — Flyway dir / Liquibase dir.
  if [ -d "$REPO_PATH/src/main/resources/db/migration" ]; then
    MIGRATION_TOOL="[SCANNED 90%] Migrations: Flyway (src/main/resources/db/migration/)"
  elif [ -d "$REPO_PATH/src/main/resources/db/changelog" ]; then
    MIGRATION_TOOL="[SCANNED 90%] Migrations: Liquibase (src/main/resources/db/changelog/)"
  fi

  run_stack_scans "$REPO_PATH" \
    "src/main/java src/test/java src/main/resources src/test/resources" \
    "src/main/java" \
    -name "*.java" ! -name "*Test.java" ! -name "*IT.java"

elif [ "$STACK" = "node" ] && [ -f "$REPO_PATH/package.json" ]; then
  PKG="$REPO_PATH/package.json"
  # Conservative: require at least one Node backend marker.
  # Markers: express, fastify, @nestjs/*, prisma, typeorm, sequelize, knex.
  if grep -qE '"(express|fastify|@nestjs/[^"]+|prisma|typeorm|sequelize|knex)"' "$PKG" 2>/dev/null; then
    NODE_VERSION=$(grep -oE '"engines"[^}]*"node"[[:space:]]*:[[:space:]]*"[^"]+"' "$PKG" 2>/dev/null \
      | grep -oE '[0-9]+(\.[0-9]+)?' | head -1 || true)
    FRAMEWORK_DETECTED=""
    grep -q '"@nestjs/' "$PKG" 2>/dev/null && FRAMEWORK_DETECTED="NestJS"
    [ -z "$FRAMEWORK_DETECTED" ] && grep -q '"express"' "$PKG" 2>/dev/null && FRAMEWORK_DETECTED="Express"
    [ -z "$FRAMEWORK_DETECTED" ] && grep -q '"fastify"' "$PKG" 2>/dev/null && FRAMEWORK_DETECTED="Fastify"
    [ -z "$FRAMEWORK_DETECTED" ] && FRAMEWORK_DETECTED="Node backend"
    STACK_DETECTED="[SCANNED 95%] Node ${NODE_VERSION:-x.x} with ${FRAMEWORK_DETECTED}"
  else
    STACK_DETECTED="[TODO] package.json present but no Node backend dependency (express/fastify/@nestjs/prisma/typeorm/sequelize/knex). If this is a Node backend, declare a backend dep in package.json. If this is a frontend, pass --stack angular or --stack react explicitly."
  fi

  run_stack_scans "$REPO_PATH" \
    "src app routes controllers services repositories middleware dto tests" \
    "routes controllers services repositories" \
    -maxdepth 2 \( -name "*.ts" -o -name "*.js" \) ! -name "*.test.ts" ! -name "*.test.js" ! -name "*.spec.ts" ! -name "*.spec.js"

elif [ "$STACK" = "react" ] && [ -f "$REPO_PATH/package.json" ]; then
  PKG="$REPO_PATH/package.json"
  # Conservative: refuse if @angular/core present; require at least one React marker.
  if grep -q '"@angular/core"' "$PKG" 2>/dev/null; then
    STACK_DETECTED="[TODO] package.json contains @angular/core. Pass --stack angular instead."
  elif grep -qE '"(react|react-dom|next|vite)"' "$PKG" 2>/dev/null; then
    REACT_VERSION=$(grep '"react"' "$PKG" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
    FRAMEWORK_DETECTED=""
    grep -q '"next"' "$PKG" 2>/dev/null && FRAMEWORK_DETECTED="Next.js"
    [ -z "$FRAMEWORK_DETECTED" ] && grep -q '"vite"' "$PKG" 2>/dev/null && FRAMEWORK_DETECTED="React + Vite"
    [ -z "$FRAMEWORK_DETECTED" ] && FRAMEWORK_DETECTED="React"
    STACK_DETECTED="[SCANNED 95%] React ${REACT_VERSION:-x.x} with ${FRAMEWORK_DETECTED}"
  else
    STACK_DETECTED="[TODO] package.json present but no React markers (react/react-dom/next/vite). If this is a Node backend, pass --stack node. If this is Angular, pass --stack angular."
  fi

  run_stack_scans "$REPO_PATH" \
    "src app components hooks store state api pages routes lib tests" \
    "components hooks store api" \
    -maxdepth 2 \( -name "*.tsx" -o -name "*.ts" -o -name "*.jsx" -o -name "*.js" \) ! -name "*.test.tsx" ! -name "*.test.ts" ! -name "*.spec.tsx" ! -name "*.spec.ts"

elif [ "$STACK" = "flutter" ] && [ -f "$REPO_PATH/pubspec.yaml" ]; then
  PUBSPEC="$REPO_PATH/pubspec.yaml"
  # Extract the environment: block (range from 'environment:' until the next
  # top-level key) so that 'flutter:' and 'sdk:' below match only inside that
  # block — not the bare 'flutter:' opener under 'dependencies:' that the
  # standard `flutter create` produces.
  ENV_BLOCK=$(awk '/^environment:/{flag=1; next} /^[^[:space:]]/{flag=0} flag' "$PUBSPEC" 2>/dev/null || true)
  # Flutter SDK constraint (optional `environment.flutter:` line, e.g. ">=3.10.0")
  FLUTTER_SDK=$(echo "$ENV_BLOCK" | grep -E '^[[:space:]]+flutter:' | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
  # Dart SDK constraint (`environment.sdk:` line, e.g. ">=3.0.0 <4.0.0")
  DART_SDK=$(echo "$ENV_BLOCK" | grep -E '^[[:space:]]+sdk:' | head -1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)

  # Native shells presence (informational — surface in bootstrap report)
  NATIVE_PLATFORMS=""
  [ -d "$REPO_PATH/ios/Runner" ] && NATIVE_PLATFORMS="${NATIVE_PLATFORMS}iOS "
  [ -d "$REPO_PATH/android/app" ] && NATIVE_PLATFORMS="${NATIVE_PLATFORMS}Android "
  [ -d "$REPO_PATH/web" ] && NATIVE_PLATFORMS="${NATIVE_PLATFORMS}Web "
  NATIVE_PLATFORMS="${NATIVE_PLATFORMS%% }"
  if [ -n "$NATIVE_PLATFORMS" ]; then
    STACK_DETECTED="[SCANNED 95%] Flutter ${FLUTTER_SDK:-3.x} (Dart ${DART_SDK:-3.x}) — platforms: ${NATIVE_PLATFORMS// /, }"
  else
    STACK_DETECTED="[SCANNED 95%] Flutter ${FLUTTER_SDK:-3.x} (Dart ${DART_SDK:-3.x})"
  fi

  # Dart sources under lib/ + test/
  run_stack_scans "$REPO_PATH" \
    "lib lib/features lib/widgets lib/services lib/models lib/providers lib/blocs lib/router lib/shared test" \
    "lib/features lib/services lib/widgets" \
    -maxdepth 3 -name "*.dart" ! -name "*_test.dart" ! -name "*.g.dart" ! -name "*.freezed.dart"

  # Native sources — only scanned when the platform folder is present, so non-mobile Flutter Web repos pay no cost
  if [ -d "$REPO_PATH/ios/Runner" ]; then
    run_stack_scans "$REPO_PATH" \
      "ios/Runner ios/RunnerTests" \
      "ios/Runner" \
      -maxdepth 3 \( -name "*.swift" -o -name "*.m" -o -name "*.h" \)
  fi
  if [ -d "$REPO_PATH/android/app/src/main" ]; then
    run_stack_scans "$REPO_PATH" \
      "android/app/src/main/kotlin android/app/src/main/java android/app/src/test android/app/src/androidTest" \
      "android/app/src/main/kotlin android/app/src/main/java" \
      -maxdepth 6 \( -name "*.kt" -o -name "*.java" \)
  fi
fi

[ -z "$STACK_DETECTED" ] && STACK_DETECTED="[TODO] Detect stack version from go.mod/pyproject.toml/composer.json/package.json/pubspec.yaml"
[ -z "$DIRS_FOUND" ] && DIRS_FOUND="[TODO] List key directories and their purpose"
[ -z "$KEY_FILES" ] && KEY_FILES="[TODO] Identify largest file per layer as key files"
[ -z "$ORM_DETECTED" ] && ORM_DETECTED="[TODO] Confirm if secondary ORM or other dependencies used"

# Fill deterministic placeholders in the freshly-written template, gated on
# the explicit CLAUDE_TEMPLATE_WRITTEN flag (set only by fresh-copy and
# explicit-replace paths — never inject/adopt/skip). Inject/adopt preserve
# human-owned content; running placeholder substitution there could mutate
# team-authored prose, which is unsafe.
if [ "$CLAUDE_TEMPLATE_WRITTEN" = true ]; then
  _fill_claude_md_placeholders "$REPO_PATH" "$STACK"
fi

# Detect upstream dependencies (basic grep for internal service URLs and known external providers).
# Internal services are found by their env-var prefix: INTELLISENSE_SERVICE_URL_PREFIX (default SVC_).
DEPS_FOUND=""
for dir in services app/Services src/app app src; do
  if [ -d "$REPO_PATH/$dir" ]; then
    # Grep for <prefix>*_URL env var references
    _svc_prefix="${INTELLISENSE_SERVICE_URL_PREFIX:-SVC_}"
    if grep -r "${_svc_prefix}[A-Z_]*_URL" "$REPO_PATH/$dir" 2>/dev/null | head -1 >/dev/null; then
      DEPS_FOUND="${DEPS_FOUND}[SCANNED 65%] Internal service(s) — source: \$${_svc_prefix}*_URL env variables\n"
    fi

    # Grep for known external providers (Stripe, AWS, etc.)
    for provider in Stripe AWS Twilio SendGrid; do
      if grep -r "$provider" "$REPO_PATH/$dir" 2>/dev/null | grep -q "import\|require\|use"; then
        DEPS_FOUND="${DEPS_FOUND}[SCANNED 65%] $provider — source: import/require statement\n"
      fi
    done
  fi
done

[ -z "$DEPS_FOUND" ] && DEPS_FOUND="[TODO] Identify upstream services this service calls\n[TODO] Check go.mod/pyproject.toml/composer.json/package.json for external provider SDKs"

# Get module/package name for header
MODULE_NAME="[TODO]"
if [ -f "$REPO_PATH/go.mod" ]; then
  MODULE_NAME=$(head -1 "$REPO_PATH/go.mod" 2>/dev/null | awk '{print $2}' | sed 's|.*/||')
elif [ -f "$REPO_PATH/pyproject.toml" ]; then
  MODULE_NAME=$(grep -E '^\s*name\s*=' "$REPO_PATH/pyproject.toml" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)".*/\1/' | sed 's|.*/||' || true)
elif [ -f "$REPO_PATH/composer.json" ]; then
  MODULE_NAME=$(grep '"name"' "$REPO_PATH/composer.json" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)".*/\1/' | sed 's|.*/||' || true)
elif [ -f "$REPO_PATH/package.json" ]; then
  MODULE_NAME=$(grep '"name"' "$REPO_PATH/package.json" 2>/dev/null | head -1 | sed 's/.*"\([^"]*\)".*/\1/' | sed 's|.*/||' || true)
fi
[ -z "$MODULE_NAME" ] && MODULE_NAME="[TODO]"

# Generate bootstrap file
cat > "$BOOTSTRAP_FILE" << 'BOOTSTRAP_EOF'
<!-- intellisense Bootstrap — Generated at setup-time for repository scaffolding -->
<!-- This is temporary SCAFFOLDING. Edit sections below, migrate verified content to CLAUDE.md sections, then delete this file. -->
<!-- /intellisense-audit will deduct points for this file's presence and for unresolved [TODO] items. -->

---

## Scanned Stack Information

BOOTSTRAP_EOF

printf "%b\n" "$STACK_DETECTED" >> "$BOOTSTRAP_FILE"
[ -n "$ORM_DETECTED" ] && printf "%b\n" "$ORM_DETECTED" >> "$BOOTSTRAP_FILE"
[ -n "$MIGRATION_TOOL" ] && printf "%b\n" "$MIGRATION_TOOL" >> "$BOOTSTRAP_FILE"
printf "[TODO] Confirm exact version and any secondary tools/ORMs\n" >> "$BOOTSTRAP_FILE"
printf "→ Migrate into CLAUDE.md ## Stack section\n\n" >> "$BOOTSTRAP_FILE"

printf "## Detected Directories and Layers\n\n" >> "$BOOTSTRAP_FILE"
printf "%b" "$DIRS_FOUND" >> "$BOOTSTRAP_FILE"
printf "[TODO] Add descriptions and purposes for each directory\n" >> "$BOOTSTRAP_FILE"
printf "→ Migrate into CLAUDE.md ## Structural Map section\n\n" >> "$BOOTSTRAP_FILE"

if [ -n "$KEY_FILES" ]; then
  printf "## Key Files (Largest per Layer)\n\n" >> "$BOOTSTRAP_FILE"
  printf "%b" "$KEY_FILES" >> "$BOOTSTRAP_FILE"
  printf "[TODO] Verify these are the correct key entry points\n" >> "$BOOTSTRAP_FILE"
  printf "→ Migrate into CLAUDE.md ## Structural Map section\n\n" >> "$BOOTSTRAP_FILE"
fi

printf "## Detected Dependencies\n\n" >> "$BOOTSTRAP_FILE"
printf "%b" "$DEPS_FOUND" >> "$BOOTSTRAP_FILE"
printf "→ Migrate and expand into CLAUDE.md ## Upstream Dependencies section\n\n" >> "$BOOTSTRAP_FILE"

cat >> "$BOOTSTRAP_FILE" << 'BOOTSTRAP_EOF'
## Content Still Requiring Human Input

**## Architecture** (3-5 sentences: what this service does, domain, data flow, key integrations)
[TODO — cannot be extracted automatically]

**## Downstream Consumers** (services that call this service)
[TODO — cannot be extracted automatically]

**## Shared Database Tables** (tables written by 2+ services)
[TODO — cannot be extracted automatically; verify consumers from service-map.md by hand]

**## API Contracts** (endpoints other services call)
[TODO — cannot be extracted automatically]

**## Domain Terms** (business vocabulary specific to this service)
[TODO — cannot be extracted automatically]

**## Known Gotchas** (non-obvious issues from past bugs, incidents, implementation quirks)
[TODO — cannot be extracted automatically]

---

## Migration Checklist

- [ ] Stack: Confirmed version and ORM, migrated to CLAUDE.md
- [ ] Structural Map: Directory purposes added, key files verified, migrated to CLAUDE.md
- [ ] Upstream Dependencies: False positives removed, reasons added, migrated to CLAUDE.md
- [ ] Downstream Consumers: Listed and migrated to CLAUDE.md
- [ ] Shared Database Tables: Identified and migrated to CLAUDE.md
- [ ] API Contracts: Listed and migrated to CLAUDE.md
- [ ] Domain Terms: Defined and migrated to CLAUDE.md
- [ ] Known Gotchas: Added and migrated to CLAUDE.md
- [ ] This bootstrap file deleted from repo

---

BOOTSTRAP_EOF

printf "Created: %s by setup-repos.sh\n" "$TODAY" >> "$BOOTSTRAP_FILE"
printf "Once all content is migrated to CLAUDE.md, delete this file to improve audit score.\n" >> "$BOOTSTRAP_FILE"

echo -e "${GREEN}✓ Bootstrap file created: .intellisense-bootstrap.md${NC}"
echo "  [SCANNED] Stack detected: $(echo "$STACK_DETECTED" | sed 's/\[SCANNED 95%\] //')"
echo "  [SCANNED] Directories and layers identified"
echo "  [TODO] Architecture, Consumers, Domain Terms, Gotchas need human input"
echo ""
echo "  After filling CLAUDE.md sections: delete .intellisense-bootstrap.md to improve audit score"
echo ""

# Append bootstrap reference to CLAUDE.md if not already present (but respect skip action)
if [ "$CLAUDE_ACTION" != "skip" ] && [ -f "$REPO_PATH/CLAUDE.md" ] && ! grep -q "intellisense-bootstrap" "$REPO_PATH/CLAUDE.md"; then
  {
    printf '\n\n## Scanned Context (intellisense Bootstrap)\n'
    printf '<!-- Temporary scaffolding generated by setup-repos.sh. Migrate content to appropriate sections above, then delete .intellisense-bootstrap.md -->\n'
    printf '@.intellisense-bootstrap.md\n'
  } >> "$REPO_PATH/CLAUDE.md"
fi

fi

echo ""

# Step 2.7: Claude-assisted knowledge-base stub extraction (always runs — idempotent on re-runs)
echo -e "${BLUE}→ Step 2.7: Extract knowledge-base stubs via Claude${NC}"
if command -v claude &> /dev/null; then
    bash "$INTELLISENSE_SETUP_DIR/scripts/generate-kb-stubs.sh" \
        --repo "$REPO_PATH" \
        --stack "$STACK" \
        --kb-dir "$REPO_PATH/knowledge-base"
    # Remove any .stub.md files that leaked into the service repo
    find "$REPO_PATH/knowledge-base/" -name "*.stub.md" -type f -delete
    KB_STATUS_FILE=$(intellisense_state_path "$REPO_PATH" stubs-status)
    if [ -f "$KB_STATUS_FILE" ]; then
        # Extract counts for summary output
        STUBS_FILLED=$(grep -o '"claude_extracted": [0-9]*' "$KB_STATUS_FILE" | grep -o '[0-9]*')
        STUBS_EMPTY=$(grep -o '"team_required": [0-9]*' "$KB_STATUS_FILE" | grep -o '[0-9]*')
    fi
else
    echo -e "  ${YELLOW}⚠ Claude CLI not found — stubs left empty${NC}"
    STUBS_FILLED=0
    STUBS_EMPTY=15
fi
echo ""

# Step 3: pre-push hook installation is handled by the hook-chaining section below: without Beads it chains the
# intellisense hooks into the repository's hooks directory; with Beads, bd init writes .beads/hooks/pre-push and
# Beads step 4 appends a chain block that delegates to $INTELLISENSE_SETUP_DIR/hooks/pre-push.
echo -e "${BLUE}→ Step 3: Pre-push hook (chained below)${NC}"
echo -e "  ${DIM}see the hook-chaining step below${NC}"
echo ""

# Step 4: Install GitHub Actions workflows
echo -e "${BLUE}→ Step 4: Install GitHub Actions workflows${NC}"
if [ "$SKIP_CI" = true ]; then
    echo -e "  ${DIM}⊘ SKIPPED${NC} (--skip-ci flag set)"
else
    CI_SRC_DIR="$INTELLISENSE_SETUP_DIR/templates/ci"
    CI_DEST_DIR="$REPO_PATH/.github/workflows"

    if [ -d "$CI_SRC_DIR" ]; then
        mkdir -p "$CI_DEST_DIR"

        # Copy refresh-docs.yml workflow
        if [ -f "$CI_SRC_DIR/refresh-docs.yml" ]; then
            install_file_safe "$CI_SRC_DIR/refresh-docs.yml" "$CI_DEST_DIR/refresh-docs.yml" "refresh-docs.yml workflow"
            if [ -f "$CI_DEST_DIR/refresh-docs.yml" ]; then
                echo "  refresh-docs.yml installed (weekly doc refresh)"
                INSTALLED_COMPONENTS+=("github-actions")
            fi
        else
            echo -e "  ${YELLOW}⚠️  refresh-docs.yml not found in templates/ci/, skipping${NC}"
        fi

        # Copy intellisense-trailer-check.yml workflow + vendor the
        # validator script into .intellisense/scripts/ so the workflow finds it
        # without depending on INTELLISENSE_SETUP being reachable from the runner.
        if [ -f "$CI_SRC_DIR/intellisense-trailer-check.yml" ]; then
            install_file_safe "$CI_SRC_DIR/intellisense-trailer-check.yml" "$CI_DEST_DIR/intellisense-trailer-check.yml" "intellisense-trailer-check.yml workflow"
            mkdir -p "$REPO_PATH/.intellisense/scripts"
            if [ -f "$INTELLISENSE_SETUP_DIR/scripts/validate-intellisense-trailers-pr.sh" ]; then
                install_file_safe "$INTELLISENSE_SETUP_DIR/scripts/validate-intellisense-trailers-pr.sh" \
                    "$REPO_PATH/.intellisense/scripts/validate-intellisense-trailers-pr.sh" \
                    "PR validator (vendored)"
                chmod +x "$REPO_PATH/.intellisense/scripts/validate-intellisense-trailers-pr.sh" 2>/dev/null || true
                echo "  intellisense-trailer-check.yml + .intellisense/scripts/validate-intellisense-trailers-pr.sh installed (server-side enforcement)"
                echo "  ${DIM}↳ To enforce: set 'intellisense/trailers' as a required status check in GitHub branch protection.${NC}"
            else
                echo -e "  ${YELLOW}⚠️  PR validator script not found in INTELLISENSE_SETUP — workflow installed but will fail until validator is vendored.${NC}"
            fi
        else
            echo -e "  ${YELLOW}⚠️  intellisense-trailer-check.yml not found in templates/ci/, skipping the PR validator${NC}"
        fi
    else
        echo -e "  ${YELLOW}⚠️  templates/ci directory not found in INTELLISENSE_SETUP, skipping${NC}"
    fi
fi

echo ""

# Step 5: Run intellisense audit via Claude CLI
echo -e "${BLUE}→ Step 5: intellisense Audit [intellisense]${NC}"
echo ""
if $INTERACTIVE && command -v claude &> /dev/null; then
    echo -e "  ${DIM}Running intellisense audit via Claude CLI...${NC}"
    AUDIT_PROMPT="You are auditing a $STACK repository. Score it on 5 categories (20 pts each = 100 total):

**CATEGORY DEFINITIONS:**

1. **Structure Compliance (0-20)**: File organization
   - Go: handlers/, services/, models/, repository/, tests/ or *_test.go files
   - Score: 20=all present, 15=4/5, 12=3/5, 8=2/5, 0=none/flat

2. **CLAUDE.md Quality (0-20)**: Documentation completeness
   - 4pts if file exists
   - 2pts each for: Stack, Architecture, Structural Map, Upstream Dependencies, Downstream Consumers, Domain Terms, Known Gotchas, Run/Test/Build
   - Deduct 2pts each: placeholder text, .intellisense-bootstrap.md present

3. **Test Approach (0-20)**: Test quality
   - 6pts if tests exist
   - 4pts if behavior-named (e.g., 'returns empty when invalid')
   - 4pts if AAA pattern visible
   - 4pts if test count >= 50% of source files
   - 2pts if no stub test files

4. **Pattern Consistency (0-20)**: Code consistency
   - 5pts: consistent error handling across 3+ files
   - 4pts: no ORM mixing
   - 4pts: same HTTP response envelope
   - 4pts: no oversized files (>3x avg in layer)
   - 3pts: consistent import ordering

5. **Documentation Freshness (0-20)**: Doc maintenance
   - 4pts: CLAUDE.md committed within 60 days
   - 4pts: no placeholder patterns in .md files
   - 4pts: .intellisense-doc-health.json exists
   - 4pts: all files in CLAUDE.md Structural Map exist
   - 4pts: knowledge-base/ has no unresolved stubs

**RESPOND WITH A JSON OBJECT (ONLY — no markdown, no explanation):**
\`\`\`json
{
  \"total_score\": <0-100>,
  \"grade\": \"<Excellent|Good|Works But Risky|Poor|Critical>\",
  \"category_scores\": {
    \"structure\": <0-20>,
    \"claude_md\": <0-20>,
    \"tests\": <0-20>,
    \"patterns\": <0-20>,
    \"docs\": <0-20>
  },
  \"suggestions\": [\"<fix 1>\", \"<fix 2>\", \"<fix 3>\"]
}
\`\`\`"
    # Fail-soft: the audit is best-effort scoring. A non-zero exit from claude -p
    # (auth not configured, usage limit, network) must NOT abort onboarding — under
    # set -euo pipefail it would, and setup.sh's ERR trap would then roll back the
    # whole ~/.claude install. Swallow the failure to an empty string so the
    # parse-failed else-branch below handles it gracefully.
    AUDIT_OUTPUT=$(cd "$REPO_PATH" && claude -p "$AUDIT_PROMPT" < /dev/null 2>/dev/null) || AUDIT_OUTPUT=""

    # Extract JSON from output (may be wrapped in markdown code blocks).
    # '|| true' so a grep no-match on empty/JSON-less output doesn't trip pipefail.
    AUDIT_JSON=$(echo "$AUDIT_OUTPUT" | grep -A 100 '{' | grep -B 100 '}' | head -20 || true)

    # Parse JSON using jq if available, otherwise use grep fallback
    if command -v jq &> /dev/null; then
        AUDIT_SCORE=$(echo "$AUDIT_JSON" | jq -r '.total_score // empty' 2>/dev/null)
        AUDIT_GRADE=$(echo "$AUDIT_JSON" | jq -r '.grade // empty' 2>/dev/null)
        STRUCTURE_SCORE=$(echo "$AUDIT_JSON" | jq -r '.category_scores.structure // 0' 2>/dev/null)
        CLAUDE_MD_SCORE=$(echo "$AUDIT_JSON" | jq -r '.category_scores.claude_md // 0' 2>/dev/null)
        TEST_SCORE=$(echo "$AUDIT_JSON" | jq -r '.category_scores.tests // 0' 2>/dev/null)
        PATTERN_SCORE=$(echo "$AUDIT_JSON" | jq -r '.category_scores.patterns // 0' 2>/dev/null)
        DOC_SCORE=$(echo "$AUDIT_JSON" | jq -r '.category_scores.docs // 0' 2>/dev/null)
    else
        # Fallback: basic grep parsing (less reliable but works without jq)
        AUDIT_SCORE=$(echo "$AUDIT_JSON" | grep "total_score" | grep -o '[0-9][0-9]*' | head -1)
        AUDIT_GRADE=$(echo "$AUDIT_JSON" | grep "grade" | cut -d'"' -f4)
        STRUCTURE_SCORE=$(echo "$AUDIT_JSON" | grep -o '"structure": *[0-9][0-9]*' | grep -o '[0-9][0-9]*')
        CLAUDE_MD_SCORE=$(echo "$AUDIT_JSON" | grep -o '"claude_md": *[0-9][0-9]*' | grep -o '[0-9][0-9]*')
        TEST_SCORE=$(echo "$AUDIT_JSON" | grep -o '"tests": *[0-9][0-9]*' | grep -o '[0-9][0-9]*')
        PATTERN_SCORE=$(echo "$AUDIT_JSON" | grep -o '"patterns": *[0-9][0-9]*' | grep -o '[0-9][0-9]*')
        DOC_SCORE=$(echo "$AUDIT_JSON" | grep -o '"docs": *[0-9][0-9]*' | grep -o '[0-9][0-9]*')
    fi

    if [ -n "$AUDIT_SCORE" ] && [ "$AUDIT_SCORE" != "" ]; then
        # Write health file
        cat > "$REPO_PATH/.intellisense-doc-health.json" << EOF
{
  "schema_version": "1.0",
  "service": "$(basename $REPO_PATH)",
  "stack": "$STACK",
  "last_audit_score": $AUDIT_SCORE,
  "last_audit_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "last_audit_by": "claude-code",
  "category_scores": {
    "structure": ${STRUCTURE_SCORE:-0},
    "claude_md_quality": ${CLAUDE_MD_SCORE:-0},
    "test_approach": ${TEST_SCORE:-0},
    "pattern_consistency": ${PATTERN_SCORE:-0},
    "documentation_freshness": ${DOC_SCORE:-0}
  },
  "pending_doc_updates": [],
  "update_history": [],
  "audit_history": [{ "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "score": $AUDIT_SCORE, "run_by": "claude-code" }]
}
EOF
        echo -e "  ${GREEN}✓ Audit complete — Score: $AUDIT_SCORE ($AUDIT_GRADE)${NC}"
        echo -e "  ${DIM}Health file written to .intellisense-doc-health.json${NC}"
    else
        echo -e "  ${YELLOW}⚠ Audit ran but score parsing failed${NC}"
        echo -e "  ${DIM}Output: $(echo "$AUDIT_OUTPUT" | head -1)...${NC}"
    fi
else
    if $INTERACTIVE; then
      echo -e "  ${YELLOW}⚠ Claude CLI not found — skipping audit${NC}"
      echo -e "  ${DIM}Install Claude CLI, then open this repo in Claude and run: /intellisense-audit --repo . --stack $STACK${NC}"
    else
      echo -e "  ${DIM}⊘ Audit skipped (non-interactive mode)${NC}"
    fi
fi
echo ""

# Optional integrations: --tracker / --code-intel, else what setup.sh recorded, else none.
if [ -f "$HOME/.intellisense/integrations.env" ]; then
  _recorded_tracker="$(sed -n 's/^INTELLISENSE_TRACKER=//p' "$HOME/.intellisense/integrations.env")"
  _recorded_code_intel="$(sed -n 's/^INTELLISENSE_CODE_INTEL=//p' "$HOME/.intellisense/integrations.env")"
fi
TRACKER="${TRACKER:-${_recorded_tracker:-none}}"
CODE_INTEL="${CODE_INTEL:-${_recorded_code_intel:-none}}"

if [ "$TRACKER" != "beads" ]; then
# No Beads: chain the intellisense hooks straight into the repository's active hooks directory.
echo -e "${BLUE}→ Hooks: chain intellisense pre-push / prepare-commit-msg / post-commit (tracker: $TRACKER)${NC}"
intellisense_ensure_repo_gitignore "$REPO_PATH"
HOOKS_DIR_FOR_REPO="$(resolve_hooks_dir "$REPO_PATH")"
mkdir -p "$HOOKS_DIR_FOR_REPO"
for _hook in pre-push prepare-commit-msg post-commit; do
  _dest="$HOOKS_DIR_FOR_REPO/$_hook"
  if [ -f "$_dest" ] && grep -q '^# --- BEGIN intellisense INTEGRATION ---$' "$_dest"; then
    sed -i.intellisensebak '/^# --- BEGIN intellisense INTEGRATION ---$/,/^# --- END intellisense INTEGRATION ---$/d' "$_dest"
    rm -f "$_dest.intellisensebak"
  elif [ ! -f "$_dest" ]; then
    printf '#!/usr/bin/env sh\n' > "$_dest"
  fi
  if [ "$_hook" = "post-commit" ]; then _run='"$INTELLISENSE_HOOK" "$@" 2>/dev/null || true'; else _run='"$INTELLISENSE_HOOK" "$@" || exit $?'; fi
  cat >> "$_dest" <<EOF

# --- BEGIN intellisense INTEGRATION ---
# Managed by intellisense setup-repos.sh. Runs the intellisense $_hook hook.
INTELLISENSE_HOOK="$INTELLISENSE_SETUP_DIR/hooks/$_hook"
if [ -x "\$INTELLISENSE_HOOK" ]; then
  $_run
fi
# --- END intellisense INTEGRATION ---
EOF
  chmod +x "$_dest"
  echo -e "  ${GREEN}[INSTALLED]${NC} $_dest"
done
INSTALLED_COMPONENTS+=("hooks")
echo ""
else
# ============================================================================
# Beads onboarding: verify bd, gitignore .beads/, init .beads/, chain intellisense.
# bd is a per-laptop task tracker; issues are NOT shared via git. Order:
# ensure bd → gitignore .beads/ → bd init → disable auto-export → chain intellisense.
# ============================================================================
echo -e "${BLUE}→ Beads: install / verify + chain intellisense pre-push${NC}"

# Beads step 1: ensure bd is on PATH
if ! command -v bd >/dev/null 2>&1; then
  echo -e "  ${RED}[FAILED]${NC} bd not found in PATH"
  echo "    Re-run: bash $INTELLISENSE_SETUP_DIR/setup.sh  (installs/verifies bd)"
  exit 1
fi

# Beads step 2: gitignore .beads/ BEFORE bd init (prevents bd's auto-commit attempts).
REPO_GITIGNORE="$REPO_PATH/.gitignore"
if [ ! -f "$REPO_GITIGNORE" ]; then
  echo ".beads/" > "$REPO_GITIGNORE"
  echo -e "  ${GREEN}[CREATED]${NC} $REPO_GITIGNORE with .beads/"
elif ! grep -qE '^\.beads/?$' "$REPO_GITIGNORE"; then
  echo ".beads/" >> "$REPO_GITIGNORE"
  echo -e "  ${YELLOW}[UPDATED]${NC} $REPO_GITIGNORE — added .beads/ (must precede bd init)"
fi

# Beads step 2b: gitignore ALL intellisense per-dev state files. Closes the gap where the
# team-lead workflow could leak session uuids / classification / usage data
# via `git add . && git push`. Idempotent on re-runs.
intellisense_ensure_repo_gitignore "$REPO_PATH"

# Beads step 3: bd init if no Dolt config marker.
if [ ! -f "$REPO_PATH/.beads/config.yaml" ]; then
  echo "  Initializing Beads database for $REPO_PATH..."
  if ! ( cd "$REPO_PATH" && bd init --skip-agents --non-interactive --role maintainer ); then
    echo -e "  ${RED}[FAILED]${NC} bd init failed in $REPO_PATH"
    echo "    Investigate: cd $REPO_PATH && bd init --skip-agents --non-interactive --role maintainer"
    exit 1
  fi
  # Disable auto-export (issues.jsonl is gitignored; auto-export's git-add
  # would print "auto-export: git add failed" on every bd write).
  ( cd "$REPO_PATH" && bd config set export.auto false >/dev/null 2>&1 ) || true
  echo -e "  ${GREEN}[CREATED]${NC} .beads/ initialized in $REPO_PATH (auto-export disabled)"
else
  echo -e "  ${DIM}[SKIPPED]${NC} .beads/ already initialized in $REPO_PATH (preserved)"
fi

# Beads step 4: install/refresh intellisense chain block (always — re-runs must refresh).
BEADS_PREPUSH="$REPO_PATH/.beads/hooks/pre-push"
if [ ! -f "$BEADS_PREPUSH" ]; then
  echo -e "  ${RED}[FAILED]${NC} expected $BEADS_PREPUSH after bd init, not found"
  exit 1
fi
if grep -q '^# --- BEGIN intellisense INTEGRATION ---$' "$BEADS_PREPUSH"; then
  sed -i.intellisensebak '/^# --- BEGIN intellisense INTEGRATION ---$/,/^# --- END intellisense INTEGRATION ---$/d' "$BEADS_PREPUSH"
  rm -f "$BEADS_PREPUSH.intellisensebak"
fi
cat >> "$BEADS_PREPUSH" <<EOF

# --- BEGIN intellisense INTEGRATION ---
# Managed by intellisense setup scripts. Chains intellisense's tier-validation pre-push.
# Fail-safe: missing or non-executable hook BLOCKS the push (no silent bypass).
INTELLISENSE_HOOK="$INTELLISENSE_SETUP_DIR/hooks/pre-push"
if [ ! -f "\$INTELLISENSE_HOOK" ]; then
  echo "❌ intellisense pre-push hook missing at \$INTELLISENSE_HOOK" >&2
  echo "   Re-run: bash $INTELLISENSE_SETUP_DIR/setup.sh" >&2
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
echo -e "  ${YELLOW}[UPDATED]${NC} $BEADS_PREPUSH — intellisense chain block refreshed (BEADS block preserved)"
INSTALLED_COMPONENTS+=("hooks")

# install/refresh intellisense chain block in prepare-commit-msg.
# Resolve the active hooks dir per the target repo —
# handles repos where core.hooksPath is unset or custom (Beads-onboarded
# repos resolve to .beads/hooks/; un-onboarded ones to .git/hooks/).
HOOKS_DIR_FOR_REPO="$(resolve_hooks_dir "$REPO_PATH")"
BEADS_PCM="$HOOKS_DIR_FOR_REPO/prepare-commit-msg"
if [ -f "$BEADS_PCM" ]; then
  # Existing hook path: append/refresh chain
  # block. Wrapper PROPAGATES the intellisense hook's exit code (prepare-commit-msg uses exit 1 for
  # cursor corruption that must block; exit 0 for pilot warnings).
  rm -f "$BEADS_PCM.intellisense-new"
  if grep -q '^# --- BEGIN intellisense INTEGRATION ---$' "$BEADS_PCM"; then
    sed -i.intellisensebak '/^# --- BEGIN intellisense INTEGRATION ---$/,/^# --- END intellisense INTEGRATION ---$/d' "$BEADS_PCM"
    rm -f "$BEADS_PCM.intellisensebak"
  fi
  cat >> "$BEADS_PCM" <<EOF

# --- BEGIN intellisense INTEGRATION ---
# Managed by intellisense setup scripts. prepare-commit-msg internally decides
# pilot-vs-block: exit 0 = proceed; exit 1 = block (cursor corruption, etc).
# Propagate the exit code; do NOT swallow with \`||\`.
INTELLISENSE_HOOK="$INTELLISENSE_SETUP_DIR/hooks/prepare-commit-msg"
if [ -x "\$INTELLISENSE_HOOK" ]; then
  "\$INTELLISENSE_HOOK" "\$@"
  _intellisense_rc=\$?
  if [ \$_intellisense_rc -ne 0 ]; then
    exit \$_intellisense_rc
  fi
fi
# --- END intellisense INTEGRATION ---
EOF
  echo -e "  ${YELLOW}[UPDATED]${NC} $BEADS_PCM — intellisense chain block refreshed (BEADS block preserved)"
else
  # No existing hook → write a fresh wrapper, so trailer injection is always wired.
  cat > "$BEADS_PCM" <<EOF
#!/usr/bin/env sh
# Managed by intellisense setup scripts. Fresh-install wrapper —
# no prior Beads-managed hook to chain through.
INTELLISENSE_HOOK="$INTELLISENSE_SETUP_DIR/hooks/prepare-commit-msg"
if [ -x "\$INTELLISENSE_HOOK" ]; then
  "\$INTELLISENSE_HOOK" "\$@"
  _intellisense_rc=\$?
  if [ \$_intellisense_rc -ne 0 ]; then
    exit \$_intellisense_rc
  fi
fi
EOF
  chmod +x "$BEADS_PCM"
  echo -e "  ${GREEN}[INSTALLED]${NC} $BEADS_PCM — prepare-commit-msg fresh wrapper written (no prior hook present)"
fi

# install intellisense post-commit hook.
# Use resolve_hooks_dir, not hardcoded .beads/hooks.
# Beads does NOT ship its own post-commit, so we write the wrapper fresh.
BEADS_POSTCOMMIT="$HOOKS_DIR_FOR_REPO/post-commit"
mkdir -p "$(dirname "$BEADS_POSTCOMMIT")" 2>/dev/null
cat > "$BEADS_POSTCOMMIT" <<EOF
#!/usr/bin/env sh
# Managed by intellisense setup scripts. Phase 2 of the two-phase token
# cursor. Promotes pending_cursor → committed_cursor after commit success.
# Fail-soft: missing intellisense hook is a no-op.
INTELLISENSE_HOOK="$INTELLISENSE_SETUP_DIR/hooks/post-commit"
if [ -x "\$INTELLISENSE_HOOK" ]; then
  "\$INTELLISENSE_HOOK" "\$@" 2>/dev/null || true
fi
EOF
chmod +x "$BEADS_POSTCOMMIT"
echo -e "  ${GREEN}[INSTALLED]${NC} $BEADS_POSTCOMMIT — post-commit post-commit cursor promotion wired"
echo ""
fi  # tracker = beads

# =====================================================================
# Graph bootstrap (only with --code-intel code-review-graph; required for mandatory stacks)
#
# This step is the authoritative point at which:
#   1. The intellisense-managed marker is written (CLAUDE.md or .intellisense/MANAGED).
#   2. Stack support is classified.
#   3. Graph install state is independently re-detected (NO inter-process
#      flag from setup.sh; we look at the binary on PATH every run).
#   4. Defensive .gitignore writes happen.
#   5. graph-bootstrap.sh is invoked (or the exception path is taken).
#
# This step always runs, even when SKIP_CLAUDE_MD_SETUP/SKIP_DOCS_SETUP
# short-circuited earlier steps. The graph state must be current.
# =====================================================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}→ Graph bootstrap${NC}"
echo ""

# 1. Write intellisense-managed marker (idempotent)
#
# Marker location follows the user's CLAUDE.md preference:
#   - --skip-claude-md OR --claude-md-action skip OR no CLAUDE.md → .intellisense/MANAGED
#   - otherwise → <!-- INTELLISENSE-MANAGED --> line in CLAUDE.md
#
# Both forms satisfy the §2.7 intellisense-managed definition; the choice respects
# whether the user wants CLAUDE.md modified.
if [ "$SKIP_CLAUDE_MD" = true ] || [ "$CLAUDE_ACTION" = "skip" ] || [ ! -f "$REPO_PATH/CLAUDE.md" ]; then
  if ! intellisense_is_managed "$REPO_PATH"; then
    intellisense_graph_write_managed_marker "$REPO_PATH"
    echo -e "  ${GREEN}✓${NC} intellisense-managed marker written: .intellisense/MANAGED"
  else
    echo -e "  ${DIM}✓ intellisense-managed marker already present${NC}"
  fi
else
  if ! grep -qF '<!-- INTELLISENSE-MANAGED -->' "$REPO_PATH/CLAUDE.md" 2>/dev/null; then
    intellisense_graph_ensure_managed_in_claude_md "$REPO_PATH"
    echo -e "  ${GREEN}✓${NC} intellisense-managed marker added to CLAUDE.md"
  else
    echo -e "  ${DIM}✓ intellisense-managed marker already present in CLAUDE.md${NC}"
  fi
fi

# 2. Stack classification
STACK_SUPPORT="$(intellisense_graph_stack_support "$STACK")"
STACK_MIN_NODES="$(intellisense_graph_min_nodes "$STACK")"
echo -e "  Stack: ${BOLD}$STACK${NC} (support: $STACK_SUPPORT, default min-nodes: $STACK_MIN_NODES)"

# 3. Defensive .gitignore writes
intellisense_graph_ensure_gitignore "$REPO_PATH"
echo -e "  ${DIM}✓ .gitignore: .code-review-graph/ + .intellisense/graph-status.json${NC}"

GRAPH_BOOT_OK=skipped
if [ "$CODE_INTEL" != "code-review-graph" ]; then
  echo -e "  ${DIM}⊘ Graph build skipped (code intelligence: $CODE_INTEL; choose it with --code-intel code-review-graph)${NC}"
else
# 4. Handle exception path (--graph-exception)
if [ -n "$GRAPH_EXCEPTION" ]; then
  case "$GRAPH_EXCEPTION" in
    unsupported-stack|opt-out|incident|other) ;;
    *)
      echo -e "${RED}ERROR: --graph-exception must be one of: unsupported-stack, opt-out, incident, other${NC}"
      exit 1
      ;;
  esac

  # Owner: required (prompt if interactive)
  if [ -z "$GRAPH_EXC_OWNER" ]; then
    if [ "$INTERACTIVE" = true ]; then
      read -p "  Owner email for graph exception: " GRAPH_EXC_OWNER
    fi
  fi
  if [ -z "$GRAPH_EXC_OWNER" ]; then
    echo -e "${RED}ERROR: --graph-exception-owner required (or --owner) — non-interactive mode${NC}"
    exit 1
  fi

  # Expires: default to 6 months out
  if [ -z "$GRAPH_EXC_EXPIRES" ]; then
    DEFAULT_EXP="$(date -u -v+6m +%Y-%m-%d 2>/dev/null || date -u -d '+6 months' +%Y-%m-%d 2>/dev/null || echo '')"
    if [ "$INTERACTIVE" = true ]; then
      read -p "  Exception expires (YYYY-MM-DD, default $DEFAULT_EXP): " GRAPH_EXC_EXPIRES
    fi
    [ -z "$GRAPH_EXC_EXPIRES" ] && GRAPH_EXC_EXPIRES="$DEFAULT_EXP"
  fi
  if [ -z "$GRAPH_EXC_EXPIRES" ]; then
    echo -e "${RED}ERROR: --graph-exception-expires required (or --expires) — and 'date' could not compute a default${NC}"
    exit 1
  fi

  # Validate YYYY-MM-DD shape
  if ! [[ "$GRAPH_EXC_EXPIRES" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo -e "${RED}ERROR: --graph-exception-expires must be YYYY-MM-DD (got: $GRAPH_EXC_EXPIRES)${NC}"
    exit 1
  fi

  # Write the exception JSON (committed; NOT gitignored).
  # Deterministic content: any field that would vary between developers re-running
  # setup (e.g., per-run timestamps) belongs in git log / .intellisense/local.json, not
  # in a tracked audit file. First-write time is preserved by git history of
  # this file; a timestamp here would produce a diff on every re-run.
  ensure_intellisense_state_dir "$REPO_PATH"
  cat > "$(intellisense_graph_exception_path "$REPO_PATH")" <<JSON
{
  "reason": "$GRAPH_EXCEPTION",
  "stack": "$STACK",
  "owner": "$GRAPH_EXC_OWNER",
  "expires": "$GRAPH_EXC_EXPIRES",
  "notes": "Created by setup-repos.sh"
}
JSON
  echo -e "  ${GREEN}✓${NC} Graph exception written: .intellisense/graph-exception.json"
  echo -e "    reason: $GRAPH_EXCEPTION | owner: $GRAPH_EXC_OWNER | expires: $GRAPH_EXC_EXPIRES"
fi

# 5. Decide build behavior
GRAPH_BOOT_OK=true   # tracks whether the build succeeded; influences final summary

if intellisense_graph_has_exception "$REPO_PATH"; then
  echo -e "  ${YELLOW}ℹ Graph build skipped (.intellisense/graph-exception.json present)${NC}"
  # Run bootstrap so it writes the readiness=skipped status with advisory marker.
  if intellisense_graph_detect_install >/dev/null 2>&1; then
    bash "$INTELLISENSE_SETUP_DIR/scripts/graph-bootstrap.sh" \
      --repo "$REPO_PATH" --stack "$STACK" --yes >/dev/null 2>&1 || true
  fi
  GRAPH_BOOT_OK=skipped

elif [ "$STACK_SUPPORT" = "unsupported" ]; then
  cat <<EOF >&2

  ${RED}ERROR: stack '$STACK' is classified 'unsupported' and no --graph-exception was provided.${NC}

  intellisense-managed unsupported-stack repos require an explicit opt-out. Either:
    - Re-run with: --graph-exception unsupported-stack \\
                   --owner <email> --expires <YYYY-MM-DD>
    - Or do not run setup-repos.sh on this repo (leave it non-intellisense-managed).

  See: @rules/operational/graph-supported-stacks.md

EOF
  exit 1

else
  # Independent install detection (does NOT depend on setup.sh shell state).
  if ! intellisense_graph_detect_install >/dev/null 2>&1; then
    DETECT_RC=$?
    cat <<EOF >&2

  ${RED}ERROR: code-review-graph not available at the required version.${NC}
$(if [ "$DETECT_RC" -eq 1 ]; then
  echo "    Diagnosis: binary not on PATH"
elif [ "$DETECT_RC" -eq 2 ]; then
  echo "    Diagnosis: installed at wrong version (need $(intellisense_graph_required_version))"
fi)

  This is required for stack '$STACK' (classified $STACK_SUPPORT).
  Run:
      bash setup.sh

  This will install code-review-graph==$(intellisense_graph_required_version) via
  uv tool / pipx / pip --user (whichever is available).

EOF
    exit 1
  fi

  # Compose bootstrap arguments
  BOOT_ARGS=(--repo "$REPO_PATH" --stack "$STACK" --yes)
  [ -n "$MIN_NODES_OVERRIDE" ] && BOOT_ARGS+=(--min-nodes "$MIN_NODES_OVERRIDE")

  echo ""
  echo -e "  → Invoking graph-bootstrap.sh"
  if bash "$INTELLISENSE_SETUP_DIR/scripts/graph-bootstrap.sh" "${BOOT_ARGS[@]}"; then
    GRAPH_BOOT_OK=true
  else
    BOOT_RC=$?
    case "$STACK_SUPPORT" in
      mandatory-supported)
        # Hard fail for mandatory stacks (opt-in only via INTELLISENSE_GRAPH_MANDATORY_STACKS
        # or intellisense.graph_mandatory_stacks in settings.json — no stack is mandatory by default)
        echo -e "${RED}✗ Graph bootstrap FAILED for mandatory-supported stack (exit=$BOOT_RC).${NC}" >&2
        echo "  intellisense-managed $STACK repos require a working graph (mandatory stack)." >&2
        exit "$BOOT_RC"
        ;;
      candidate-supported|weak)
        # Soft fail: status file written with readiness=failed; build continues.
        echo -e "${YELLOW}⚠ Graph bootstrap had issues (exit=$BOOT_RC) — continuing because stack is $STACK_SUPPORT.${NC}"
        echo "  Status: .intellisense/graph-status.json (readiness=failed)"
        GRAPH_BOOT_OK=false
        ;;
    esac
  fi

  # Post-condition: for mandatory-supported stacks, the success contract is
  # observable from the filesystem, not just from graph-bootstrap.sh's exit
  # code. Defense-in-depth against (a) wrappers that lose exit codes and
  # (b) future graph-bootstrap.sh paths that might exit 0 without writing
  # the status file. Discovered during real-run validation: the failure
  # signal can be invisible to setup-repos.sh's caller if only the exit
  # code is checked.
  if [ "$STACK_SUPPORT" = "mandatory-supported" ]; then
    GRAPH_STATUS_FILE="$REPO_PATH/.intellisense/graph-status.json"
    if [ ! -f "$GRAPH_STATUS_FILE" ]; then
      echo -e "${RED}✗ Graph post-condition FAILED: $GRAPH_STATUS_FILE not found.${NC}" >&2
      echo "  Mandatory-supported stack '$STACK' requires graph-bootstrap to write a status file." >&2
      echo "  This often indicates code-review-graph could not be located or build was aborted." >&2
      exit 1
    fi
    GRAPH_READINESS=""
    if command -v jq >/dev/null 2>&1; then
      GRAPH_READINESS=$(jq -r '.readiness // ""' "$GRAPH_STATUS_FILE" 2>/dev/null || echo "")
    else
      GRAPH_READINESS=$(grep -oE '"readiness"[[:space:]]*:[[:space:]]*"[^"]*"' "$GRAPH_STATUS_FILE" \
        | head -1 | sed -E 's/.*"readiness"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')
    fi
    if [ "$GRAPH_READINESS" != "ready" ]; then
      echo -e "${RED}✗ Graph post-condition FAILED: readiness='$GRAPH_READINESS' (expected 'ready').${NC}" >&2
      echo "  Status file: $GRAPH_STATUS_FILE" >&2
      echo "  Mandatory-supported stack '$STACK' requires readiness=ready." >&2
      exit 1
    fi
    echo -e "  ${GREEN}✓${NC} Graph post-condition: readiness=ready"
  fi
fi
fi  # code intelligence = code-review-graph


# Write version + manifest files.
#
# Idempotency: on a version-match re-run (SKIP_CLAUDE_MD_SETUP=true) we MUST
# preserve the existing committed .intellisense/version and .intellisense/manifest.json
# byte-for-byte. Otherwise every developer who pulls a setup-configured repo
# and re-runs setup produces a spurious diff in tracked files:
#   - .intellisense/version would otherwise change INSTALLED_DATE / UPDATED_BY each run
#   - .intellisense/manifest.json would otherwise be overwritten with components=[],
#     because INSTALLED_COMPONENTS is only populated by code paths that
#     execute on first install / --force (claude-md, knowledge-base, hooks,
#     github-actions). Writing [] would silently disable downstream verify
#     checks gated on .components[] (verify-setup.sh:83, check-repo.sh:42).
#
# .intellisense/version is the only tracked file written here that consumers actually
# read — and they only read INTELLISENSE_VERSION= and STACK=. The other former
# fields (INSTALLED_DATE, UPDATED_BY, INTELLISENSE_SETUP_PATH) had zero readers and
# duplicated data already captured in .intellisense/local.json (gitignored). Dropped.
#
# Trigger: fresh install OR --force OR version mismatch upgrade.
# Skip:    version-match re-run on the same machine OR by a different developer.
ensure_intellisense_state_dir "$REPO_PATH"
if [ "$VERSION_MATCH" != true ] || [ "$FORCE_INSTALL" = true ]; then
  cat > "$(intellisense_state_path "$REPO_PATH" version)" << EOF
INTELLISENSE_VERSION=$INTELLISENSE_VERSION
STACK=$STACK
EOF
  echo -e "${DIM}✓ Version file written: .intellisense/version ($INTELLISENSE_VERSION)${NC}"

  # Serialize INSTALLED_COMPONENTS array to JSON
  components_json=$(printf '"%s",' "${INSTALLED_COMPONENTS[@]}" | sed 's/,$//')
  components_json="[$components_json]"

  write_manifest "$REPO_PATH" "$STACK" "$components_json"
  echo -e "${DIM}✓ Manifest written: .intellisense/manifest.json${NC}"
else
  echo -e "${DIM}✓ Version + manifest preserved (version match, no rewrite)${NC}"
fi

# .intellisense/local.json is gitignored per-developer state — always write so the
# current machine's install_by/install_date is current. No diff cost.
write_local "$REPO_PATH" "$INTELLISENSE_SETUP_DIR" "$INTELLISENSE_VERSION"
echo -e "${DIM}✓ Local state written: .intellisense/local.json (gitignored)${NC}"

# Ensure .gitignore covers the local-state path.
if [ -f "$REPO_PATH/.gitignore" ] && ! grep -qE '^\.intellisense/local\.json[[:space:]]*$' "$REPO_PATH/.gitignore"; then
  echo '.intellisense/local.json' >> "$REPO_PATH/.gitignore"
fi

# Ensure .gitignore covers .intellisense/.backup/ — the per-developer-local
# capture of the pre-intellisense CLAUDE.md original. It's machine-local state, must
# never be committed.
if [ -f "$REPO_PATH/.gitignore" ] && ! grep -qE '^\.intellisense/\.backup/?[[:space:]]*$' "$REPO_PATH/.gitignore"; then
  echo '.intellisense/.backup/' >> "$REPO_PATH/.gitignore"
fi
echo ""

# Step 5: Print summary and next steps
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  intellisense Repo Setup Complete ✓${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${BOLD}$(basename $REPO_PATH)/${NC}  ${DIM}[intellisense configured]${NC}"
echo -e "  ├── ${GREEN}CLAUDE.md${NC}  [intellisense template, $STACK stack]"
echo -e "  ├── ${BOLD}knowledge-base/${NC}  ${DIM}[documentation stubs]${NC}"
_SUMMARY_HOOK=$(resolve_pre_push_hook_path "$REPO_PATH" 2>/dev/null || echo "")
[ -n "$_SUMMARY_HOOK" ] && [ -f "$_SUMMARY_HOOK" ] \
  && echo -e "  ├── ${GREEN}pre-push hook${NC}  [intellisense fork-first → $(basename $(dirname $_SUMMARY_HOOK))/pre-push]" \
  || echo -e "  ├── pre-push hook  [skipped]"
[ -f "$REPO_PATH/.intellisense-bootstrap.md" ] \
  && echo -e "  ├── ${YELLOW}.intellisense-bootstrap.md${NC}  [scaffolding — migrate to CLAUDE.md, then delete]" \
  || echo -e "  ├── .intellisense-bootstrap.md  [generated by setup-repos.sh]"
[ -f "$REPO_PATH/.intellisense-doc-health.json" ] \
  && echo -e "  └── ${GREEN}.intellisense-doc-health.json${NC}  [intellisense health tracking]" \
  || echo -e "  └── .intellisense-doc-health.json  [created after /intellisense-audit runs]"
echo ""
echo -e "${BOLD}Knowledge Base Status:${NC}"
echo ""

# Build knowledge-base status report
if [ -f "$(intellisense_state_path "$REPO_PATH" stubs-status)" ]; then
  echo -e "${GREEN}✅ Auto-filled by Claude (review & enhance):${NC}"
  echo "  • 00-system-context.md          (70%) — service metadata, stack, owned tables"
  echo "  • 00-system-architecture.md     (60%) — directory structure, layers, data flow"
  echo "  • 01-system-tech-stack.md       (85%) — language version, framework, top deps"
  echo "  • 01-system-source-tree.md      (90%) — depth-3 tree with layer descriptions"
  echo "  • 02-api-contracts.md           (85%) — endpoints, auth, routes"
  echo "  • 02-data-models.md             (90%) — tables/models, columns, relationships"
  echo "  • 04-eng-testing-guide.md       (30%) — test framework, structure, CI gates"
  echo ""
  echo -e "${YELLOW}❌ Empty — Requires team input:${NC}"
  echo "  • 03-biz-critical-flows.md      (45 min) Senior dev — How key flows work"
  echo "  • 03-biz-domain-rules.md        (30 min) Architect — Business rules, constraints"
  echo "  • 04-eng-gotchas.md             (30 min) Tech lead — Production lessons learned"
  echo "  • 04-eng-conventions.md         (20 min) Tech lead — Naming, error handling, PR checklist"
  echo "  • 05-meta-changelog.md          (ongoing) All — Feature changelog"
  echo ""
  echo -e "${DIM}Total effort: ~2 hours split across roles (not per person)${NC}"
else
  echo -e "${YELLOW}⚠️  Knowledge-base extraction skipped (Claude CLI not available)${NC}"
fi

echo ""
echo -e "${BOLD}Next steps:${NC}"
echo -e "  1. Review auto-filled knowledge-base/ stubs — no action needed, optional enhancements welcome"
echo -e "  2. Fill empty stubs (03-biz-* through 05-meta-changelog.md) — assign to team roles above"
echo -e "  3. Fill ${YELLOW}.intellisense-bootstrap.md${NC} — add Architecture, Domain Terms, Known Gotchas"
echo -e "  4. Migrate verified content to ${GREEN}CLAUDE.md${NC}, then delete the bootstrap file"
echo ""

# ── record this repo in the intellisense onboarded list + fire heartbeat ──
# Data source: heartbeat reads $HOME/.intellisense/onboarded-repos.tsv
# Fire the heartbeat once at the end of onboarding so the dashboard
# picks up the new repo within seconds, not at the next daily cron.
#
# Extracted to a function for testability. Called below.
intellisense_record_onboarded_repo_and_fire_heartbeat() {
  local repo_path="${1:-$REPO_PATH}"
  local stack="${2:-${STACK:-unknown}}"
  local intellisense_setup="${3:-${INTELLISENSE_SETUP_DIR:-$INTELLISENSE_SETUP}}"

  if [ -z "$repo_path" ] || [ ! -d "$repo_path" ]; then
    return 0
  fi

  local onboarded_list="$HOME/.intellisense/onboarded-repos.tsv"
  mkdir -p "$(dirname "$onboarded_list")" 2>/dev/null
  chmod 700 "$(dirname "$onboarded_list")" 2>/dev/null || true

  # Idempotent append: strip any prior entry for this path, then append.
  if [ -f "$onboarded_list" ]; then
    local tmp_list
    tmp_list="$(mktemp)"
    grep -v -F "$(printf '%s\t' "$repo_path")" "$onboarded_list" > "$tmp_list" 2>/dev/null || true
    mv "$tmp_list" "$onboarded_list"
  fi
  printf '%s\t%s\n' "$repo_path" "$stack" >> "$onboarded_list"
  chmod 644 "$onboarded_list" 2>/dev/null || true

  # Fire heartbeat once if installed. Best-effort: queues silently on failure.
  local heartbeat_script="$intellisense_setup/scripts/intellisense-heartbeat.sh"
  if [ -x "$heartbeat_script" ] && [ -f "$HOME/.intellisense/heartbeat-token" ]; then
    ( bash "$heartbeat_script" >/dev/null 2>&1 ) || true
  fi
}

intellisense_record_onboarded_repo_and_fire_heartbeat "$REPO_PATH" "${STACK:-unknown}" "${INTELLISENSE_SETUP_DIR:-$INTELLISENSE_SETUP}"

# ─────────────────────────────────────────────────────────────────────────────
# Optionally apply rebase-only merge policy to upstream repo
#
# Off by default — flip via --apply-merge-policy. Requires gh CLI authenticated
# with admin on the upstream repo. Failures here are non-fatal (the onboarding
# already succeeded); operator can re-run scripts/apply-merge-policy.sh
# directly with admin credentials later.
# ─────────────────────────────────────────────────────────────────────────────
if [ "$APPLY_MERGE_POLICY" = "true" ]; then
    APPLY_SCRIPT="$SCRIPT_DIR/scripts/apply-merge-policy.sh"
    if [ ! -x "$APPLY_SCRIPT" ]; then
        echo "⚠ --apply-merge-policy requested but scripts/apply-merge-policy.sh not executable" >&2
    else
        # Derive owner/repo from upstream remote (fallback: origin).
        UPSTREAM_URL="$(cd "$REPO_PATH" && git remote get-url upstream 2>/dev/null || git remote get-url origin 2>/dev/null || echo "")"
        # Parse owner/repo from URL forms: git@github.com:owner/repo.git or https://github.com/owner/repo.git
        OWNER_REPO="$(echo "$UPSTREAM_URL" | sed -E 's#.*github\.com[:/]([^/]+/[^/]+)\.git$#\1#; s#.*github\.com[:/]([^/]+/[^/]+)$#\1#')"
        if [ -z "$OWNER_REPO" ] || [ "$OWNER_REPO" = "$UPSTREAM_URL" ]; then
            echo "⚠ --apply-merge-policy: could not parse owner/repo from remote URL '$UPSTREAM_URL'" >&2
            echo "  Skipping merge-policy step. Re-run scripts/apply-merge-policy.sh manually." >&2
        else
            echo ""
            echo "→ applying rebase-only merge policy to $OWNER_REPO"
            if "$APPLY_SCRIPT" --repo "$OWNER_REPO" --manifest-dir "$REPO_PATH"; then
                echo "  ✓ merge policy applied"
            else
                echo "⚠ merge-policy step failed (likely missing admin on $OWNER_REPO)." >&2
                echo "  Onboarding still succeeded. Re-run scripts/apply-merge-policy.sh with admin creds." >&2
            fi
        fi
    fi
fi
