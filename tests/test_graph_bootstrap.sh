#!/bin/bash

# test_graph_bootstrap.sh — graph integration tests (code intelligence code-review-graph).
# Covers: scripts/lib/intellisense-graph.sh helpers, scripts/graph-bootstrap.sh entry
# points, setup-repos.sh graph step (marker write, exception path, gitignore).
#
# Needs code-review-graph==2.3.2 — skipped (exit 77) when it is not installed (no bypass valves; opt-out testing
# uses --graph-exception explicitly per the same path real users take).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

INTELLISENSE_SETUP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SETUP_REPOS_SCRIPT="$INTELLISENSE_SETUP_ROOT/setup-repos.sh"
BOOTSTRAP_SCRIPT="$INTELLISENSE_SETUP_ROOT/scripts/graph-bootstrap.sh"
GRAPH_LIB="$INTELLISENSE_SETUP_ROOT/scripts/lib/intellisense-graph.sh"

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Test Suite: graph integration${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

require_code_review_graph_or_fail
echo ""

# ─────────────────────────────────────────────────────────────
# Group 1: scripts/lib/intellisense-graph.sh — pure functions
# ─────────────────────────────────────────────────────────────
test_lib_pure_functions() {
  echo -e "${CYAN}Group 1: intellisense-graph.sh pure functions${NC}"

  # shellcheck source=../scripts/lib/intellisense-graph.sh
  source "$GRAPH_LIB"

  # Version pin
  assert_eq "2.3.2" "$(intellisense_graph_required_version)" "intellisense_graph_required_version → 2.3.2"

  # Stack classification — mandatory is opt-in only; no stack ships
  # mandatory-supported by default (see intellisense-graph.sh / graph-supported-stacks.md)
  assert_eq "candidate-supported" "$(intellisense_graph_stack_support go)"     "go → candidate-supported (default, not opted in)"
  assert_eq "candidate-supported" "$(intellisense_graph_stack_support python)" "python → candidate-supported (default, not opted in)"
  assert_eq "mandatory-supported" "$(INTELLISENSE_GRAPH_MANDATORY_STACKS='go python' intellisense_graph_stack_support go)"     "go → mandatory-supported (opted in via INTELLISENSE_GRAPH_MANDATORY_STACKS)"
  assert_eq "mandatory-supported" "$(INTELLISENSE_GRAPH_MANDATORY_STACKS='go,python' intellisense_graph_stack_support python)" "python → mandatory-supported (comma-separated opt-in)"
  assert_eq "candidate-supported" "$(INTELLISENSE_GRAPH_MANDATORY_STACKS='go' intellisense_graph_stack_support python)"        "python NOT opted in when only go is listed"

  # Stack classification — candidate
  assert_eq "candidate-supported" "$(intellisense_graph_stack_support typescript)" "typescript → candidate-supported"
  assert_eq "candidate-supported" "$(intellisense_graph_stack_support java)"       "java → candidate-supported"
  assert_eq "candidate-supported" "$(intellisense_graph_stack_support rust)"       "rust → candidate-supported"
  assert_eq "candidate-supported" "$(intellisense_graph_stack_support node)"       "node → candidate-supported"
  assert_eq "candidate-supported" "$(intellisense_graph_stack_support react)"      "react → candidate-supported"

  # Stack classification — weak
  assert_eq "weak" "$(intellisense_graph_stack_support php)"     "php → weak"
  assert_eq "weak" "$(intellisense_graph_stack_support laravel)" "laravel → weak"
  assert_eq "weak" "$(intellisense_graph_stack_support angular)" "angular → weak"

  # Stack classification — unsupported
  assert_eq "unsupported" "$(intellisense_graph_stack_support vue)" "vue → unsupported"

  # Stack classification — case-by-case fallback
  assert_eq "case-by-case" "$(intellisense_graph_stack_support solidity)" "solidity → case-by-case"
  assert_eq "case-by-case" "$(intellisense_graph_stack_support '')"       "empty stack → case-by-case"

  # Min-nodes thresholds
  assert_eq "50" "$(intellisense_graph_min_nodes go)"     "go min-nodes → 50"
  assert_eq "50" "$(intellisense_graph_min_nodes python)" "python min-nodes → 50"
  assert_eq "50" "$(intellisense_graph_min_nodes laravel)" "laravel min-nodes → 50 (advisory only)"
  assert_eq "0"  "$(intellisense_graph_min_nodes vue)"    "vue min-nodes → 0"

  # Path helpers
  assert_eq "/tmp/r/.intellisense/graph-status.json"    "$(intellisense_graph_status_path /tmp/r)"    "status_path"
  assert_eq "/tmp/r/.intellisense/graph-exception.json" "$(intellisense_graph_exception_path /tmp/r)" "exception_path"
  assert_eq "/tmp/r/.intellisense/MANAGED"              "$(intellisense_graph_managed_path /tmp/r)"   "managed_path"
  assert_eq "/tmp/r/.code-review-graph"         "$(intellisense_graph_db_path /tmp/r)"        "db_path"
  echo ""
}

# ─────────────────────────────────────────────────────────────
# Group 2: scripts/lib/intellisense-graph.sh — managed marker detection (both forms)
# ─────────────────────────────────────────────────────────────
test_managed_marker() {
  echo -e "${CYAN}Group 2: intellisense-managed marker detection${NC}"

  # shellcheck source=../scripts/lib/intellisense-graph.sh
  source "$GRAPH_LIB"

  local TMPREPO
  TMPREPO=$(mktemp -d -t intellisense-mgmd.XXXX)

  # Empty repo: not managed
  if intellisense_is_managed "$TMPREPO"; then
    echo -e "  ${RED}✗${NC} empty repo wrongly reported as managed"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  else
    echo -e "  ${GREEN}✓${NC} empty repo not intellisense-managed"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  fi

  # .intellisense/MANAGED form
  intellisense_graph_write_managed_marker "$TMPREPO"
  if intellisense_is_managed "$TMPREPO"; then
    echo -e "  ${GREEN}✓${NC} .intellisense/MANAGED → intellisense-managed"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  else
    echo -e "  ${RED}✗${NC} .intellisense/MANAGED present but not detected"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  fi
  assert_eq "INTELLISENSE-MANAGED" "$(cat "$TMPREPO/.intellisense/MANAGED")" ".intellisense/MANAGED content"

  # Cleanup and try CLAUDE.md form
  rm -rf "$TMPREPO/.intellisense"
  cat > "$TMPREPO/CLAUDE.md" <<EOF
# Test Service

## Stack
EOF
  intellisense_graph_ensure_managed_in_claude_md "$TMPREPO"
  if intellisense_is_managed "$TMPREPO"; then
    echo -e "  ${GREEN}✓${NC} CLAUDE.md marker → intellisense-managed"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  else
    echo -e "  ${RED}✗${NC} CLAUDE.md marker present but not detected"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  fi

  # Idempotence: ensure_managed_in_claude_md doesn't duplicate marker
  intellisense_graph_ensure_managed_in_claude_md "$TMPREPO"
  local count
  count=$(grep -cF '<!-- INTELLISENSE-MANAGED -->' "$TMPREPO/CLAUDE.md")
  assert_eq "1" "$count" "CLAUDE.md marker idempotent (count=1 after re-run)"

  rm -rf "$TMPREPO"
  echo ""
}

# ─────────────────────────────────────────────────────────────
# Group 3: scripts/lib/intellisense-graph.sh — defensive .gitignore writes
# ─────────────────────────────────────────────────────────────
test_gitignore_writes() {
  echo -e "${CYAN}Group 3: defensive .gitignore writes${NC}"

  # shellcheck source=../scripts/lib/intellisense-graph.sh
  source "$GRAPH_LIB"

  local TMPREPO
  TMPREPO=$(mktemp -d -t intellisense-gi.XXXX)

  # First call: writes both entries
  intellisense_graph_ensure_gitignore "$TMPREPO"
  if grep -qE '^\.code-review-graph/$' "$TMPREPO/.gitignore"; then
    echo -e "  ${GREEN}✓${NC} .code-review-graph/ added"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  else
    echo -e "  ${RED}✗${NC} .code-review-graph/ missing"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  fi
  if grep -qE '^\.intellisense/graph-status\.json$' "$TMPREPO/.gitignore"; then
    echo -e "  ${GREEN}✓${NC} .intellisense/graph-status.json added"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  else
    echo -e "  ${RED}✗${NC} .intellisense/graph-status.json missing"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  fi

  # Committed files NOT gitignored (check for actual gitignore rules — non-comment, non-blank lines)
  # A real rule starts at column 1 with a non-# non-blank character.
  if grep -E '^\s*[^#[:space:]].*graph-exception\.json' "$TMPREPO/.gitignore" >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} .intellisense/graph-exception.json wrongly gitignored"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  else
    echo -e "  ${GREEN}✓${NC} .intellisense/graph-exception.json NOT gitignored (committed)"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  fi
  if grep -E '^\s*[^#[:space:]].*MANAGED' "$TMPREPO/.gitignore" >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} .intellisense/MANAGED wrongly gitignored"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  else
    echo -e "  ${GREEN}✓${NC} .intellisense/MANAGED NOT gitignored (committed)"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  fi

  # Idempotence: re-run produces no duplicates
  intellisense_graph_ensure_gitignore "$TMPREPO"
  local crg_count status_count
  crg_count=$(grep -cE '^\.code-review-graph/$' "$TMPREPO/.gitignore")
  status_count=$(grep -cE '^\.intellisense/graph-status\.json$' "$TMPREPO/.gitignore")
  assert_eq "1" "$crg_count"    ".code-review-graph/ exactly once after re-run"
  assert_eq "1" "$status_count" ".intellisense/graph-status.json exactly once after re-run"

  rm -rf "$TMPREPO"
  echo ""
}

# ─────────────────────────────────────────────────────────────
# Group 4: scripts/lib/intellisense-graph.sh — advisory marker composition
# ─────────────────────────────────────────────────────────────
test_advisory_marker() {
  echo -e "${CYAN}Group 4: advisory marker composition${NC}"

  # shellcheck source=../scripts/lib/intellisense-graph.sh
  source "$GRAPH_LIB"

  local TMPREPO
  TMPREPO=$(mktemp -d -t intellisense-adv.XXXX)
  mkdir -p "$TMPREPO/.intellisense"

  # No status, no exception → empty marker
  local m
  m=$(intellisense_graph_advisory_marker "$TMPREPO")
  if [ -z "$m" ]; then
    echo -e "  ${GREEN}✓${NC} no status/exception → empty marker"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  else
    echo -e "  ${RED}✗${NC} empty repo produced marker: $m"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  fi

  # Weak-stack status → laravel-specific marker
  cat > "$TMPREPO/.intellisense/graph-status.json" <<JSON
{"stack": "laravel", "stack_support": "weak", "nodes": 1234, "min_nodes_threshold": 50, "min_nodes_override": null}
JSON
  m=$(intellisense_graph_advisory_marker "$TMPREPO")
  if [[ "$m" == *"[INTELLISENSE-WEAK-STACK: laravel"* ]]; then
    echo -e "  ${GREEN}✓${NC} weak-stack laravel marker generated: $m"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  else
    echo -e "  ${RED}✗${NC} weak laravel marker missing/wrong: $m"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  fi

  # Candidate-stack status → "not yet validated" marker
  cat > "$TMPREPO/.intellisense/graph-status.json" <<JSON
{"stack": "typescript", "stack_support": "candidate-supported", "nodes": 5000, "min_nodes_threshold": 50, "min_nodes_override": null}
JSON
  m=$(intellisense_graph_advisory_marker "$TMPREPO")
  if [[ "$m" == *"candidate stack"* ]]; then
    echo -e "  ${GREEN}✓${NC} candidate-stack marker generated: $m"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  else
    echo -e "  ${RED}✗${NC} candidate marker missing/wrong: $m"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  fi

  # Mandatory-supported with no override → empty marker
  cat > "$TMPREPO/.intellisense/graph-status.json" <<JSON
{"stack": "go", "stack_support": "mandatory-supported", "nodes": 5000, "min_nodes_threshold": 50, "min_nodes_override": null}
JSON
  m=$(intellisense_graph_advisory_marker "$TMPREPO")
  if [ -z "$m" ]; then
    echo -e "  ${GREEN}✓${NC} mandatory-supported go (full coverage) → empty marker"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  else
    echo -e "  ${RED}✗${NC} go marker should be empty, got: $m"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  fi

  # min-nodes override below default → empty-graph marker
  cat > "$TMPREPO/.intellisense/graph-status.json" <<JSON
{"stack": "go", "stack_support": "mandatory-supported", "nodes": 5, "min_nodes_threshold": 50, "min_nodes_override": 5}
JSON
  m=$(intellisense_graph_advisory_marker "$TMPREPO")
  if [[ "$m" == *"empty-graph"* ]]; then
    echo -e "  ${GREEN}✓${NC} min-nodes override marker: $m"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  else
    echo -e "  ${RED}✗${NC} override marker missing: $m"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  fi

  # Exception present → exception marker takes precedence
  cat > "$TMPREPO/.intellisense/graph-exception.json" <<JSON
{"reason": "unsupported-stack", "stack": "vue", "owner": "lead@x.com", "expires": "2026-12-31"}
JSON
  m=$(intellisense_graph_advisory_marker "$TMPREPO")
  if [[ "$m" == *"exception mode"* ]] && [[ "$m" == *"vue"* ]]; then
    echo -e "  ${GREEN}✓${NC} exception marker takes precedence: $m"; ((++TESTS_PASSED)); ((++TESTS_RUN))
  else
    echo -e "  ${RED}✗${NC} exception marker wrong: $m"; ((++TESTS_FAILED)); ((++TESTS_RUN))
  fi

  rm -rf "$TMPREPO"
  echo ""
}

# ─────────────────────────────────────────────────────────────
# Group 5: scripts/graph-bootstrap.sh — argument validation
# ─────────────────────────────────────────────────────────────
test_bootstrap_args() {
  echo -e "${CYAN}Group 5: graph-bootstrap.sh argument validation${NC}"

  # Missing args → exit 2
  local rc=0
  bash "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "no args → exit 2"

  # Bad --repo → exit 2
  rc=0
  bash "$BOOTSTRAP_SCRIPT" --repo /nonexistent --stack go >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "nonexistent --repo → exit 2"

  # Bad --min-nodes (non-integer) → exit 2
  local TMPREPO
  TMPREPO=$(mktemp -d)
  mkdir -p "$TMPREPO/.intellisense"
  echo "INTELLISENSE-MANAGED" > "$TMPREPO/.intellisense/MANAGED"
  rc=0
  bash "$BOOTSTRAP_SCRIPT" --repo "$TMPREPO" --stack go --min-nodes notanumber >/dev/null 2>&1 || rc=$?
  assert_eq "2" "$rc" "non-integer --min-nodes → exit 2"
  rm -rf "$TMPREPO"
  echo ""
}

# ─────────────────────────────────────────────────────────────
# Group 6: scripts/graph-bootstrap.sh — refuses non-intellisense-managed repo
# ─────────────────────────────────────────────────────────────
test_bootstrap_requires_managed() {
  echo -e "${CYAN}Group 6: graph-bootstrap.sh refuses non-intellisense-managed repo${NC}"

  local TMPREPO
  TMPREPO=$(mktemp -d -t intellisense-unmgd.XXXX)
  # No marker; bootstrap should refuse with exit 1
  local rc=0
  bash "$BOOTSTRAP_SCRIPT" --repo "$TMPREPO" --stack go --yes >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "bootstrap on unmanaged repo → exit 1"

  rm -rf "$TMPREPO"
  echo ""
}

# ─────────────────────────────────────────────────────────────
# Group 7: scripts/graph-bootstrap.sh — refuses unsupported stack without exception
# ─────────────────────────────────────────────────────────────
test_bootstrap_refuses_unsupported() {
  echo -e "${CYAN}Group 7: graph-bootstrap.sh refuses unsupported stack without exception${NC}"

  local TMPREPO
  TMPREPO=$(mktemp -d -t intellisense-vue.XXXX)
  mkdir -p "$TMPREPO/.intellisense"
  echo "INTELLISENSE-MANAGED" > "$TMPREPO/.intellisense/MANAGED"

  # Vue is unsupported; no exception present → exit 1
  local rc=0
  bash "$BOOTSTRAP_SCRIPT" --repo "$TMPREPO" --stack vue --yes >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "unsupported stack vue without exception → exit 1"

  # With exception present → succeeds (skipped build, status with readiness=skipped)
  cat > "$TMPREPO/.intellisense/graph-exception.json" <<JSON
{"reason": "unsupported-stack", "stack": "vue", "owner": "lead@x", "expires": "2099-12-31"}
JSON
  rc=0
  bash "$BOOTSTRAP_SCRIPT" --repo "$TMPREPO" --stack vue --yes >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "unsupported stack vue with exception → exit 0 (skipped)"
  assert_file_exists "$TMPREPO/.intellisense/graph-status.json" "graph-status.json written for exception path"

  rm -rf "$TMPREPO"
  echo ""
}

# ─────────────────────────────────────────────────────────────
# Group 8: setup-repos.sh hard-fails for mandatory-supported with missing
# install — sanity check, since the precondition guarantees the binary IS
# installed at the right version, this scenario is exercised by deliberately
# spoofing the wrong version. Skipped here unless we add a mock-binary helper;
# the negative cases are covered in Groups 5-7 against the bootstrap entry
# point directly, which is what setup-repos.sh delegates to.
# ─────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────
# Group 9: PATH-not-found hard exit
# Bug fix: graph-bootstrap exits non-zero when binary cannot be located,
# even after _ensure_local_bin_on_path normalization runs (i.e. binary
# truly absent).
# ─────────────────────────────────────────────────────────────
test_bootstrap_hard_exits_when_binary_truly_absent() {
  echo -e "${CYAN}Group 9: hard exit when code-review-graph genuinely absent${NC}"

  local TMPREPO TMPHOME
  TMPREPO=$(mktemp -d)
  TMPHOME=$(mktemp -d)
  # Empty fake home — no .local/bin contents
  mkdir -p "$TMPHOME/.local/bin"
  # Set up an intellisense-managed repo so the script reaches the binary check
  mkdir -p "$TMPREPO/.intellisense"
  touch "$TMPREPO/.intellisense/MANAGED"
  ( cd "$TMPREPO" && git init -q -b master 2>/dev/null \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )

  # Run with PATH containing only directories that DO NOT contain code-review-graph.
  # The helper will prepend $TMPHOME/.local/bin (empty), /opt/homebrew/bin and
  # /usr/local/bin (real, but we strip them via empty fake dirs we shadow first).
  # Simplest: point HOME at TMPHOME (helper will then add an empty .local/bin)
  # and exclude real install dirs from PATH entirely.
  local rc=0
  HOME="$TMPHOME" PATH="/usr/bin:/bin" \
    bash "$BOOTSTRAP_SCRIPT" --repo "$TMPREPO" --stack go --yes >/dev/null 2>&1 || rc=$?

  # The script may still find code-review-graph: _ensure_local_bin_on_path adds
  # /opt/homebrew/bin, /usr/local/bin and /home/linuxbrew/.linuxbrew/bin (a root
  # pip install lands in /usr/local/bin). Skip the assertion when the binary is
  # resolvable from the same directories the helper searches.
  if HOME="$TMPHOME" PATH="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin" \
       command -v code-review-graph >/dev/null 2>&1; then
    echo -e "  ${YELLOW}⊘${NC} skipped: code-review-graph found via system path; cannot exercise absence"
  else
    assert_eq "1" "$rc" "graph-bootstrap exits 1 when binary truly absent"
  fi

  rm -rf "$TMPREPO" "$TMPHOME"
  echo ""
}

# ─────────────────────────────────────────────────────────────
# Run everything
# ─────────────────────────────────────────────────────────────
test_lib_pure_functions
test_managed_marker
test_gitignore_writes
test_advisory_marker
test_bootstrap_args
test_bootstrap_requires_managed
test_bootstrap_refuses_unsupported
test_bootstrap_hard_exits_when_binary_truly_absent

print_test_summary
exit $?
