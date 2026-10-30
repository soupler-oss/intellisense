#!/bin/bash
# tests/test_pre_push_tier_classification.sh — Layer 1 regression harness for
# the Tier 2 false-positive fix.
#
# Strategy: ask the engine (`intellisense classify --format json`), which the hook
# itself asks, for synthetic CHANGED_FILES inputs. This isolates the tier rules and
# the diagnostic records from the rest of the hook (fork checks, metadata trailers,
# graph warning), which depend on git state.
#
# Coverage:
#   F1-F4  False positives — substring bleed-through must NOT trigger Tier 2
#   T1-T12 True positives — conservative keyword set must STILL trigger Tier 2
#                            (incl. OAuth)
#   M1-M4  Diagnostic message format — ALL triggers captured (not just first),
#                                       reason+pattern present per record

set -u
INTELLISENSE_SETUP="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$INTELLISENSE_SETUP/hooks/pre-push"
RESULTS="$(mktemp)"
trap 'rm -f "$RESULTS"' EXIT

case_pass() { echo "  ✓ $1"; echo "P" >> "$RESULTS"; }
case_fail() { echo "  ✗ $1: $2"; echo "F" >> "$RESULTS"; }

# The engine (`intellisense classify`) is the only tier model: the hook asks it, so this harness asks it too,
# with this repository's policy. Each Tier 2 hit becomes a `file|reason|pattern` record, like the hook prints.
. "$INTELLISENSE_SETUP/scripts/lib/engine.sh"
ENGINE="$(intellisense_engine)"
[ -n "$ENGINE" ] || { echo "intellisense engine not found (set INTELLISENSE_BIN)"; exit 1; }

classify() {
  # Newline-separated files; each line is one path (spaces kept).
  local files="$1" file json
  local args=()
  TIER=0
  TIER2_TRIGGERS=()
  while IFS= read -r file; do
    [ -n "$file" ] && args+=("$file")
  done <<< "$files"
  json="$("$ENGINE" classify --dir "$INTELLISENSE_SETUP" --format json "${args[@]}")"
  TIER="$(printf '%s' "$json" | jq -r '.path_tier')"
  while IFS= read -r rec; do
    [ -n "$rec" ] && TIER2_TRIGGERS+=("$rec")
  done < <(printf '%s' "$json" | jq -r '.files[] | select(.tier == 2) | "\(.path)|\(.reason)|\(.pattern)"')
}

assert_tier2() {
  local label="$1" files="$2"
  classify "$files"
  if [ "$TIER" -eq 2 ]; then
    case_pass "$label"
  else
    case_fail "$label" "expected Tier 2, got Tier $TIER"
  fi
}

assert_not_tier2() {
  local label="$1" files="$2"
  classify "$files"
  if [ "$TIER" -ne 2 ]; then
    case_pass "$label"
  else
    # Use ${arr[*]:-} to tolerate empty array under set -u.
    case_fail "$label" "expected NOT Tier 2, but got Tier 2 with triggers: ${TIER2_TRIGGERS[*]:-}"
  fi
}

# ─── A. False positives (must NOT trigger Tier 2) ────────────────────────────
echo "A. False positives (substring bleed-through)"
assert_not_tier2 "F1 pkg/author.go (auth substring inside 'author')" "pkg/author.go"
assert_not_tier2 "F2 src/components/AuthorBio.tsx (Auth substring inside 'Author')" "src/components/AuthorBio.tsx"
assert_not_tier2 "F3 docs/authors.md (auth substring inside 'authors')" "docs/authors.md"
assert_not_tier2 "F4 internal/audit_log.go ('aud' before 'it' — no auth/payment match)" "internal/audit_log.go"

# ─── B. True positives — auth/identity ──────────────────────────────────────
echo "B. True positives — auth/identity"
assert_tier2 "T1 internal/oauth_handler.go (OAuth)" "internal/oauth_handler.go"
assert_tier2 "T2 internal/auth/auth.go" "internal/auth/auth.go"
assert_tier2 "T3 pkg/auth_middleware.go" "pkg/auth_middleware.go"
assert_tier2 "T4 app/Auth/Guard.php" "app/Auth/Guard.php"
assert_tier2 "T5 pkg/authentication.go" "pkg/authentication.go"
assert_tier2 "T6 internal/authorization.py" "internal/authorization.py"

# ─── C. True positives — financial ──────────────────────────────────────────
echo "C. True positives — financial"
assert_tier2 "T7 pkg/payment/processor.go" "pkg/payment/processor.go"
assert_tier2 "T8 app/Billing/Invoice.php" "app/Billing/Invoice.php"
assert_tier2 "T9 services/account.go" "services/account.go"
assert_tier2 "T10 internal/journal/entries.go" "internal/journal/entries.go"

# ─── D. True positives — migrations + rules ─────────────────────────────────
echo "D. True positives — migrations + security rules"
assert_tier2 "T11 migrations/2024_add_user.sql" "migrations/2024_add_user.sql"
assert_tier2 "T12 rules/baseline/security.md (literal preserved)" "rules/baseline/security.md"

# ─── S. Filenames with spaces (loop-quoting regression) ────────
echo "S. Filenames with spaces (loop quoting)"

# S1: Tier 2 ESCAPE (false negative). 'migrations/2024 add users.sql' matches
# the migration pattern only as a full path. The old unquoted
# `for file in $CHANGED_FILES` split it into "migrations/2024" (no .sql$),
# "add", "users.sql" (no migrations/ prefix) — NO fragment matched, so a
# Tier 2 migration with a space in its name escaped Tier 2 entirely.
classify 'migrations/2024 add users.sql'
if [ "$TIER" -eq 2 ] && [ "${#TIER2_TRIGGERS[@]}" -eq 1 ] \
   && [ "${TIER2_TRIGGERS[0]%%|*}" = "migrations/2024 add users.sql" ]; then
  case_pass "S1 migration with space: Tier 2 detected, full path in record"
else
  case_fail "S1 migration with space" "tier=$TIER triggers(${#TIER2_TRIGGERS[@]:-0}): ${TIER2_TRIGGERS[*]:-none}"
fi

# S1b: record integrity. 'payment/refund report.go' triggers via the
# 'payment/' segment either way, but the old loop recorded the mangled
# fragment "payment/refund" as the triggering file instead of the full path.
classify 'payment/refund report.go'
if [ "$TIER" -eq 2 ] && [ "${#TIER2_TRIGGERS[@]}" -eq 1 ] \
   && [ "${TIER2_TRIGGERS[0]%%|*}" = "payment/refund report.go" ]; then
  case_pass "S1b space-in-filename: full path preserved in trigger record"
else
  case_fail "S1b space-in-filename" "tier=$TIER triggers(${#TIER2_TRIGGERS[@]:-0}): ${TIER2_TRIGGERS[*]:-none}"
fi

# S2: a harmless filename with spaces iterates cleanly and stays non-Tier-2.
assert_not_tier2 "S2 'docs/meeting notes.md' (space, no risk keyword)" 'docs/meeting notes.md'

# ─── E. Diagnostic message format ───────────────────────────────────────────
echo "E. Diagnostic capture (TIER2_TRIGGERS)"

# M1: multiple Tier 2 hits → ALL captured, not just first.
classify $'internal/oauth_handler.go\npkg/payment/processor.go\nREADME.md'
if [ "${#TIER2_TRIGGERS[@]}" -eq 2 ]; then
  case_pass "M1 multi-file capture: 2 Tier 2 hits, 1 non-match → 2 triggers"
else
  case_fail "M1 multi-file capture" "expected 2 triggers, got ${#TIER2_TRIGGERS[@]}: ${TIER2_TRIGGERS[*]}"
fi

# M2: each record parses to non-empty file / reason / pattern. Note the
# pattern itself contains pipes (regex alternation), so we use the same
# split-on-first-two-pipes logic the hook uses, not a naive field count.
classify "internal/auth/auth.go"
record="${TIER2_TRIGGERS[0]:-}"
m2_file="${record%%|*}"
m2_rest="${record#*|}"
m2_reason="${m2_rest%%|*}"
m2_pattern="${m2_rest#*|}"
if [ -n "$m2_file" ] && [ -n "$m2_reason" ] && [ -n "$m2_pattern" ] \
   && [ "$m2_file" != "$record" ]; then
  case_pass "M2 record shape: file ($m2_file), reason ($m2_reason), and pattern all non-empty"
else
  case_fail "M2 record shape" "missing field in: $record"
fi

# M3: reason field is non-empty and matches one of the known labels.
t_reason="$m2_reason"
case "$t_reason" in
  "auth/identity"|"financial"|"database migration"|"security rule"|"reasoning-integrity rule")
    case_pass "M3 reason label is a known category: '$t_reason'"
    ;;
  *)
    case_fail "M3 reason label" "unknown label: '$t_reason'"
    ;;
esac

# M4: diagnostic block in BLOCKED message renders all triggers (smoke test
# against the actual hook output by simulating a Tier 2 push). We verify the
# message-rendering code by reproducing it in isolation, since running the
# full hook needs git/bd state we don't have hermetically.
classify $'internal/oauth_handler.go\npkg/payment/processor.go'
rendered="$(
  if [ "${#TIER2_TRIGGERS[@]}" -gt 0 ]; then
    echo "   Triggered by:"
    for trigger in "${TIER2_TRIGGERS[@]}"; do
      t_file="${trigger%%|*}"
      t_rest="${trigger#*|}"
      t_reason="${t_rest%%|*}"
      t_pattern="${t_rest#*|}"
      echo "     • $t_file"
      echo "       reason:  $t_reason"
      echo "       pattern: $t_pattern"
    done
  fi
)"
if echo "$rendered" | grep -qF "internal/oauth_handler.go" \
   && echo "$rendered" | grep -qF "pkg/payment/processor.go" \
   && echo "$rendered" | grep -qF "auth/identity" \
   && echo "$rendered" | grep -qF "financial"; then
  case_pass "M4 BLOCKED message renders all triggers with file + reason"
else
  case_fail "M4 BLOCKED message" "missing expected content in: $rendered"
fi

# ─── Tier 1+ classification — this repository's platform paths are gated ─────
# Under this repository's policy these are at least Tier 1 (hooks/pre-push and the tier libraries are Tier 2:
# "the gate itself"). The point is that none of them is ungated.
assert_gated() {
  local label="$1" files="$2"
  classify "$files"
  if [ "$TIER" -ge 1 ]; then
    case_pass "$label"
  else
    case_fail "$label" "expected Tier 1+, got Tier $TIER (files: $files)"
  fi
}

echo ""
echo "  Tier 1+ path classification:"
assert_gated "TIER1-H1 hooks/pre-push is gated" "hooks/pre-push"
assert_gated "TIER1-H2 hooks/prepare-commit-msg is gated" "hooks/prepare-commit-msg"
assert_gated "TIER1-H3 hooks/pre-commit is gated" "hooks/pre-commit"
assert_gated "TIER1-S1 setup.sh is gated" "setup.sh"
assert_gated "TIER1-SC1 scripts/lib/effective-tier.sh is gated" "scripts/lib/effective-tier.sh"

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
