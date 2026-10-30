#!/usr/bin/env bash
# intellisense-ship.sh — deterministic branch → preflight → tests → commit → push → PR.
#
# Automates the MECHANICS of shipping; it never bypasses a gate:
#   • never pushes to upstream (origin/fork only)
#   • never force-pushes
#   • never uses --no-verify (pre-push remains the authoritative gate)
#   • never auto-approves a contract (the human "proceed" stays a real decision)
#   • never pushes red tests
#
# It mirrors the pre-push blocking rules UP FRONT (per-commit `Beads:`, the
# `Change Contract` artifact, fork remote, effective tier) so a failure prints
# the exact next action instead of sending you spelunking through hooks.
#
# Usage:
#   intellisense-ship.sh [--dry-run] [--base <branch>] [--remote origin]
#                [--skip-tests --ack-skip-tests]
#
#   --dry-run            print the full plan; mutate NOTHING
#   --base <branch>      PR base branch (default: detected default branch).
#                        Set this for STACKED PRs (e.g. --base feat/parent).
#   --remote <name>      push remote; MUST be origin (the fork). Default: origin.
#   --skip-tests         skip test selection/run (requires --ack-skip-tests)

set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo "${RED}✗${NC} $1" >&2; [ -n "${2:-}" ] && echo "    ${BOLD}Next:${NC} $2" >&2; exit "${3:-1}"; }
warn() { echo "${YELLOW}⚠${NC} $1" >&2; }
ok()   { echo "${GREEN}✓${NC} $1" >&2; }
step() { echo "${CYAN}▸${NC} $1" >&2; }

# ─── Args ─────────────────────────────────────────────────────────────────────
DRY_RUN=false; BASE=""; BASE_EXPLICIT=false; REMOTE="origin"; SKIP_TESTS=false; ACK_SKIP_TESTS=false
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --base) BASE="${2:-}"; BASE_EXPLICIT=true; shift 2 ;;
        --remote) REMOTE="${2:-}"; shift 2 ;;
        --skip-tests) SKIP_TESTS=true; shift ;;
        --ack-skip-tests) ACK_SKIP_TESTS=true; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) fail "unknown argument: $1" "see --help" 2 ;;
    esac
done

# HARD GUARDRAIL: only ever push to the fork remote. No code path reaches upstream.
[ "$REMOTE" = "origin" ] || fail "Ship only pushes to 'origin' (your fork); got --remote=$REMOTE." \
    "Drop --remote (defaults to origin). upstream is read-only."

# ─── Preamble (read-only) ─────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "Not inside a git repository." "cd into your repo and retry."
cd "$REPO_ROOT" || fail "cannot cd to repo root $REPO_ROOT"

BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
[ -n "$BRANCH" ] || fail "Detached HEAD — no branch to ship." "git switch -c <type>/<short-desc>"

# Default branch (mirror pre-push detection) + range base.
DEFAULT_BRANCH="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')"
[ -z "$DEFAULT_BRANCH" ] && for b in main master develop; do
    git show-ref --verify --quiet "refs/remotes/origin/$b" && { DEFAULT_BRANCH="$b"; break; }
done
[ -z "$DEFAULT_BRANCH" ] && DEFAULT_BRANCH="master"
[ -z "$BASE" ] && BASE="$DEFAULT_BRANCH"

# Range base. When --base is explicit (stacked PRs) it DRIVES the diff range, so
# tier / changed-files / trailers / tests reflect only THIS branch's commits, not
# the parent's. Otherwise prefer upstream/<default>, then origin.
if [ "$BASE_EXPLICIT" = true ]; then
    RANGE_BASE=""
    for r in "upstream/$BASE" "origin/$BASE" "$BASE"; do
        git rev-parse --verify "$r" >/dev/null 2>&1 && { RANGE_BASE="$r"; break; }
    done
    [ -n "$RANGE_BASE" ] || fail "--base '$BASE' is not a known ref." "Use an existing branch/ref for --base (e.g. feat/parent)."
else
    RANGE_BASE="origin/$DEFAULT_BRANCH"
    git rev-parse --verify "upstream/$DEFAULT_BRANCH" >/dev/null 2>&1 && RANGE_BASE="upstream/$DEFAULT_BRANCH"
    git rev-parse --verify "$RANGE_BASE" >/dev/null 2>&1 || RANGE_BASE="$BASE"
fi

CHANGED_FILES="$(git diff --name-only "$RANGE_BASE...HEAD" 2>/dev/null | sort -u)"

# Effective tier and evidence come from the engine — the same `intellisense` the pre-push hook and CI ask.
. "$SCRIPT_DIR/lib/engine.sh"
ENGINE="$(intellisense_engine)"
TIER=1
if [ -n "$ENGINE" ]; then
    TIER="$("$ENGINE" classify --base "$RANGE_BASE" --head HEAD --tier-only 2>/dev/null || echo 1)"
    case "$TIER" in [0-9]) ;; *) TIER=1 ;; esac
else
    warn "the intellisense engine is not installed; assuming Tier 1 (install: intellisense live install)."
fi

# ─── Step 1: branch ───────────────────────────────────────────────────────────
step "Step 1/5: branch"
[ "$BRANCH" = "$DEFAULT_BRANCH" ] && fail "On the integration branch '$DEFAULT_BRANCH'." "git switch -c <type>/<short-desc>"
# Ship ships EXISTING commits. Refuse a dirty tree so (a) staged-but-uncommitted
# work can't slip past tier/preflight, and (b) ship never invents a commit
# message or trailers. Untracked files are ignored (not pushed).
if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "Working tree has uncommitted changes (staged or unstaged)." \
        "Commit them WITH their task trailer and Change Contract, then re-run /ship. Ship ships existing commits; it does not create them."
fi
[ -z "$CHANGED_FILES" ] && fail "Nothing to ship vs $RANGE_BASE (no commits ahead)." "Commit your change (with trailers) first."
ok "branch '$BRANCH' → base '$BASE' (range $RANGE_BASE), effective tier=$TIER"

# ─── Step 2: fork / remote ────────────────────────────────────────────────────
step "Step 2/5: fork remote"
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || echo "")"
UPSTREAM_URL="$(git remote get-url upstream 2>/dev/null || echo "")"
[ -n "$ORIGIN_URL" ] || fail "No 'origin' remote." "git remote add origin git@github.com:<you>/<repo>.git"
if [ -n "$UPSTREAM_URL" ] && [ "$ORIGIN_URL" = "$UPSTREAM_URL" ]; then
    fail "origin == upstream (misconfigured fork). Pre-push Phase 0 will block." \
        "git remote set-url origin git@github.com:<you>/<repo>.git"
fi
ok "origin is a fork distinct from upstream"

# ─── Step 3: bead / contract preflight (mirror pre-push) ──────────────────────
step "Step 3/5: evidence preflight (Tier $TIER) — the gate pre-push runs"
if [ "$TIER" -ge 1 ]; then
    # 3a/3b. Task trailer on each Tier 1+ commit (the policy's keys: Task, Refs, Beads …) and a valid change
    # contract — checked by the engine's gate, exactly as the push will be.
    [ -n "$ENGINE" ] || fail "The intellisense engine is not installed, so the push cannot be checked." "intellisense live install"
    if ! _gate_out="$("$ENGINE" gate --base "$RANGE_BASE" --head HEAD 2>&1)"; then
        printf '%s\n' "$_gate_out" | sed 's/^/    /' >&2
        fail "Tier $TIER: the evidence gate blocks this push (details above)." \
            "Add the task trailer to each commit (git commit --amend, or git rebase -i) and a Change Contract (intellisense contract new \"<title>\"); then re-run /ship."
    fi
    ok "evidence present: the intellisense gate passed"

    # 3c. The branch's contract (.intellisense/contracts/<branch>.md) — its state; never auto-approve.
    . "$SCRIPT_DIR/lib/contract-file.sh"
    CONTRACT="$(intellisense_contract_file "$REPO_ROOT" "$BRANCH")"
    if [ -f "$CONTRACT" ]; then
        _cj="$(mktemp)"
        _state=""
        intellisense_contract_json "$CONTRACT" "$_cj" && _state="$(jq -r '.state // empty' "$_cj" 2>/dev/null)"
        rm -f "$_cj"
        case "$_state" in
            approved|active|"") ok "contract ${CONTRACT#"$REPO_ROOT"/}${_state:+ (state '$_state')}" ;;
            *) fail "Contract state is '$_state', not approved." \
                   "The 'proceed' decision is yours — review and set state to approved via /contract. Ship will NOT auto-approve." ;;
        esac
    else
        warn "No .intellisense/contracts/${BRANCH//\//__}.md for this branch (a contract line in a commit is enough for the gate; /contract writes the file)."
    fi
else
    ok "Tier 0 — no task trailer or contract required"
fi

# ─── Step 4: test selection ───────────────────────────────────────────────────
step "Step 4/5: tests"
select_tests() {
    if [ -f "$REPO_ROOT/.intellisense/manifest.json" ] && command -v jq >/dev/null 2>&1; then
        local s; s="$(jq -r '.stack // empty' "$REPO_ROOT/.intellisense/manifest.json" 2>/dev/null)"
        [ -n "$s" ] && { echo "$s"; return; }
    fi
    [ -f "$REPO_ROOT/go.mod" ] && { echo go; return; }
    [ -f "$REPO_ROOT/composer.json" ] && { echo php; return; }
    { [ -f "$REPO_ROOT/pyproject.toml" ] || [ -f "$REPO_ROOT/setup.py" ]; } && { echo python; return; }
    [ -f "$REPO_ROOT/package.json" ] && { echo node; return; }
    ls "$REPO_ROOT"/tests/test_*.sh >/dev/null 2>&1 && { echo bash; return; }
    echo unknown
}
TEST_CMD=""
case "$(select_tests)" in
    go) TEST_CMD="go test ./..." ;;
    php) TEST_CMD="composer test" ;;
    python) TEST_CMD="pytest -q" ;;
    node) TEST_CMD="npm test" ;;
    bash) TEST_CMD="for t in tests/test_*.sh; do bash \"\$t\" || exit 1; done" ;;
    *) TEST_CMD="" ;;
esac

if [ "$SKIP_TESTS" = true ]; then
    [ "$ACK_SKIP_TESTS" = true ] || fail "--skip-tests requires --ack-skip-tests (skipping tests is a deliberate choice)."
    warn "tests skipped (--skip-tests --ack-skip-tests)"
elif [ -z "$TEST_CMD" ]; then
    if [ "$ACK_SKIP_TESTS" = true ]; then
        warn "could not infer test stack; skipping (--ack-skip-tests)"
    else
        fail "Could not infer the test stack (no .intellisense/manifest.json or known marker)." \
            "Run your repo's test target manually, then re-run with --skip-tests --ack-skip-tests."
    fi
else
    ok "selected tests: $TEST_CMD"
    if [ "$DRY_RUN" = false ]; then
        bash -c "$TEST_CMD" >&2 || fail "tests failed: $TEST_CMD" "Fix tests before shipping (ship does not push red)."
        ok "tests passed"
    fi
fi

# ─── Trailer preview (for dry-run + commit) ───────────────────────────────────
_bead="$(git log "$RANGE_BASE..HEAD" --format='%B' 2>/dev/null | grep -m1 -E '^Beads: ' || echo 'Beads: <MISSING — bd create ...>')"
PR_TITLE="$(git log -1 --format='%s' 2>/dev/null)"

# ─── Dry-run: print plan, mutate nothing ──────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
    cat >&2 <<EOF

${BOLD}intellisense SHIP — DRY RUN (no changes made)${NC}
  branch:        $BRANCH  →  base: $BASE  (range $RANGE_BASE)
  effective tier: $TIER   (source: scripts/lib/effective-tier.sh)
  changed files: $(printf '%s' "$CHANGED_FILES" | grep -c . || echo 0)
  tests:         ${TEST_CMD:-<none/skip>}
  target remote: origin  (NEVER upstream; NEVER --force; NEVER --no-verify)
  PR:            head=origin:$BRANCH  base=$BASE
  PR title:      $PR_TITLE
  trailers:      $_bead
EOF
    exit 0
fi

# No commit step: ship ships EXISTING commits (a dirty tree was already refused
# in Step 1). This guarantees deterministic trailers — the commits the preflight
# validated are exactly what gets pushed; ship never opens an editor or invents a
# message/trailers.

# ─── Step 5: push (origin only, no force, no --no-verify) ──────────────────────
step "Step 5/5: push + PR"
if ! git push -u origin "$BRANCH" >&2; then
    fail "Pre-push blocked the push (output above) — the authoritative gate." "Resolve the cited item and re-run /ship. (Ship never retries with --no-verify.)"
fi
ok "pushed to origin/$BRANCH"

# ─── PR ───────────────────────────────────────────────────────────────────────
command -v gh >/dev/null 2>&1 || fail "gh CLI not found; push succeeded." "Install gh (brew install gh; gh auth login) or open the PR manually."
gh auth status >/dev/null 2>&1 || fail "gh not authenticated; push succeeded." "Run: gh auth login, then open the PR (or re-run /ship)."
UPSTREAM_REPO="$(git remote get-url upstream 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s/\.git$//')"
ORIGIN_OWNER="$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#/.*##')"
PR_ARGS=(--base "$BASE" --head "${ORIGIN_OWNER}:${BRANCH}" --title "$PR_TITLE" --body "$_bead")
[ -n "$UPSTREAM_REPO" ] && PR_ARGS=(--repo "$UPSTREAM_REPO" "${PR_ARGS[@]}")
if PR_URL="$(gh pr create "${PR_ARGS[@]}" 2>&1)"; then
    ok "PR: $PR_URL"
else
    echo "$PR_URL" | grep -qiE 'already exists' && { ok "PR already exists for $BRANCH"; gh pr view "$BRANCH" --json url -q .url >&2 2>/dev/null || true; } \
        || fail "PR creation failed (output below); push to origin succeeded." "Open the PR manually.
$PR_URL"
fi
