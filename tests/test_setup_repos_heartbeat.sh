#!/usr/bin/env bash
# tests/test_setup_repos_heartbeat.sh
#
# Tests for the F3 fix: setup-repos.sh's intellisense_record_onboarded_repo_and_fire_heartbeat
# function must:
#   1. Write/update $HOME/.intellisense/onboarded-repos.tsv with path + stack
#   2. Be idempotent (re-runs don't duplicate)
#   3. Fire the heartbeat script only if a token is installed (best-effort)
#
# Strategy: source the function from setup-repos.sh and call it in isolation
# with HOME pointed at a tmpdir. Avoids the full setup-repos.sh pipeline
# (which hard-fails on empty Go fixtures due to graph bootstrap).
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
sed -n '/^intellisense_record_onboarded_repo_and_fire_heartbeat() {/,/^}/p' "$SETUP_REPOS" > "$FN_FILE"
trap 'rm -f "$FN_FILE"' EXIT

# Sanity: the function got extracted
if [[ ! -s "$FN_FILE" ]] || ! grep -q '^intellisense_record_onboarded_repo_and_fire_heartbeat()' "$FN_FILE"; then
    fail "Could not extract intellisense_record_onboarded_repo_and_fire_heartbeat from setup-repos.sh"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "=== F3-1: function writes onboarded-repos.tsv with path + stack ==="
TMP_HOME=$(mktemp -d)
REPO=$(mktemp -d)
HOME="$TMP_HOME" bash -c "source '$FN_FILE' && intellisense_record_onboarded_repo_and_fire_heartbeat '$REPO' 'go' '$REPO_ROOT'"

TSV="$TMP_HOME/.intellisense/onboarded-repos.tsv"
[[ -f "$TSV" ]] && pass "F3-1: tsv created" || fail "F3-1: tsv NOT created at $TSV"
if [[ -f "$TSV" ]]; then
    grep -qF "$REPO" "$TSV" && pass "F3-1: tsv contains repo path" || fail "F3-1: missing path"
    grep -qE "$(printf '%s\tgo' "$REPO")" "$TSV" && pass "F3-1: tab-separated path+stack" \
        || fail "F3-1: format wrong: $(cat "$TSV")"
fi
rm -rf "$TMP_HOME" "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== F3-2: re-running on same path is idempotent (no dup line) ==="
TMP_HOME=$(mktemp -d)
REPO=$(mktemp -d)
for i in 1 2 3; do
    HOME="$TMP_HOME" bash -c "source '$FN_FILE' && intellisense_record_onboarded_repo_and_fire_heartbeat '$REPO' 'go' '$REPO_ROOT'"
done
TSV="$TMP_HOME/.intellisense/onboarded-repos.tsv"
n_lines=$(awk -v p="$REPO" '$0 ~ "^" p "\t" {n++} END{print n+0}' "$TSV")
[[ "$n_lines" == "1" ]] && pass "F3-2: idempotent — exactly 1 line after 3 runs" \
    || fail "F3-2: $n_lines lines (expected 1)"
rm -rf "$TMP_HOME" "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== F3-3: onboarding multiple repos accumulates them in tsv ==="
TMP_HOME=$(mktemp -d)
REPO_A=$(mktemp -d)
REPO_B=$(mktemp -d)
HOME="$TMP_HOME" bash -c "source '$FN_FILE' && intellisense_record_onboarded_repo_and_fire_heartbeat '$REPO_A' 'go' '$REPO_ROOT'"
HOME="$TMP_HOME" bash -c "source '$FN_FILE' && intellisense_record_onboarded_repo_and_fire_heartbeat '$REPO_B' 'php' '$REPO_ROOT'"

TSV="$TMP_HOME/.intellisense/onboarded-repos.tsv"
grep -qF "$REPO_A" "$TSV" && pass "F3-3: repo A in tsv" || fail "F3-3: repo A missing"
grep -qF "$REPO_B" "$TSV" && pass "F3-3: repo B in tsv" || fail "F3-3: repo B missing"
total=$(wc -l < "$TSV" | tr -d ' ')
[[ "$total" == "2" ]] && pass "F3-3: tsv has exactly 2 lines (1 per repo)" \
    || fail "F3-3: tsv has $total lines (expected 2)"
rm -rf "$TMP_HOME" "$REPO_A" "$REPO_B"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== F3-4: updating an existing repo's stack replaces the old entry ==="
TMP_HOME=$(mktemp -d)
REPO=$(mktemp -d)
HOME="$TMP_HOME" bash -c "source '$FN_FILE' && intellisense_record_onboarded_repo_and_fire_heartbeat '$REPO' 'go' '$REPO_ROOT'"
HOME="$TMP_HOME" bash -c "source '$FN_FILE' && intellisense_record_onboarded_repo_and_fire_heartbeat '$REPO' 'python' '$REPO_ROOT'"

TSV="$TMP_HOME/.intellisense/onboarded-repos.tsv"
total=$(wc -l < "$TSV" | tr -d ' ')
[[ "$total" == "1" ]] && pass "F3-4: still 1 line after stack change" \
    || fail "F3-4: $total lines (expected 1)"
grep -qE "$(printf '%s\tpython' "$REPO")" "$TSV" && pass "F3-4: new stack 'python' present" \
    || fail "F3-4: tsv content: $(cat "$TSV")"
! grep -qE "$(printf '%s\tgo' "$REPO")" "$TSV" && pass "F3-4: old stack 'go' replaced" \
    || fail "F3-4: old stack still present: $(cat "$TSV")"
rm -rf "$TMP_HOME" "$REPO"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== F3-5: missing/invalid repo path → no tsv write, no error ==="
TMP_HOME=$(mktemp -d)
out=$(
    HOME="$TMP_HOME" bash -c "source '$FN_FILE' && intellisense_record_onboarded_repo_and_fire_heartbeat '/no/such/path' 'go' '$REPO_ROOT'; echo rc=\$?"
)
TSV="$TMP_HOME/.intellisense/onboarded-repos.tsv"
[[ ! -f "$TSV" ]] && pass "F3-5: no tsv written for non-existent path" \
    || fail "F3-5: tsv created despite bad path"
echo "$out" | grep -q 'rc=0' && pass "F3-5: function returns 0 (graceful no-op)" \
    || fail "F3-5: non-zero exit: $out"
rm -rf "$TMP_HOME"

# ─────────────────────────────────────────────────────────────────────────────
echo "=== F3-6: heartbeat fired ONLY when token file exists ==="
TMP_HOME=$(mktemp -d)
REPO=$(mktemp -d)
MARKER="$TMP_HOME/heartbeat-marker"

# Build a fake INTELLISENSE_SETUP with a mock heartbeat script that touches MARKER
FAKE_SETUP=$(mktemp -d)
mkdir -p "$FAKE_SETUP/scripts"
cat > "$FAKE_SETUP/scripts/intellisense-heartbeat.sh" <<EOF
#!/usr/bin/env bash
touch "$MARKER"
EOF
chmod +x "$FAKE_SETUP/scripts/intellisense-heartbeat.sh"

# Sub-test A: no token file → heartbeat must NOT fire
HOME="$TMP_HOME" bash -c "source '$FN_FILE' && intellisense_record_onboarded_repo_and_fire_heartbeat '$REPO' 'go' '$FAKE_SETUP'"
[[ ! -f "$MARKER" ]] && pass "F3-6a: no token → heartbeat NOT fired" \
    || fail "F3-6a: heartbeat fired without a token (would 401 nightly)"

# Sub-test B: install token → heartbeat SHOULD fire on next onboarding
mkdir -p "$TMP_HOME/.intellisense"
echo "fakeToken" > "$TMP_HOME/.intellisense/heartbeat-token"
chmod 600 "$TMP_HOME/.intellisense/heartbeat-token"

HOME="$TMP_HOME" bash -c "source '$FN_FILE' && intellisense_record_onboarded_repo_and_fire_heartbeat '$REPO' 'go' '$FAKE_SETUP'"
[[ -f "$MARKER" ]] && pass "F3-6b: token present → heartbeat fired (dashboard updated immediately)" \
    || fail "F3-6b: heartbeat not fired despite token being installed"

rm -rf "$TMP_HOME" "$REPO" "$FAKE_SETUP"

# ─────────────────────────────────────────────────────────────────────────────
echo
echo "═══════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════════════"
[[ $FAIL -eq 0 ]]
