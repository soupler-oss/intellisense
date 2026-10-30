#!/usr/bin/env bash
# tests/test_repo_gitignore.sh
#
# Tests for intellisense_ensure_repo_gitignore() in setup-repos.sh — the function
# that closes the team-lead-pushes-session-files leak by ensuring every
# onboarded repo's .gitignore lists all intellisense per-dev paths.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_REPOS="$REPO_ROOT/setup-repos.sh"

PASS=0; FAIL=0
fail() { FAIL=$((FAIL+1)); echo "✗ FAIL: $*" >&2; }
pass() { PASS=$((PASS+1)); echo "✓ PASS: $*"; }

# Extract the function definition to a temp file we can source per-test.
export FN_FILE
FN_FILE="$(mktemp)"
sed -n '/^intellisense_ensure_repo_gitignore() {/,/^}/p' "$SETUP_REPOS" > "$FN_FILE"
trap 'rm -f "$FN_FILE"' EXIT

# Sanity: extracted
if ! grep -q '^intellisense_ensure_repo_gitignore()' "$FN_FILE"; then
    fail "Could not extract intellisense_ensure_repo_gitignore from setup-repos.sh"
    exit 1
fi

# Stub color vars and call helper for sub-bash isolation.
run_func() {
    local repo="$1"
    bash -c "GREEN=''; YELLOW=''; NC=''; source '$FN_FILE'; intellisense_ensure_repo_gitignore '$repo'" 2>&1
}

# Helper: assert a line exists in .gitignore
assert_in_gitignore() {
    local gi="$1" pattern="$2" label="$3"
    if grep -qE "^[[:space:]]*${pattern}[[:space:]]*\$" "$gi" 2>/dev/null; then
        pass "$label"
    else
        fail "$label — not found in: $(cat "$gi" 2>/dev/null)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo "=== G1: empty repo (no .gitignore) → creates file with all 5 entries ==="
REPO=$(mktemp -d)
run_func "$REPO" >/dev/null

GI="$REPO/.gitignore"
[[ -f "$GI" ]] && pass "G1: .gitignore created" || fail "G1: file missing"
assert_in_gitignore "$GI" '\.intellisense/session/'                       "G1: .intellisense/session/ entry"
assert_in_gitignore "$GI" '\.intellisense/local\.json'                    "G1: .intellisense/local.json entry"
assert_in_gitignore "$GI" '\.intellisense/kb-status\.md'                  "G1: .intellisense/kb-status.md entry"
assert_in_gitignore "$GI" '\.intellisense/stubs-status\.json'             "G1: .intellisense/stubs-status.json entry"
assert_in_gitignore "$GI" '\.intellisense/existing-knowledge-report\.md'  "G1: existing-knowledge-report entry"
grep -q 'intellisense: per-developer state' "$GI" && pass "G1: marker comment present" \
    || fail "G1: no marker comment"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== G2: idempotent — running twice does not duplicate entries ==="
REPO=$(mktemp -d)
run_func "$REPO" >/dev/null
run_func "$REPO" >/dev/null
run_func "$REPO" >/dev/null

GI="$REPO/.gitignore"
n_session=$(grep -cE '^\s*\.intellisense/session/\s*$' "$GI")
n_session="${n_session//[!0-9]/}"
[[ "$n_session" == "1" ]] && pass "G2: .intellisense/session/ appears exactly once after 3 runs" \
    || fail "G2: .intellisense/session/ appears $n_session times"
n_marker=$(grep -c 'intellisense: per-developer state' "$GI")
n_marker="${n_marker//[!0-9]/}"
[[ "$n_marker" == "1" ]] && pass "G2: marker comment appears exactly once" \
    || fail "G2: marker appears $n_marker times"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== G3: existing .gitignore content preserved ==="
REPO=$(mktemp -d)
cat > "$REPO/.gitignore" <<'EOF'
# Pre-existing dev's choices
node_modules/
*.log
.DS_Store
.beads/
EOF
PRE_SHA=$(shasum "$REPO/.gitignore" | awk '{print $1}')
run_func "$REPO" >/dev/null

GI="$REPO/.gitignore"
grep -q 'node_modules/' "$GI" && pass "G3: existing 'node_modules/' preserved" || fail "G3: removed"
grep -q '\*\.log' "$GI" && pass "G3: existing '*.log' preserved" || fail "G3: removed"
grep -q '\.DS_Store' "$GI" && pass "G3: existing '.DS_Store' preserved" || fail "G3: removed"
grep -q '^\.beads/$' "$GI" && pass "G3: existing '.beads/' preserved" || fail "G3: removed"
# And the new entries got appended
assert_in_gitignore "$GI" '\.intellisense/session/' "G3: .intellisense/session/ added below existing content"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== G4: partial-coverage .gitignore — only missing entries added ==="
REPO=$(mktemp -d)
cat > "$REPO/.gitignore" <<'EOF'
.intellisense/session/
node_modules/
EOF
run_func "$REPO" >/dev/null

GI="$REPO/.gitignore"
# .intellisense/session/ was already present → must NOT be duplicated
n=$(grep -cE '^\s*\.intellisense/session/\s*$' "$GI")
n="${n//[!0-9]/}"
[[ "$n" == "1" ]] && pass "G4: pre-existing .intellisense/session/ NOT duplicated" \
    || fail "G4: appears $n times"
# But the other 4 entries SHOULD be added
assert_in_gitignore "$GI" '\.intellisense/local\.json'                    "G4: .intellisense/local.json added"
assert_in_gitignore "$GI" '\.intellisense/kb-status\.md'                  "G4: .intellisense/kb-status.md added"
assert_in_gitignore "$GI" '\.intellisense/stubs-status\.json'             "G4: .intellisense/stubs-status.json added"
assert_in_gitignore "$GI" '\.intellisense/existing-knowledge-report\.md'  "G4: existing-knowledge-report added"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== G5: team-shared markers are NOT added to .gitignore ==="
# .intellisense/MANAGED, .intellisense/version, .intellisense/manifest.json must travel via git —
# they're the team-lead's onboarding signal. Function must NOT gitignore them.
REPO=$(mktemp -d)
run_func "$REPO" >/dev/null

GI="$REPO/.gitignore"
! grep -qE '^\s*\.intellisense/MANAGED\s*$' "$GI" \
    && pass "G5: .intellisense/MANAGED NOT gitignored (team-shared)" \
    || fail "G5: .intellisense/MANAGED was added — would break onboarding signal"
! grep -qE '^\s*\.intellisense/version\s*$' "$GI" \
    && pass "G5: .intellisense/version NOT gitignored (team-shared)" \
    || fail "G5: .intellisense/version was added"
! grep -qE '^\s*\.intellisense/manifest\.json\s*$' "$GI" \
    && pass "G5: .intellisense/manifest.json NOT gitignored (team-shared)" \
    || fail "G5: .intellisense/manifest.json was added"
# And .intellisense/ alone (whole dir) is NOT added — that would over-ignore
! grep -qE '^\s*\.intellisense/?\s*$' "$GI" \
    && pass "G5: bare .intellisense/ NOT gitignored (would over-ignore MANAGED + version)" \
    || fail "G5: bare .intellisense/ entry present — would hide team-shared files"
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== G6: simulates the real leak — team lead workflow ==="
# Team lead runs setup-repos.sh on orders-service. Sessions accumulate.
# Without our fix, `git add .` would stage their .intellisense/session/<sid>.classification.json.
# With our fix, git status shows .intellisense/session/ entries as ignored.
REPO=$(mktemp -d)
cd "$REPO"
git init -q -b master
git config user.email t@t; git config user.name t
git commit --allow-empty -q -m init

# Run the gitignore fix
run_func "$REPO" >/dev/null

# Now simulate session files accumulating
mkdir -p "$REPO/.intellisense/session"
echo '{"session_id":"team-lead-uuid"}' > "$REPO/.intellisense/session/team-lead-uuid.classification.json"
echo '{"session_id":"team-lead-uuid","skills_used":["plan"]}' > "$REPO/.intellisense/session/team-lead-uuid.usage.json"
echo "team-lead-uuid" > "$REPO/.intellisense/session/current-session-id"

# git status should NOT mention these (they're ignored)
git_status_out=$(git -C "$REPO" status --porcelain 2>&1)
echo "$git_status_out" | grep -q '\.intellisense/session/' \
    && fail "G6: LEAK — session files visible to git status. Output: $git_status_out" \
    || pass "G6: session files correctly ignored by git (no leak)"

# git add . should NOT stage them
git -C "$REPO" add . 2>/dev/null || true
staged=$(git -C "$REPO" diff --cached --name-only 2>/dev/null)
if echo "$staged" | grep -q '\.intellisense/session/'; then
    fail "G6: LEAK — git add . staged session files. Staged: $staged"
else
    pass "G6: git add . correctly skipped session files"
fi
# But .gitignore itself SHOULD be staged
echo "$staged" | grep -q '\.gitignore' \
    && pass "G6: .gitignore IS staged (team lead's update to ignore rules)" \
    || fail "G6: .gitignore not staged — won't propagate to other devs"
cd - >/dev/null
rm -rf "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
