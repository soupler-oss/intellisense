#!/usr/bin/env bash
# test_fast_lane_agreement.sh — fast-lane safety + cross-layer agreement.
#
# Proves the small-task fast lane is safe and that the three enforcement layers
# (classifier / PreToolUse gate / pre-push) AGREE on tier for the same input.
#
# Sections:
#   1. safe-lane.sh unit tests — dangerous phrase, safe path, comment/doc-only
#      diff parser (the highest-risk new code; fail-closed assertions).
#   2. One engine — no hook or script keeps its own copy of the tier rules.
#   3. Cross-layer agreement — README vs setup.sh across classifier + path-tier.
#   4. Push-time fast lane (the engine) — comment-only DEFAULT file demotes; real
#      code stays Tier 1; a path a rule matched (setup.sh) never demotes.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CLASSIFIER="$REPO_ROOT/scripts/userPromptSubmit-classifier.sh"
PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

# shellcheck source=../scripts/lib/safe-lane.sh
. "$REPO_ROOT/scripts/lib/safe-lane.sh"

# ─── Section 1: safe-lane unit tests ──────────────────────────────────────────
echo "Section 1: safe-lane.sh predicates"

# dangerous phrase
for p in "comment out the auth check" "disable the rate limiter" "bypass the gate" "remove validation here" "skip check on x"; do
    intellisense_has_dangerous_phrase "$p" && ok "dangerous: '$p'" || bad "dangerous MISSED: '$p'"
done
for p in "add a comment to config" "fix a typo" "rename the variable" "" "update the readme"; do
    intellisense_has_dangerous_phrase "$p" && bad "dangerous FALSE-POS: '$p'" || ok "benign: '$p'"
done

# safe path (requires path-tier 0 AND a safe pattern)
for p in README.md docs/x.md notes.txt guide.rst CHANGELOG.md tests/test_x.sh; do
    intellisense_is_safe_path "$p" && ok "safe-path: $p" || bad "safe-path MISSED: $p"
done
for p in setup.sh scripts/foo.sh scripts/README.md app/auth/login.go hooks/pre-push migrations/001.sql; do
    intellisense_is_safe_path "$p" && bad "safe-path FALSE-POS: $p" || ok "gated-path: $p"
done

# comment/doc-only diff parser (fail-closed)
diff_is_safe() { printf '%s\n' "$2" | intellisense_is_comment_or_doc_only_diff; }
run_diff() { local name="$1" d="$2" want="$3"; if diff_is_safe "$name" "$d"; then g=SAFE; else g=gated; fi; [ "$g" = "$want" ] && ok "parser $name=$g" || bad "parser $name=$g want $want"; }
run_diff "doc-edit"        "$(printf '+++ b/docs/x.md\n@@ -1 +1 @@\n+new prose')"            SAFE
run_diff "sh-comment"      "$(printf '+++ b/lib/x.sh\n@@ -1 +1 @@\n+# note')"                  SAFE
run_diff "js-comment"      "$(printf '+++ b/a.js\n@@ -1 +1 @@\n+// note')"                      SAFE
run_diff "block-1line"     "$(printf '+++ b/a.c\n@@ -1 +1 @@\n+/* note */')"                    SAFE
run_diff "comment-out-code" "$(printf '+++ b/a.sh\n@@ -1 +2 @@\n-do_it\n+# do_it')"             gated
run_diff "string-with-//"  "$(printf '+++ b/a.js\n@@ -1 +1 @@\n+var x = "// no";')"             gated
run_diff "real-code"       "$(printf '+++ b/a.go\n@@ -1 +1 @@\n+x := f()')"                     gated
run_diff "unknown-ext"     "$(printf '+++ b/a.xyz\n@@ -1 +1 @@\n+# hi')"                        gated
run_diff "empty"           ""                                                                   gated
# HTML/XML are markup, NOT prose — only <!-- --> qualifies.
run_diff "html-comment"    "$(printf '+++ b/index.html\n@@ -1 +1 @@\n+<!-- nav -->')"            SAFE
run_diff "html-script"     "$(printf '+++ b/index.html\n@@ -1 +1 @@\n+<script>x()</script>')"    gated
run_diff "xml-config"      "$(printf '+++ b/pom.xml\n@@ -1 +1 @@\n+<version>2.0</version>')"      gated

# ─── Section 2: one engine (no Bash copy of the rules) ─────────────────────────
echo "Section 2: the Bash hooks keep no copy of the tier rules"
# The engine (internal/tier) is the only tier model. A pattern table reappearing in a hook or script is a second
# model that will drift, which is the bug this replaced.
copies="$(grep -lE '^(INTELLISENSE_)?(TIER[012]_PATTERNS|TIER0_SAFE_PATTERNS|SAFE_PATH_PATTERNS|DANGEROUS_PHRASES)=\(|\*\[Aa\]uth\*' \
    "$REPO_ROOT"/hooks/* "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/scripts/lib/*.sh 2>/dev/null)"
if [ -z "$copies" ]; then
    ok "no tier-rule tables in hooks/ or scripts/"
else
    bad "tier-rule tables found (ask the engine instead):"; printf '      %s\n' $copies
fi

# ─── Section 3: cross-layer agreement (classifier prompt-tier vs path-tier) ────
echo "Section 3: cross-layer agreement"
. "$REPO_ROOT/scripts/lib/effective-tier.sh"
classify_tier() {
    local prompt="$1" d; d=$(mktemp -d); mkdir -p "$d/.intellisense/session"
    printf '{"prompt":%s,"session_id":"s","cwd":%s}' "$(jq -Rn --arg x "$prompt" '$x')" "$(jq -Rn --arg x "$d" '$x')" \
        | bash "$CLASSIFIER" >/dev/null 2>&1
    jq -r '.tier' "$d/.intellisense/session/s.classification.json" 2>/dev/null; rm -rf "$d"
}
# (a) README typo: classifier Tier 0 AND path-tier 0 → all layers agree Tier 0.
[ "$(classify_tier 'fix a typo in the readme')" = "0" ] && ok "(a) classifier: readme typo → 0" || bad "(a) classifier readme typo"
[ "$(intellisense_path_tier README.md)" = "0" ] && ok "(a) path-tier README.md → 0" || bad "(a) path README"
# (b) setup.sh typo: classifier downgrades (prompt-only) BUT path-tier keeps it 1.
[ "$(classify_tier 'fix a typo in the setup script')" = "0" ] && ok "(b) classifier: setup typo → 0 (prompt-only)" || bad "(b) classifier setup typo"
[ "$(intellisense_path_tier setup.sh)" = "1" ] && ok "(b) path-tier setup.sh → 1 (the real guard)" || bad "(b) path setup.sh"
# (e) dangerous escalation agrees across classifier + is never path-demotable.
[ "$(classify_tier 'comment out the auth check')" = "2" ] && ok "(e) classifier: dangerous+auth → 2" || bad "(e) classifier dangerous"

# ─── Section 4: push-time fast lane, as the engine decides it ──────────────────
echo "Section 4: fast lane at push time (engine: default-tier file + comment-only diff → Tier 0)"
ENGINE="$(intellisense_engine)"
push_tier() {   # push_tier PATH DIFF — the tier the engine gives PATH with that diff (the repo's own policy)
    local f; f=$(mktemp)
    printf '%s\n' "$2" > "$f"
    "$ENGINE" classify --dir "$REPO_ROOT" --tier-only --diff-file "$f" "$1"
    rm -f "$f"
}
[ "$(push_tier src/app.go "$(printf '+++ b/src/app.go\n@@ -1 +1 @@\n+// clarify intent')")" = "0" ] \
    && ok "demote: comment-only src/app.go" || bad "demote MISSED: comment-only src/app.go"
[ "$(push_tier src/app.go "$(printf '+++ b/src/app.go\n@@ -1 +1 @@\n+x := compute()')")" = "1" ] \
    && ok "keep Tier1: real code change" || bad "demote FALSE-POS: real code"
[ "$(push_tier setup.sh "$(printf '+++ b/setup.sh\n@@ -1 +1 @@\n+# clarify')")" = "1" ] \
    && ok "keep Tier1: setup.sh comment-only (a rule matched it)" || bad "demote FALSE-POS: setup.sh"
[ "$(push_tier src/app.go "$(printf '+++ b/src/app.go\n@@ -1 +2 @@\n-validate()\n+// validate()')")" = "1" ] \
    && ok "keep Tier1: comment-out code" || bad "demote FALSE-POS: comment-out code"
[ "$(push_tier src/app.go "$(printf '+++ b/src/app.go\n@@ -1 +1 @@\n+// TODO: bypass the limiter for now')")" = "1" ] \
    && ok "keep Tier1: comment with a dangerous phrase" || bad "demote FALSE-POS: dangerous comment"

echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
