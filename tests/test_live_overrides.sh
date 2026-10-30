#!/usr/bin/env bash
# test_live_overrides.sh — Live mode's per-repository layering and template record.
#
#   1. _rule_pointers (setup-repos.sh) builds the managed CLAUDE.md block from layers: the repository's own
#      copy of its language rule wins over the platform's, a rule disabled in .intellisense.yml is left out,
#      an operational rule the repository changed is pointed at, organization rules are listed.
#   2. _record_template records what setup-repos.sh installed, and `intellisense live templates update`
#      then refreshes the unedited copy and keeps the edited one.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="${INTELLISENSE_BIN:-$(command -v intellisense)}"
PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

FN="$(mktemp)"
sed -n '/^_rule_pointers()/,/^}/p; /^_record_template()/,/^}/p' "$ROOT/setup-repos.sh" > "$FN"
# shellcheck disable=SC1090
. "$FN"; rm -f "$FN"
INTELLISENSE_SETUP_DIR="$ROOT"
INTELLISENSE_BIN="$ENGINE"

REPO_PATH="$(mktemp -d)"
git -C "$REPO_PATH" init -q
mkdir -p "$REPO_PATH/.intellisense/rules/language-specific" "$REPO_PATH/.intellisense/rules/operational" "$REPO_PATH/.intellisense/rules/organization"
echo "# Go, our way" > "$REPO_PATH/.intellisense/rules/language-specific/go-patterns.md"
cp "$ROOT/rules/operational/coding-style.md" "$REPO_PATH/.intellisense/rules/operational/coding-style.md"   # unchanged
echo "# Testing, our way" > "$REPO_PATH/.intellisense/rules/operational/testing.md"                          # override
echo "# Proof" > "$REPO_PATH/.intellisense/rules/operational/proof-standards.md"                            # disabled below
echo "# Payments" > "$REPO_PATH/.intellisense/rules/organization/payments.md"
echo "# readme" > "$REPO_PATH/.intellisense/rules/organization/README.md"
printf 'version: 1\nrules:\n  disable: [operational/proof-standards]\n' > "$REPO_PATH/.intellisense.yml"

echo "1. layered rule pointers"
out="$(_rule_pointers go-patterns.md)"
[[ "$out" == *"@.intellisense/rules/language-specific/go-patterns.md"* ]] && ok "repository copy of the language rule wins" || bad "language rule not taken from the repository: $out"
[[ "$out" == *"@.intellisense/rules/operational/testing.md"* ]] && ok "changed operational rule is pointed at" || bad "override missing: $out"
[[ "$out" != *"coding-style.md"* ]] && ok "unchanged operational copy is not repeated" || bad "unchanged rule listed: $out"
[[ "$out" != *"proof-standards"* ]] && ok "disabled rule is left out" || bad "disabled rule listed: $out"
[[ "$out" == *"@.intellisense/rules/organization/payments.md"* && "$out" != *"README"* ]] && ok "organization rules listed (README skipped)" || bad "organization rules wrong: $out"
rm -f "$REPO_PATH/.intellisense/rules/language-specific/go-patterns.md"
out="$(_rule_pointers go-patterns.md)"
[[ "$out" == *"@~/.intellisense/rules/language-specific/go-patterns.md"* ]] && ok "without a repository copy the platform rule is used" || bad "platform fallback missing: $out"

echo "2. template record + update"
mkdir -p "$REPO_PATH/.github/workflows"
cp "$ROOT/templates/ci/refresh-docs.yml" "$REPO_PATH/.github/workflows/refresh-docs.yml"
_record_template "$ROOT/templates/ci/refresh-docs.yml" "$REPO_PATH/.github/workflows/refresh-docs.yml"
src="$(jq -r '.".github/workflows/refresh-docs.yml".source' "$REPO_PATH/.intellisense/templates.json" 2>/dev/null)"
[ "$src" = "templates/ci/refresh-docs.yml" ] && ok "install recorded with its source" || bad "record missing (source=$src)"
# Simulate an older install: the record says what was installed, the platform has moved on.
echo "# old" > "$REPO_PATH/.github/workflows/refresh-docs.yml"
jq --arg h "$(shasum -a 256 "$REPO_PATH/.github/workflows/refresh-docs.yml" | awk '{print $1}')" \
   '.".github/workflows/refresh-docs.yml".sha256 = $h' "$REPO_PATH/.intellisense/templates.json" > "$REPO_PATH/t.json" \
   && mv "$REPO_PATH/t.json" "$REPO_PATH/.intellisense/templates.json"
INTELLISENSE_SETUP_PATH="$ROOT" "$ENGINE" live templates update --dir "$REPO_PATH" >/dev/null 2>&1
cmp -s "$ROOT/templates/ci/refresh-docs.yml" "$REPO_PATH/.github/workflows/refresh-docs.yml" \
  && ok "unedited template refreshed by live templates update" || bad "template not refreshed"

rm -rf "$REPO_PATH"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
