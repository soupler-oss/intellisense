#!/bin/bash
#
# add-frontmatter.sh — one-off tool that stamps every rule/skill/agent
# markdown file with YAML frontmatter (id, version, updated, scope,
# layer, category, breaking).
#
# Idempotent: skips files that already have a `---` as their first line.
# Safe to rerun when new files land.
#
# Usage:  bash scripts/add-frontmatter.sh
#         bash scripts/add-frontmatter.sh --dry-run
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

today="$(date -u +%Y-%m-%d)"
added=0
skipped=0

# derive scope/layer/category/id from the file path
derive_meta() {
  local path="$1"
  local rel="${path#./}"

  case "$rel" in
    core/*)                    scope="core" ;;
    overlays/*)                scope="overlay/$(echo "$rel" | cut -d/ -f2)" ;;
    *)                         scope="misc" ;;
  esac

  case "$rel" in
    */rules/*)     layer="rules" ;;
    */skills/*)    layer="skills" ;;
    */agents/*)    layer="agents" ;;
    */templates/*) layer="templates" ;;
    *)             layer="docs" ;;
  esac

  case "$rel" in
    */rules/baseline/*)              category="baseline" ;;
    */rules/operational/*)           category="operational" ;;
    */rules/protocols/*)             category="protocols" ;;
    */rules/language-specific/*)     category="language-specific" ;;
    */skills/implementation/*)       category="implementation" ;;
    */skills/verification/*)         category="verification" ;;
    */skills/diagnosis/*)            category="diagnosis" ;;
    */skills/planning/*)             category="planning" ;;
    */skills/qa/*)                   category="qa" ;;
    */skills/incidents/*)            category="incidents" ;;
    */skills/knowledge/*)            category="knowledge" ;;
    */skills/onboarding/*)           category="onboarding" ;;
    */skills/analysis/*)             category="analysis" ;;
    *)                               category="general" ;;
  esac

  # Stable id = relative path without extension, slash-separated.
  id="${rel%.md}"
}

stamp() {
  local file="$1"
  # Already has frontmatter? Line 1 equals exactly "---"?
  if [ "$(head -n1 "$file")" = "---" ]; then
    skipped=$((skipped + 1))
    return
  fi

  derive_meta "$file"

  local header
  header=$(cat <<YAML
---
id: ${id}
version: 1.0.0
updated: ${today}
scope: ${scope}
layer: ${layer}
category: ${category}
breaking: false
---

YAML
)

  if [ "$DRY_RUN" = "1" ]; then
    echo "[+] $file  (scope=$scope layer=$layer cat=$category)"
  else
    local tmp
    tmp="$(mktemp)"
    # Command substitution strips trailing newlines; add them back
    # explicitly so the closing --- sits on its own line with a
    # blank line separating it from the file's first heading.
    printf "%s\n\n" "$header" > "$tmp"
    cat "$file" >> "$tmp"
    mv "$tmp" "$file"
  fi
  added=$((added + 1))
}

# Stamp every .md under the content dirs (excluding top-level docs).
while IFS= read -r f; do
  stamp "$f"
done < <(find core/rules core/skills core/agents \
              overlays/*/rules overlays/*/skills overlays/*/agents \
              -name "*.md" -type f 2>/dev/null | sort)

echo ""
echo "Frontmatter summary:"
echo "  Added:   $added"
echo "  Skipped: $skipped (already had frontmatter)"
[ "$DRY_RUN" = "1" ] && echo "  (dry-run — no files modified)"
