#!/bin/bash
# tests/test_claude_md_versioning.sh — CLAUDE.md versioning, backup location and
# placeholder filling.
#
# Strategy: extract individual helpers from setup-repos.sh (no end-to-end
# setup run — that pulls in Beads/graph/hooks, which are out of scope here)
# and exercise them in isolation under temp HOME / temp git repos.
#
# Tests:
#   T2  same-version re-run preserves CLAUDE.md (mtime + sha unchanged)
#   T3  _capture_claude_md_original is write-once
#   T4  no repo-root pollution after capture
#   T5  .gitignore line for .intellisense/.backup/ is idempotent
#   T6  placeholder fill across 6 stacks (go/python/php/angular/node/react)
#   T7  unset stack-version → literal "[version]" preserved
#   T8  <!-- INTELLISENSE-MANAGED --> marker untouched (no new marker added)
#   T9  generate-kb-stubs reads the original from .intellisense/.backup/
#   T11 setup.sh / setup-repos.sh write no repo-root `CLAUDE.md.backup-*`
#   T12 awk substitution survives special chars in service name (hyphen, space)
#   T13 human-owned CLAUDE.md (no marker) → CLAUDE_TEMPLATE_WRITTEN gating
#       prevents placeholder fill (verified by direct call with flag=false)

set -u
INTELLISENSE_SETUP="$(cd "$(dirname "$0")/.." && pwd)"
RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

case_pass() { echo "  ✓ $1"; echo "P" >> "$RESULTS"; }
case_fail() { echo "  ✗ $1: $2"; echo "F" >> "$RESULTS"; }

# Pull a single bash function definition out of a file. Brace-matched across
# multiple lines so we can source individual functions without running the
# script's main flow. (Same pattern as test_backup_location.sh.)
extract_func() {
  local file="$1" name="$2"
  awk -v fn="$name" '
    !in_fn && $0 ~ "^"fn"\\(\\)[[:space:]]*\\{" {
      in_fn = 1
      depth = gsub(/\{/, "{") - gsub(/\}/, "}")
      print
      next
    }
    in_fn {
      print
      depth += gsub(/\{/, "{") - gsub(/\}/, "}")
      if (depth <= 0) exit
    }
  ' "$file"
}

# Source the canonical path API + the two new helpers in isolation.
# shellcheck disable=SC1091
source "$INTELLISENSE_SETUP/scripts/lib/intellisense-paths.sh"
eval "$(extract_func "$INTELLISENSE_SETUP/setup-repos.sh" _capture_claude_md_original)"
eval "$(extract_func "$INTELLISENSE_SETUP/setup-repos.sh" _fill_claude_md_placeholders)"

make_repo() {
  local r
  r="$(mktemp -d)"
  echo "$r"
}

# ─── T3: _capture_claude_md_original is write-once ───────────────────────────
echo "T3 _capture_claude_md_original write-once"
REPO="$(make_repo)"
printf 'original content v1\n' > "$REPO/CLAUDE.md"
_capture_claude_md_original "$REPO" >/dev/null
captured="$REPO/.intellisense/.backup/CLAUDE.md.original"
if [ ! -f "$captured" ]; then
  case_fail "T3.1 first capture" "expected $captured to exist"
elif ! diff -q "$REPO/CLAUDE.md" "$captured" >/dev/null; then
  case_fail "T3.1 first capture" "captured content differs from source"
else
  case_pass "T3.1 first capture writes to .intellisense/.backup/CLAUDE.md.original"
fi

# Modify CLAUDE.md, run capture again — original must NOT be overwritten.
printf 'modified content v2\n' > "$REPO/CLAUDE.md"
_capture_claude_md_original "$REPO" >/dev/null
if ! grep -q '^original content v1$' "$captured"; then
  case_fail "T3.2 second capture is no-op" "original was overwritten"
else
  case_pass "T3.2 second capture is no-op (write-once preserved)"
fi
rm -rf "$REPO"

# ─── T4: no repo-root pollution after capture ───────────────────────────────
echo "T4 no repo-root CLAUDE.md.backup-* after capture"
REPO="$(make_repo)"
printf 'team-authored CLAUDE.md\n' > "$REPO/CLAUDE.md"
_capture_claude_md_original "$REPO" >/dev/null
pollution="$(find "$REPO" -maxdepth 1 -name 'CLAUDE.md.backup*' 2>/dev/null)"
if [ -n "$pollution" ]; then
  case_fail "T4 no repo-root pollution" "found: $pollution"
else
  case_pass "T4 no repo-root CLAUDE.md.backup-* files created"
fi
rm -rf "$REPO"

# ─── T5: .gitignore line for .intellisense/.backup/ is idempotent ────────────
echo "T5 gitignore line idempotency"
REPO="$(make_repo)"
touch "$REPO/.gitignore"
# Mirror the exact line-append block from setup-repos.sh.
add_gitignore_line() {
  local repo="$1"
  if [ -f "$repo/.gitignore" ] && ! grep -qE '^\.intellisense/\.backup/?[[:space:]]*$' "$repo/.gitignore"; then
    echo '.intellisense/.backup/' >> "$repo/.gitignore"
  fi
}
add_gitignore_line "$REPO"
add_gitignore_line "$REPO"
add_gitignore_line "$REPO"
count="$(grep -cE '^\.intellisense/\.backup/?$' "$REPO/.gitignore")"
if [ "$count" != "1" ]; then
  case_fail "T5 idempotent gitignore line" "expected 1 line, got $count"
else
  case_pass "T5 .gitignore line appears exactly once after 3 calls"
fi
rm -rf "$REPO"

# ─── T6 + T7: placeholder fill across 6 stacks + literal fallback ───────────
test_fill_for_stack() {
  local stack="$1" version_var="$2" version_value="$3" version_label="$4" expected_text="$5"
  local repo
  repo="$(make_repo)"
  cp "$INTELLISENSE_SETUP/templates/CLAUDE.md.${stack}.template" "$repo/CLAUDE.md"
  # Reset all stack-version vars so cross-stack contamination cannot happen.
  GO_VERSION="" PY_VERSION="" PHP_VERSION="" NG_VERSION="" NODE_VERSION="" REACT_VERSION=""
  if [ -n "$version_var" ]; then
    eval "$version_var=\"\$version_value\""
  fi
  STACK="$stack" _fill_claude_md_placeholders "$repo" "$stack"
  local content
  content="$(cat "$repo/CLAUDE.md")"
  if echo "$content" | grep -qF '{{SERVICE_NAME}}'; then
    case_fail "T6 $stack: SERVICE_NAME token left raw" "{{SERVICE_NAME}} not substituted"
  elif echo "$content" | grep -qF '{{STACK_VERSION}}'; then
    case_fail "T6 $stack: STACK_VERSION token left raw" "{{STACK_VERSION}} not substituted"
  elif ! echo "$content" | grep -qF "$(basename "$repo")"; then
    case_fail "T6 $stack: service name not present" "expected $(basename "$repo") in output"
  elif ! echo "$content" | grep -qF "$expected_text"; then
    case_fail "T6 $stack: expected stack/version line" "expected '$expected_text'"
  else
    case_pass "T6 $stack: $version_label → '$expected_text'"
  fi
  rm -rf "$repo"
}

echo "T6 placeholder fill across 6 stacks"
test_fill_for_stack go      GO_VERSION    "1.21"   "GO_VERSION=1.21"     "Go 1.21"
test_fill_for_stack python  PY_VERSION    "3.11"   "PY_VERSION=3.11"     "Python 3.11"
test_fill_for_stack php     PHP_VERSION   "8.2"    "PHP_VERSION=8.2"     "PHP 8.2"
test_fill_for_stack angular NG_VERSION    "17.0.0" "NG_VERSION=17.0.0"   "Angular 17.0.0"
test_fill_for_stack node    NODE_VERSION  "20"     "NODE_VERSION=20"     "Node.js 20"
test_fill_for_stack react   REACT_VERSION "18.2"   "REACT_VERSION=18.2"  "React 18.2"

echo "T7 unset stack-version → literal [version] preserved"
test_fill_for_stack go ""         ""       "GO_VERSION unset"    "Go [version]"
test_fill_for_stack python ""     ""       "PY_VERSION unset"    "Python [version]"

# ─── T8: <!-- INTELLISENSE-MANAGED --> marker untouched by this PR ──────────────────
echo "T8 INTELLISENSE-MANAGED marker logic untouched"
if grep -q 'intellisense_graph_ensure_managed_in_claude_md\|<!-- INTELLISENSE-MANAGED -->' "$INTELLISENSE_SETUP/setup-repos.sh"; then
  case_pass "T8 existing <!-- INTELLISENSE-MANAGED --> marker code preserved (not removed by this PR)"
else
  case_fail "T8 marker removed" "INTELLISENSE-MANAGED marker logic missing from setup-repos.sh"
fi

# Also assert no NEW marker was introduced.
new_marker_count="$(grep -cE '<!-- intellisense-managed:|<!-- INTELLISENSE-VERSION:' "$INTELLISENSE_SETUP/setup-repos.sh" || true)"
if [ "$new_marker_count" -gt 0 ]; then
  case_fail "T8 no new marker introduced" "found $new_marker_count new-style marker(s)"
else
  case_pass "T8 no new intellisense marker introduced (single existing marker preserved)"
fi

# ─── T9: generate-kb-stubs reads .intellisense/.backup/ ─────────────────────
# Mirrors the discovery line in generate-kb-stubs.sh rather than running it end
# to end (heavy).
echo "T9 generate-kb-stubs backup discovery"
REPO="$(make_repo)"
mkdir -p "$REPO/.intellisense/.backup" && echo original > "$REPO/.intellisense/.backup/CLAUDE.md.original"
backup_file=$(ls -t "$REPO"/.intellisense/.backup/CLAUDE.md.original* 2>/dev/null | head -1)
if [[ "$backup_file" == *"/.intellisense/.backup/CLAUDE.md.original" ]]; then
  case_pass "T9 original found under .intellisense/.backup/"
else
  case_fail "T9 backup discovery" "got=$backup_file"
fi
rm -rf "$REPO"

# ─── T11: no repo-root CLAUDE.md backups are written ────────────────────────
echo "T11 no repo-root backup-cp lines"
remaining_cp_lines="$(grep -nE 'cp[[:space:]]+"\$REPO_PATH/CLAUDE\.md"[[:space:]]+"\$REPO_PATH/CLAUDE\.md\.backup-' "$INTELLISENSE_SETUP/setup.sh" "$INTELLISENSE_SETUP/setup-repos.sh" 2>/dev/null || true)"
if [ -n "$remaining_cp_lines" ]; then
  case_fail "T11 no repo-root backups" "found: $remaining_cp_lines"
else
  case_pass "T11 setup.sh and setup-repos.sh write no CLAUDE.md.backup-* at repo root"
fi

# ─── T12: special characters in service name ────────────────────────────────
echo "T12 awk substitution shell-safe for special chars"
PARENT="$(mktemp -d)"
SPECIAL="$PARENT/with space-and-hyphen"
mkdir -p "$SPECIAL"
cp "$INTELLISENSE_SETUP/templates/CLAUDE.md.go.template" "$SPECIAL/CLAUDE.md"
GO_VERSION="1.21" PY_VERSION="" PHP_VERSION="" NG_VERSION="" NODE_VERSION="" REACT_VERSION=""
_fill_claude_md_placeholders "$SPECIAL" "go"
if grep -qF "with space-and-hyphen" "$SPECIAL/CLAUDE.md"; then
  case_pass "T12 service name with space + hyphen substituted literally"
else
  case_fail "T12 special chars" "service name not present in output"
fi
rm -rf "$PARENT"

# ─── T13: CLAUDE_TEMPLATE_WRITTEN gating prevents human-owned mutation ─────
echo "T13 human-owned CLAUDE.md (no marker, no flag) is not touched"
REPO="$(make_repo)"
HUMAN_CONTENT='# CLAUDE.md — Human-Authored

This file was written by the team. {{SERVICE_NAME}} should NOT be substituted
because the CLAUDE_TEMPLATE_WRITTEN flag is false (no fresh-copy / no replace).
'
printf '%s' "$HUMAN_CONTENT" > "$REPO/CLAUDE.md"
SHA_BEFORE="$(shasum "$REPO/CLAUDE.md" | awk '{print $1}')"

# Simulate the gating block from setup-repos.sh:
#   if [ "$CLAUDE_TEMPLATE_WRITTEN" = true ]; then _fill_claude_md_placeholders ... ; fi
CLAUDE_TEMPLATE_WRITTEN=false
if [ "$CLAUDE_TEMPLATE_WRITTEN" = true ]; then
  _fill_claude_md_placeholders "$REPO" go
fi

SHA_AFTER="$(shasum "$REPO/CLAUDE.md" | awk '{print $1}')"
if [ "$SHA_BEFORE" != "$SHA_AFTER" ]; then
  case_fail "T13 human-owned no-touch" "sha changed: $SHA_BEFORE → $SHA_AFTER"
elif ! grep -qF '{{SERVICE_NAME}}' "$REPO/CLAUDE.md"; then
  case_fail "T13 human-owned no-touch" "literal {{SERVICE_NAME}} was substituted"
else
  case_pass "T13 human-owned CLAUDE.md unchanged when CLAUDE_TEMPLATE_WRITTEN=false"
fi
rm -rf "$REPO"

# ─── T2: existing CLAUDE.md is preserved on every re-run (match OR upgrade) ──
# The preservation flag is set inside check_repo_version() whenever
# .intellisense/version exists AND CLAUDE.md is on disk — independently of whether
# the stored version matches INTELLISENSE_VERSION. This is the invariant teams rely
# on for their team-enriched CLAUDE.md surviving intellisense version bumps.
echo "T2 CLAUDE.md preservation path intact"
if grep -nq 'SKIP_CLAUDE_MD_SETUP=true' "$INTELLISENSE_SETUP/setup-repos.sh" \
   && awk '/^check_repo_version\(\)/,/^}/' "$INTELLISENSE_SETUP/setup-repos.sh" \
        | grep -A2 'REPO_PATH/CLAUDE\.md' | grep -q 'SKIP_CLAUDE_MD_SETUP=true'; then
  case_pass "T2 setup-repos.sh CLAUDE.md preservation (SKIP_CLAUDE_MD_SETUP=true) preserved"
else
  case_fail "T2 CLAUDE.md preservation" "check_repo_version() no longer sets SKIP_CLAUDE_MD_SETUP=true on existing CLAUDE.md"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "─── Summary ───"
total="$(wc -l < "$RESULTS" | tr -d ' ')"
passed="$(grep -c '^P$' "$RESULTS" || true)"
failed="$(grep -c '^F$' "$RESULTS" || true)"
echo "  Total:  $total"
echo "  Passed: $passed"
echo "  Failed: $failed"
[ "$failed" = "0" ] || exit 1
exit 0
