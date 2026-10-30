#!/bin/bash

# test_memory_canonical.sh — intellisense never stores shared knowledge in MEMORY.md: it goes into rules,
# or Beads memories when the team uses Beads. intellisense artifacts must NOT instruct agents to write or
# update intellisense memory in MEMORY.md.
#
# Scope (intellisense-owned artifacts only):
#   - setup.sh                                  (bootstrap; emits global CLAUDE.md)
#   - skills/                                   (in-context prompt templates)
#   - rules/operational/, rules/baseline/       (rules loaded into every session)
#   - docs/                                     (developer-facing platform docs)
#
# Out of scope:
#   - .intellisense/session/**                          (per-developer audit artifacts)
#   - tests/                                    (test files themselves are allowed
#                                                to reference the forbidden phrases
#                                                because the test code IS the
#                                                allow-list mechanism)
#   - memory/                                   (the auto-memory store itself)
#   - rules/operational/task-tracking-beads.md  (intentionally contrasts beads vs
#                                                MEMORY.md to teach the rule)
#
# Allow-listed contexts (notes that say NOT to use MEMORY.md):
#   A line is allowed when it ALSO contains a marker, e.g.
#   "do NOT", "not used by intellisense",
#   or "bd remember". The intent: docs may explain that MEMORY.md is not used;
#   what they may NOT do is tell an agent to *write* to MEMORY.md.
#
# Failure mode: any active "write/update MEMORY.md" instruction in an
# intellisense-owned artifact fails the test.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

INTELLISENSE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Test Suite: intellisense memory never goes to MEMORY.md${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ─────────────────────────────────────────────────────────────
# Forbidden patterns: phrases that instruct an agent to write
# intellisense memory to MEMORY.md. Case-insensitive ERE.
# ─────────────────────────────────────────────────────────────
FORBIDDEN_PATTERNS=(
  'write[[:space:]]+(to[[:space:]]+)?MEMORY\.md'
  'update[[:space:]]+MEMORY\.md'
  'add[[:space:]]+to[[:space:]]+MEMORY\.md'
  'save[[:space:]]+to[[:space:]]+MEMORY\.md'
  'edit[[:space:]]+MEMORY\.md'
  'Suggested[[:space:]]+MEMORY\.md[[:space:]]+Updates'
  'MEMORY\.md[[:space:]]+proposals'
  'extract[[:space:]]+patterns?[[:space:]]+to[[:space:]]+MEMORY\.md'
)

# ─────────────────────────────────────────────────────────────
# Allow-list markers: a line that matches a forbidden pattern
# but also contains one of these is treated as an informational
# note (not an instruction to write).
# ─────────────────────────────────────────────────────────────
ALLOW_MARKERS_ERE='(do NOT|does NOT|do not use MEMORY|not used by intellisense|bd remember)'

# ─────────────────────────────────────────────────────────────
# In-scope file set. We intentionally include only intellisense-owned
# artifacts that agents read as instructions.
# ─────────────────────────────────────────────────────────────
collect_in_scope_files() {
  # NUL-delimited list on stdout so paths with spaces are safe.
  {
    printf '%s\0' "$INTELLISENSE_ROOT/setup.sh"
    find "$INTELLISENSE_ROOT/skills" -type f -name '*.md' -print0 2>/dev/null || true
    find "$INTELLISENSE_ROOT/rules"  -type f -name '*.md' -print0 2>/dev/null || true
    find "$INTELLISENSE_ROOT/docs"   -type f -name '*.md' -print0 2>/dev/null || true
  }
}

# Files explicitly excluded from the scan (paths relative to INTELLISENSE_ROOT).
EXCLUDED=(
  "rules/operational/task-tracking-beads.md"   # teaches beads vs MEMORY.md by contrast
)

is_excluded() {
  local rel="$1"
  local ex
  for ex in "${EXCLUDED[@]}"; do
    [ "$rel" = "$ex" ] && return 0
  done
  return 1
}

scan_file_for_violations() {
  local file="$1"
  local rel="${file#"$INTELLISENSE_ROOT"/}"
  local pattern hit_line violation_count=0

  for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
    # grep -niE: line numbers, case-insensitive, extended regex
    while IFS= read -r hit_line; do
      [ -z "$hit_line" ] && continue
      # hit_line format: "<line_no>:<content>"
      local content="${hit_line#*:}"
      # Skip allow-listed informational notes.
      if echo "$content" | grep -qiE "$ALLOW_MARKERS_ERE"; then
        continue
      fi
      echo -e "  ${RED}✗${NC} ${rel}:${hit_line%%:*}  matches /${pattern}/"
      echo -e "      ${DIM}${content}${NC}"
      ((++violation_count))
    done < <(grep -niE "$pattern" "$file" 2>/dev/null || true)
  done

  return $violation_count
}

# ─────────────────────────────────────────────────────────────
# Test 1: no intellisense artifact contains an active "write MEMORY.md"
# instruction.
# ─────────────────────────────────────────────────────────────
echo -e "${BOLD}Test 1: intellisense artifacts do not instruct agents to write intellisense memory to MEMORY.md${NC}"
TOTAL_VIOLATIONS=0
FILES_SCANNED=0

while IFS= read -r -d '' file; do
  rel="${file#"$INTELLISENSE_ROOT"/}"
  if is_excluded "$rel"; then
    continue
  fi
  ((++FILES_SCANNED))
  if ! scan_file_for_violations "$file"; then
    TOTAL_VIOLATIONS=$((TOTAL_VIOLATIONS + $?))
  fi
done < <(collect_in_scope_files)

((++TESTS_RUN))
if [ "$TOTAL_VIOLATIONS" -eq 0 ]; then
  echo -e "  ${GREEN}✓${NC} scanned $FILES_SCANNED files; no forbidden MEMORY.md write-instructions found"
  ((++TESTS_PASSED))
else
  echo -e "  ${RED}✗${NC} $TOTAL_VIOLATIONS forbidden write-instruction(s) found across $FILES_SCANNED files"
  echo -e "    ${DIM}Team knowledge goes in rules, or bd remember with the Beads tracker.${NC}"
  echo -e "    ${DIM}If a line only says NOT to use MEMORY.md, mark it explicitly (e.g. 'do NOT',${NC}"
  echo -e "    ${DIM}'not used by intellisense') and it will be allow-listed.${NC}"
  ((++TESTS_FAILED))
fi
echo ""

# ─────────────────────────────────────────────────────────────
# Test 2: the generated global CLAUDE.md heredoc in setup.sh
# names bd remember / bd prime (positive assertion).
# ─────────────────────────────────────────────────────────────
echo -e "${BOLD}Test 2: setup.sh generated CLAUDE.md references bd remember / bd prime${NC}"
((++TESTS_RUN))
if grep -qE '(bd[[:space:]]+remember|bd[[:space:]]+prime)' "$INTELLISENSE_ROOT/setup.sh"; then
  echo -e "  ${GREEN}✓${NC} setup.sh names bd remember / bd prime as the intellisense memory commands"
  ((++TESTS_PASSED))
else
  echo -e "  ${RED}✗${NC} setup.sh does not reference bd remember / bd prime — CLAUDE.md must point developers at the canonical store"
  ((++TESTS_FAILED))
fi
echo ""

# ─────────────────────────────────────────────────────────────
# Test 3: setup.sh Step 11 writes a note that intellisense does not use
# MEMORY.md (not a fresh memory-store init) when MEMORY.md is missing.
# ─────────────────────────────────────────────────────────────
echo -e "${BOLD}Test 3: setup.sh Step 11 writes a 'not used by intellisense' MEMORY.md note (not a fresh memory store)${NC}"
((++TESTS_RUN))
if grep -qE 'MEMORY\.md — not used by intellisense' "$INTELLISENSE_ROOT/setup.sh"; then
  echo -e "  ${GREEN}✓${NC} setup.sh writes a 'not used by intellisense' note when MEMORY.md is absent"
  ((++TESTS_PASSED))
else
  echo -e "  ${RED}✗${NC} setup.sh does not write the 'not used by intellisense' note; it must NOT initialize MEMORY.md as an active intellisense memory store"
  ((++TESTS_FAILED))
fi
echo ""

# ─────────────────────────────────────────────────────────────
# Test 4: skills/learn/SKILL.md output spec has memory entries, and targets rules or Beads, never MEMORY.md.
# ─────────────────────────────────────────────────────────────
echo -e "${BOLD}Test 4: /learn output spec suggests memory entries for rules or Beads (not MEMORY.md)${NC}"
((++TESTS_RUN))
LEARN="$INTELLISENSE_ROOT/skills/learn/SKILL.md"
if grep -qE '^### Suggested Memory Entries' "$LEARN" && grep -qF '.intellisense/rules/organization/' "$LEARN" && grep -qF 'bd remember' "$LEARN"; then
  echo -e "  ${GREEN}✓${NC} /learn output spec suggests memory entries for rules, or bd remember with Beads"
  ((++TESTS_PASSED))
else
  echo -e "  ${RED}✗${NC} /learn output spec must suggest memory entries for rules (or bd remember with Beads)"
  ((++TESTS_FAILED))
fi
echo ""

# ─────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Tests run:    $TESTS_RUN"
echo -e "${GREEN}Passed:       $TESTS_PASSED${NC}"
if [ "$TESTS_FAILED" -gt 0 ]; then
  echo -e "${RED}Failed:       $TESTS_FAILED${NC}"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

exit "$TESTS_FAILED"
