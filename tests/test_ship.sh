#!/usr/bin/env bash
# test_ship.sh — tests for scripts/intellisense-ship.sh.
#
# No network: uses local-path git remotes (a "fork" dir as origin, an "upstream"
# dir) and PATH stubs for gh/bd. Most behavior is exercised via --dry-run so
# nothing is pushed.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHIP="$REPO_ROOT/scripts/intellisense-ship.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
FIXROOT="$(mktemp -d)"; trap 'rm -rf "$FIXROOT"' EXIT

# Build a fork repo (origin) + a bare upstream, on a feature branch with 1 commit.
make_repo() {
    local d="$FIXROOT/work.$RANDOM"; mkdir -p "$d"
    local up="$FIXROOT/upstream.$RANDOM.git"; git init -q --bare "$up"
    git -C "$d" init -q -b master
    git -C "$d" config user.email t@t; git -C "$d" config user.name t
    echo seed > "$d/seed.txt"; git -C "$d" add seed.txt; git -C "$d" commit -qm seed
    git -C "$d" remote add upstream "$up"
    git -C "$d" remote add origin "$up"           # default: same → caller may reset
    git -C "$d" push -q upstream master
    git -C "$d" switch -qc feat/x
    echo change > "$d/app.go"; git -C "$d" add app.go
    git -C "$d" commit -qm "feat: a change

Beads: test-123
Change Contract: scope=a change, files_affected=1, estimated_lines=1, confidence=0.9, risk=low"
    echo "$d"
}

# ─── T10: never-bypass static guarantees (inspect actual `git push` lines) ────
# Grep the real command lines, not prose comments (the header documents the
# guarantees, so a naive whole-file grep would false-positive).
echo "T10: ship never bypasses gates (static)"
PUSH_LINES="$(grep -nE 'git +push' "$SHIP")"
echo "$PUSH_LINES" | grep -q -- '--no-verify' && bad "--no-verify on a push line" || ok "no --no-verify on push"
echo "$PUSH_LINES" | grep -qE -- '(--force|[[:space:]]-f([[:space:]]|$))' && bad "force on a push line" || ok "no --force on push"
echo "$PUSH_LINES" | grep -q 'upstream' && bad "a push line targets upstream" || ok "no push targets upstream"
echo "$PUSH_LINES" | grep -q 'push -u origin' && ok "pushes to origin only" || bad "no explicit origin push"

# ─── T7: wrong remote refused ─────────────────────────────────────────────────
echo "T7: --remote upstream refused"
out="$(bash "$SHIP" --remote upstream --dry-run 2>&1)"; rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -qi "only pushes to 'origin'"; } && ok "refuses --remote upstream" || bad "did not refuse upstream remote"

# ─── T1/T11: dry-run on a ready repo prints plan, mutates nothing ─────────────
echo "T1/T11: dry-run prints plan and mutates nothing"
R="$(make_repo)"; git -C "$R" remote set-url origin "$FIXROOT/forkremote.git"; git init -q --bare "$FIXROOT/forkremote.git"
before="$(git -C "$R" rev-parse HEAD)"
out="$(cd "$R" && bash "$SHIP" --dry-run --skip-tests --ack-skip-tests 2>&1)"; rc=$?
after="$(git -C "$R" rev-parse HEAD)"
echo "$out" | grep -q "DRY RUN" && ok "dry-run banner shown" || bad "no dry-run banner"
echo "$out" | grep -q "Beads: test-123" && ok "trailer preview shows existing Beads" || bad "no trailer preview"
[ "$before" = "$after" ] && ok "no new commit in dry-run" || bad "dry-run created a commit"
# upstream/fork bare repos must have no feat/x ref (nothing pushed)
[ -z "$(git -C "$R" ls-remote origin feat/x 2>/dev/null)" ] && ok "nothing pushed in dry-run" || bad "dry-run pushed"

# ─── T3: missing task trailer on a Tier-1 file → block ───────────────────────
# A Tier-1 file (scripts/thing.sh: no rule matches, default_tier 1) with no trailers: the gate's message names
# the accepted task-trailer keys (Task, Refs, Beads).
echo "T3: Tier-1 change missing its task trailer → fail with actionable next step"
R2="$(make_repo)"; git -C "$R2" remote set-url origin "$FIXROOT/fork2.git"; git init -q --bare "$FIXROOT/fork2.git"
git -C "$R2" rm -q app.go
mkdir -p "$R2/scripts"; echo x > "$R2/scripts/thing.sh"; git -C "$R2" add scripts/thing.sh
git -C "$R2" commit -q --amend -m "feat: tier-1 change, no trailers"   # strip Beads/Contract
out="$(cd "$R2" && bash "$SHIP" --dry-run --skip-tests --ack-skip-tests 2>&1)"; rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -qi "task trailer"; } && ok "blocks on a missing task trailer, names the fix" || bad "did not block on a missing task trailer (rc=$rc)"

# ─── T1b: branch guard (on default branch) ────────────────────────────────────
echo "T1b: on integration branch → refuse"
R3="$(make_repo)"; git -C "$R3" switch -q master
out="$(cd "$R3" && bash "$SHIP" --dry-run 2>&1)"; rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -qi "integration branch"; } && ok "refuses on default branch" || bad "did not refuse on default branch"

# ─── T12: unknown stack refuses without ack ───────────────────────────────────
echo "T12: unknown stack refuses to skip tests without ack"
R4="$(make_repo)"; git -C "$R4" remote set-url origin "$FIXROOT/fork4.git"; git init -q --bare "$FIXROOT/fork4.git"
out="$(cd "$R4" && bash "$SHIP" --dry-run 2>&1)"; rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -qi "could not infer the test stack"; } && ok "refuses unknown stack without --ack-skip-tests" || bad "did not refuse unknown stack"

# ─── T13: dirty tree refused (ship only existing commits) ────
echo "T13: uncommitted changes → refuse (ship does not create commits)"
R6="$(make_repo)"; git -C "$R6" remote set-url origin "$FIXROOT/fork6.git"; git init -q --bare "$FIXROOT/fork6.git"
echo dirty >> "$R6/app.go"   # unstaged modification → dirty tree
out="$(cd "$R6" && bash "$SHIP" --dry-run --skip-tests --ack-skip-tests 2>&1)"; rc=$?
{ [ $rc -ne 0 ] && echo "$out" | grep -qi "uncommitted changes"; } && ok "refuses dirty tree, says commit first" || bad "did not refuse dirty tree (rc=$rc)"

# ─── T14: --base drives the diff range (stacked PRs) ──────────
echo "T14: --base feat/parent restricts the range to this branch's commits"
R5="$(make_repo)"; git -C "$R5" remote set-url origin "$FIXROOT/fork5.git"; git init -q --bare "$FIXROOT/fork5.git"
git -C "$R5" switch -q -c feat/parent master
echo p > "$R5/parent.go"; git -C "$R5" add parent.go; git -C "$R5" commit -qm "parent" -m "Task: T-1" -m "Change Contract: scope=parent, risk=low"
git -C "$R5" switch -q -c feat/child
echo c > "$R5/child.go"; git -C "$R5" add child.go; git -C "$R5" commit -qm "child" -m "Task: T-2" -m "Change Contract: scope=child, risk=low"
nobase="$(cd "$R5" && bash "$SHIP" --dry-run --skip-tests --ack-skip-tests 2>&1)"
withbase="$(cd "$R5" && bash "$SHIP" --base feat/parent --dry-run --skip-tests --ack-skip-tests 2>&1)"
echo "$nobase"   | grep -q "changed files: 2" && ok "no --base: range vs default includes parent (2 files)" || bad "no --base wrong count"
echo "$withbase" | grep -q "changed files: 1" && ok "--base feat/parent: range excludes parent (1 file)" || bad "--base did not drive range"

echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
