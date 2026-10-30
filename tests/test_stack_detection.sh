#!/bin/bash
#
# test_stack_detection.sh — Phase 1 language-support invariants (static checks)
#
# Architecture rationale, file inventory, and rollback semantics:
#   docs/language-support-onboarding.md
#
# Eight blocking checks:
#   Check A — Shared-file purity
#     The shared operational files (testing.md, /tdd, /code-review) MUST NOT
#     enumerate any language-specific <X>-patterns.md file. The catalog
#     ai-regression-patterns.md is the only allowed *-patterns.md reference.
#
#   Check B — Forward consistency (catalog routing)
#     Every rules/language-specific/<stack>-patterns.md MUST appear at least
#     once in rules/operational/ai-regression-patterns.md (it must have a Route).
#
#   Check C — Reverse consistency (LANG_RULE ↔ patterns file)
#     Every LANG_RULE="<file>.md" reference in setup-repos.sh MUST resolve to
#     an existing rules/language-specific/<file>.md.
#
#   Check D — Stack-onboarding completeness (patterns file ↔ setup integration)
#     Every rules/language-specific/<stack>-patterns.md MUST be reachable from
#     setup-repos.sh via at least one LANG_RULE switch entry, AND the arm name
#     in that entry MUST have a corresponding templates/CLAUDE.md.<arm>.template.
#
#   Check E — Cross-switch LANG_RULE consistency (F6)
#     setup-repos.sh has multiple LANG_RULE switch blocks. For any stack arm
#     present in more than one switch, all assigned values MUST be identical.
#     Catches "one switch updated, another missed during refactor".
#
#   Check F — Validation arm ↔ LANG_RULE arm parity (F13)
#     The set of stacks declared in `case "$STACK" in <list>)` (validation arm)
#     MUST equal the set of arm names in LANG_RULE switches. Catches stacks
#     declared in one place but not the other.
#
#   Check G — Enforcement-chain integrity (F17)
#     docs/language-support-onboarding.md MUST reference tests/test_stack_detection.sh
#     so the test cannot be silently deleted without orphaning the doc's
#     validation checklist. Catches doc-side removal of the test reference.
#
#   Check H — setup.sh manual prompt ↔ setup-repos.sh validation parity
#     The Layer-3 manual-fallback prompt in setup.sh (`case "$MANUAL_STACK" in`)
#     MUST equal setup-repos.sh's validation arm (`case "$STACK" in`) minus
#     stacks classified `unsupported` by intellisense_graph_stack_support (vue).
#     Catches the regression where a stack is added to setup-repos.sh but the
#     manual prompt in setup.sh is left stale (react/node).
#
# Non-zero exit on any failure. Designed so the original Python omission would
# have failed Check A automatically.
#
# Known limits (intentionally deferred — see docs/language-support-onboarding.md):
#   - Manifest-detection block presence in setup-repos.sh is not statically
#     verified (G3). Symptom is degraded STACK_DETECTED=[TODO], not breakage.
#   - Stale §section references in catalog Routes are not statically verified
#     (G4). Reviewer-eye catch only; documented as advisory.
#   - Simultaneous deletion of this test + the doc reference in the same PR
#     bypasses Check G. Mitigated by CI integration (out of Phase 1 scope).
#
# This is a static test — no fixture execution of setup-repos.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ERRORS=0

fail() {
  echo -e "  ${RED}✗${NC} $1"
  ERRORS=$((ERRORS + 1))
}

pass() {
  echo -e "  ${GREEN}✓${NC} $1"
}

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  Test suite: language-support onboarding invariants"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────────
# Check A — Shared-file purity
# ─────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Check A:${NC} shared-file purity (no language-specific patterns enumeration)"

SHARED_FILES=(
  "rules/operational/testing.md"
  "skills/tdd/SKILL.md"
  "skills/code-review/SKILL.md"
)

# Pattern: any <lowercase>-patterns.md reference.
# Allowed exceptions:
#   - ai-regression-patterns.md (the catalog itself)
#   - anti-patterns.md (generic TDD anti-patterns reference, NOT a language-specific patterns file)
PATTERNS_REGEX='[a-z][a-z0-9-]*-patterns\.md'
EXCLUDE_REGEX='(ai-regression|anti)-patterns\.md'

for f in "${SHARED_FILES[@]}"; do
  full="$REPO_ROOT/$f"
  if [ ! -f "$full" ]; then
    fail "$f (file missing — cannot validate)"
    continue
  fi
  matches=$(grep -nE "$PATTERNS_REGEX" "$full" 2>/dev/null | grep -vE "$EXCLUDE_REGEX" || true)
  if [ -n "$matches" ]; then
    fail "$f enumerates language-specific patterns files (use generic catalog reference instead):"
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      echo "      $line"
    done <<< "$matches"
  else
    pass "$f is stack-agnostic"
  fi
done

echo ""

# ─────────────────────────────────────────────────────────────────────
# Check B — Forward consistency
# ─────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Check B:${NC} forward consistency (every patterns file has a catalog route)"

CATALOG_REL="rules/operational/ai-regression-patterns.md"
CATALOG="$REPO_ROOT/$CATALOG_REL"
LANG_DIR="$REPO_ROOT/rules/language-specific"

if [ ! -f "$CATALOG" ]; then
  fail "$CATALOG_REL not found"
elif [ ! -d "$LANG_DIR" ]; then
  fail "rules/language-specific/ directory not found"
else
  found_any=false
  for f in "$LANG_DIR"/*-patterns.md; do
    # Guard against literal glob if no files match
    [ -e "$f" ] || continue
    found_any=true
    rule_name=$(basename "$f")
    if grep -q "$rule_name" "$CATALOG"; then
      pass "$rule_name has at least one Route entry in catalog"
    else
      fail "$rule_name exists but no Route in $CATALOG_REL — must add Routes to ai-regression-patterns.md for this stack"
    fi
  done
  if [ "$found_any" = false ]; then
    fail "no <stack>-patterns.md files found in rules/language-specific/"
  fi
fi

echo ""

# ─────────────────────────────────────────────────────────────────────
# Check C — Reverse consistency
# ─────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Check C:${NC} reverse consistency (every setup-repos.sh LANG_RULE maps to existing file)"

SETUP="$REPO_ROOT/setup-repos.sh"

if [ ! -f "$SETUP" ]; then
  fail "setup-repos.sh not found"
else
  # Extract every distinct *.md filename mentioned in a LANG_RULE= assignment.
  # Empty LANG_RULE="" assignments are skipped (they are the wildcard fallback).
  rules_referenced=$(
    grep -oE 'LANG_RULE="[^"]+\.md"' "$SETUP" \
    | sed -E 's/LANG_RULE="([^"]+)"/\1/' \
    | sort -u
  )
  if [ -z "$rules_referenced" ]; then
    fail "no LANG_RULE entries found in setup-repos.sh (parser may be broken)"
  else
    while IFS= read -r rule; do
      [ -z "$rule" ] && continue
      target="$LANG_DIR/$rule"
      if [ -f "$target" ]; then
        pass "$rule referenced by setup-repos.sh and exists in rules/language-specific/"
      else
        fail "$rule referenced by setup-repos.sh but rules/language-specific/$rule is missing"
      fi
    done <<< "$rules_referenced"
  fi
fi

echo ""

# ─────────────────────────────────────────────────────────────────────
# Check D — Stack-onboarding completeness
# ─────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Check D:${NC} stack-onboarding completeness (LANG_RULE arm + template per patterns file)"

if [ ! -f "$SETUP" ]; then
  fail "setup-repos.sh not found"
elif [ ! -d "$LANG_DIR" ]; then
  fail "rules/language-specific/ directory not found"
else
  for f in "$LANG_DIR"/*-patterns.md; do
    [ -e "$f" ] || continue
    rule_name=$(basename "$f")

    # Find every distinct arm name whose LANG_RULE switch maps to this rule.
    arms=$(
      grep -E "^[[:space:]]*[a-z]+\)[[:space:]]+LANG_RULE=\"$rule_name\"" "$SETUP" \
      | sed -E 's/^[[:space:]]*([a-z]+)\).*/\1/' \
      | sort -u
    )

    if [ -z "$arms" ]; then
      fail "$rule_name has no LANG_RULE arm in setup-repos.sh — stack onboarding is incomplete (add a 'go|php|...|<stack>)' arm and a LANG_RULE=\"$rule_name\" switch)"
      continue
    fi

    while IFS= read -r arm; do
      [ -z "$arm" ] && continue
      template_rel="templates/CLAUDE.md.${arm}.template"
      template="$REPO_ROOT/$template_rel"
      if [ -f "$template" ]; then
        pass "$rule_name → ${arm}) → $template_rel exists"
      else
        fail "$rule_name maps to stack '${arm}' but $template_rel is missing — setup-repos.sh would fail at first onboarding"
      fi
    done <<< "$arms"
  done
fi

echo ""

# ─────────────────────────────────────────────────────────────────────
# Check E — Cross-switch LANG_RULE consistency (F6)
# ─────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Check E:${NC} cross-switch LANG_RULE consistency"

if [ ! -f "$SETUP" ]; then
  fail "setup-repos.sh not found"
else
  pairs=$(
    grep -E '^[[:space:]]*[a-z]+\)[[:space:]]+LANG_RULE="[^"]*"' "$SETUP" \
    | sed -E 's/^[[:space:]]*([a-z]+)\)[[:space:]]+LANG_RULE="([^"]*)".*/\1=\2/'
  )
  if [ -z "$pairs" ]; then
    fail "no non-wildcard LANG_RULE entries found in setup-repos.sh"
  else
    for arm in $(echo "$pairs" | cut -d= -f1 | sort -u); do
      values=$(echo "$pairs" | awk -F= -v arm="$arm" '$1 == arm { print $2 }' | sort -u)
      vcount=$(echo "$values" | grep -c .)
      ncount=$(echo "$pairs" | awk -F= -v arm="$arm" '$1 == arm' | wc -l | tr -d ' ')
      if [ "$vcount" -gt 1 ]; then
        joined=$(echo "$values" | tr '\n' '|' | sed 's/|$//')
        fail "stack '${arm}' has inconsistent LANG_RULE values across $ncount switches: $joined"
      else
        pass "stack '${arm}' agrees across $ncount LANG_RULE switch(es)"
      fi
    done
  fi
fi

echo ""

# ─────────────────────────────────────────────────────────────────────
# Check F — Validation arm ↔ LANG_RULE arm parity (F13)
# Excludes stacks classified "unsupported" by intellisense_graph_stack_support
# (e.g. vue) — they are intentionally in the validation arm so the graph
# bootstrap exception flow can fire, but they have no LANG_RULE because
# no <stack>-patterns.md exists. Same filter Check H uses.
# ─────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Check F:${NC} validation-arm ↔ LANG_RULE-arm parity (excluding unsupported)"

GRAPH_LIB_F="$REPO_ROOT/scripts/lib/intellisense-graph.sh"

if [ ! -f "$SETUP" ]; then
  fail "setup-repos.sh not found"
elif [ ! -f "$GRAPH_LIB_F" ]; then
  fail "scripts/lib/intellisense-graph.sh not found — needed to identify unsupported stacks"
else
  val_line_no=$(grep -n '^case "\$STACK" in' "$SETUP" | head -1 | cut -d: -f1)
  if [ -z "$val_line_no" ]; then
    fail "could not locate validation case statement (\`case \"\$STACK\" in\`)"
  else
    val_arm_raw=$(sed -n "$((val_line_no + 1))p" "$SETUP")
    val_stacks_raw=$(
      echo "$val_arm_raw" \
      | grep -oE '^[[:space:]]*[a-z|]+\)' \
      | tr -d ' )' \
      | tr '|' '\n' \
      | sort -u \
      | grep -v '^$' || true
    )

    # shellcheck disable=SC1090
    . "$GRAPH_LIB_F"

    val_stacks=""
    while IFS= read -r stack; do
      [ -z "$stack" ] && continue
      class=$(intellisense_graph_stack_support "$stack")
      if [ "$class" != "unsupported" ]; then
        val_stacks="${val_stacks}${stack}"$'\n'
      fi
    done <<< "$val_stacks_raw"
    val_stacks=$(printf '%s' "$val_stacks" | sort -u | grep -v '^$' || true)

    lang_arms=$(
      grep -E '^[[:space:]]*[a-z]+\)[[:space:]]+LANG_RULE="[^"]+"' "$SETUP" \
      | sed -E 's/^[[:space:]]*([a-z]+)\).*/\1/' \
      | sort -u
    )
    if [ -z "$val_stacks" ] || [ -z "$lang_arms" ]; then
      fail "could not extract stack lists (validation arm or LANG_RULE arms empty — parser may be broken)"
    else
      only_val=$(comm -23 <(echo "$val_stacks") <(echo "$lang_arms"))
      only_lang=$(comm -13 <(echo "$val_stacks") <(echo "$lang_arms"))
      if [ -n "$only_val" ]; then
        joined=$(echo "$only_val" | tr '\n' ',' | sed 's/,$//')
        fail "validation arm declares stacks with no LANG_RULE switch entry: $joined"
      fi
      if [ -n "$only_lang" ]; then
        joined=$(echo "$only_lang" | tr '\n' ',' | sed 's/,$//')
        fail "LANG_RULE switches reference stacks not in validation arm: $joined"
      fi
      if [ -z "$only_val" ] && [ -z "$only_lang" ]; then
        joined=$(echo "$val_stacks" | tr '\n' ',' | sed 's/,$//')
        pass "validation arm and LANG_RULE switches agree on stack list (excluding unsupported): $joined"
      fi
    fi
  fi
fi

echo ""

# ─────────────────────────────────────────────────────────────────────
# Check G — Enforcement-chain integrity (F17)
# ─────────────────────────────────────────────────────────────────────
echo -e "${YELLOW}Check G:${NC} enforcement-chain integrity (doc references this test)"

DOC_REL="docs/language-support-onboarding.md"
DOC="$REPO_ROOT/$DOC_REL"
TEST_REL="tests/test_stack_detection.sh"

if [ ! -f "$DOC" ]; then
  fail "$DOC_REL is missing — enforcement chain broken (deletion of this doc would orphan the test)"
elif ! grep -q "$TEST_REL" "$DOC"; then
  fail "$DOC_REL no longer references $TEST_REL — test could be silently removed without the doc's checklist breaking"
else
  refs=$(grep -c "$TEST_REL" "$DOC")
  pass "$DOC_REL references $TEST_REL ($refs occurrence(s)) — enforcement chain intact"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────
# Check H — setup.sh manual prompt ↔ setup-repos.sh validation parity
# ─────────────────────────────────────────────────────────────────────
# Why this check exists: setup.sh's Layer-3 manual-fallback prompt at
# `case "$MANUAL_STACK" in <list>)` is a second source of truth for the
# supported-stack list. If a new stack is added to setup-repos.sh's
# validation arm but the manual prompt is not updated, developers whose
# repos fail auto-detection cannot select the new stack — exactly the
# regression that bit react/node onboarding.
# Policy: setup.sh's manual list MUST equal setup-repos.sh's validation
# list, minus stacks classified `unsupported` by intellisense_graph_stack_support
# (currently: vue — auto-skipped downstream because no template exists).
echo -e "${YELLOW}Check H:${NC} setup.sh manual prompt ↔ setup-repos.sh validation parity (excluding unsupported)"

SETUP_GLOBAL="$REPO_ROOT/setup.sh"
GRAPH_LIB="$REPO_ROOT/scripts/lib/intellisense-graph.sh"

if [ ! -f "$SETUP_GLOBAL" ]; then
  fail "setup.sh not found at $SETUP_GLOBAL"
elif [ ! -f "$GRAPH_LIB" ]; then
  fail "scripts/lib/intellisense-graph.sh not found — needed to identify unsupported stacks"
elif [ ! -f "$SETUP" ]; then
  fail "setup-repos.sh not found"
else
  manual_line_no=$(grep -n 'case "\$MANUAL_STACK" in' "$SETUP_GLOBAL" | head -1 | cut -d: -f1)
  if [ -z "$manual_line_no" ]; then
    fail "could not locate manual stack case in setup.sh (\`case \"\$MANUAL_STACK\" in\`)"
  else
    manual_arm_raw=$(sed -n "$((manual_line_no + 1))p" "$SETUP_GLOBAL")
    manual_stacks=$(
      echo "$manual_arm_raw" \
      | grep -oE '^[[:space:]]*[a-z|]+\)' \
      | tr -d ' )' \
      | tr '|' '\n' \
      | sort -u \
      | grep -v '^$' || true
    )

    val_line_no_h=$(grep -n '^case "\$STACK" in' "$SETUP" | head -1 | cut -d: -f1)
    val_stacks_h=$(
      sed -n "$((val_line_no_h + 1))p" "$SETUP" \
      | grep -oE '^[[:space:]]*[a-z|]+\)' \
      | tr -d ' )' \
      | tr '|' '\n' \
      | sort -u \
      | grep -v '^$' || true
    )

    # shellcheck disable=SC1090
    . "$GRAPH_LIB"

    expected_manual=""
    while IFS= read -r stack; do
      [ -z "$stack" ] && continue
      class=$(intellisense_graph_stack_support "$stack")
      if [ "$class" != "unsupported" ]; then
        expected_manual="${expected_manual}${stack}"$'\n'
      fi
    done <<< "$val_stacks_h"
    expected_manual=$(printf '%s' "$expected_manual" | sort -u | grep -v '^$' || true)

    if [ -z "$manual_stacks" ] || [ -z "$expected_manual" ]; then
      fail "could not extract stack lists for parity check (parser or graph lib may be broken)"
    else
      missing=$(comm -23 <(echo "$expected_manual") <(echo "$manual_stacks"))
      extra=$(comm -13 <(echo "$expected_manual") <(echo "$manual_stacks"))
      if [ -n "$missing" ]; then
        joined=$(echo "$missing" | tr '\n' ',' | sed 's/,$//')
        fail "setup.sh manual prompt missing supported stacks: $joined (must match setup-repos.sh validation arm minus unsupported)"
      fi
      if [ -n "$extra" ]; then
        joined=$(echo "$extra" | tr '\n' ',' | sed 's/,$//')
        fail "setup.sh manual prompt accepts stacks not in setup-repos.sh validation: $joined"
      fi
      if [ -z "$missing" ] && [ -z "$extra" ]; then
        joined=$(echo "$manual_stacks" | tr '\n' ',' | sed 's/,$//')
        pass "setup.sh manual prompt agrees with setup-repos.sh (excluding unsupported): $joined"
      fi
    fi
  fi
fi

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if [ "$ERRORS" -eq 0 ]; then
  echo -e "${GREEN}✅ All language-support invariants pass${NC}"
  exit 0
else
  echo -e "${RED}❌ $ERRORS check(s) failed${NC}"
  exit 1
fi
