#!/bin/bash

# helpers.sh — Shared test utilities for intellisense test suite

# intellisense branch-freshness sync gate: the freshness check makes
# a bounded `git fetch` against the resolved integration ref. Unit/integration
# suites that source this file invoke the pre-push hook and PreToolUse gate
# against throwaway fixtures and MUST stay hermetic (no network). Disable the
# freshness check by default here. Tests that specifically exercise freshness
# re-enable it per-invocation with `INTELLISENSE_SKIP_SYNC_CHECK=0 bash <hook/gate>`.
export INTELLISENSE_SKIP_SYNC_CHECK=1

# Color constants
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
NC='\033[0m'

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Assert equals
assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="${3:-assertion failed}"
  ((++TESTS_RUN))

  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Expected: $expected"
    echo -e "    Actual:   $actual"
    ((++TESTS_FAILED))
  fi
}

# Assert file exists
assert_file_exists() {
  local file="$1"
  local message="${2:-file should exist: $file}"
  ((++TESTS_RUN))

  if [ -f "$file" ]; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    ((++TESTS_FAILED))
  fi
}

# Assert file missing
assert_file_missing() {
  local file="$1"
  local message="${2:-file should not exist: $file}"
  ((++TESTS_RUN))

  if [ ! -f "$file" ]; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    ((++TESTS_FAILED))
  fi
}

# Assert symlink exists and points to target
assert_symlink_points_to() {
  local link="$1"
  local expected_target="$2"
  local message="${3:-symlink $link should point to $expected_target}"
  ((++TESTS_RUN))

  if [ -L "$link" ]; then
    local actual_target
    actual_target=$(readlink "$link")
    if [ "$actual_target" = "$expected_target" ]; then
      echo -e "  ${GREEN}✓${NC} $message"
      ((++TESTS_PASSED))
    else
      echo -e "  ${RED}✗${NC} $message"
      echo -e "    Expected target: $expected_target"
      echo -e "    Actual target:   $actual_target"
      ((++TESTS_FAILED))
    fi
  else
    echo -e "  ${RED}✗${NC} $message (not a symlink)"
    ((++TESTS_FAILED))
  fi
}

# Assert symlink is broken (points to non-existent target)
assert_symlink_broken() {
  local link="$1"
  local message="${2:-symlink $link should be broken}"
  ((++TESTS_RUN))

  if [ -L "$link" ] && [ ! -e "$link" ]; then
    echo -e "  ${GREEN}✓${NC} $message"
    ((++TESTS_PASSED))
  else
    echo -e "  ${RED}✗${NC} $message"
    ((++TESTS_FAILED))
  fi
}

# Create minimal fake INTELLISENSE_SETUP directory structure
make_fake_intellisense_setup() {
  local tmpdir="$1"

  mkdir -p "$tmpdir"/{rules/baseline,rules/language-specific,rules/operational,rules/protocols,skills,agents,scripts,templates/docs,templates/ci,templates/knowledge-base,hooks,docs,infrastructure}

  # Create minimal rule files
  cat > "$tmpdir/rules/baseline/security.md" << 'EOF'
# Security Rules
Test stub file
EOF

  cat > "$tmpdir/rules/baseline/reasoning-integrity.md" << 'EOF'
# Reasoning Integrity
Test stub file
EOF

  cat > "$tmpdir/rules/language-specific/go-patterns.md" << 'EOF'
# Go Patterns
Test stub file
EOF

  cat > "$tmpdir/rules/operational/development-workflow.md" << 'EOF'
# Development Workflow
Test stub file
EOF

  cat > "$tmpdir/rules/operational/coding-style.md" << 'EOF'
# Coding Style Rules
Test stub file
EOF

  # Create minimal templates
  cat > "$tmpdir/templates/CLAUDE.md.go.template" << 'EOF'
# CLAUDE.md Template (Go)
[Test stub]
EOF

  cat > "$tmpdir/templates/ci/refresh-docs.yml" << 'EOF'
name: Refresh Docs
on: {}
jobs:
  refresh:
    runs-on: ubuntu-latest
    steps:
      - run: echo "test"
EOF

  # Create infrastructure files
  cat > "$tmpdir/infrastructure/service-map.md" << 'EOF'
# Service Map
Test stub file
EOF

  # Create rule files for language-specific and operational
  cat > "$tmpdir/rules/language-specific/test-patterns.md" << 'EOF'
# Test Patterns
Test stub file
EOF

  cat > "$tmpdir/rules/operational/test-workflow.md" << 'EOF'
# Test Workflow
Test stub file
EOF

  cat > "$tmpdir/rules/protocols/test-protocol.md" << 'EOF'
# Test Protocol
Test stub file
EOF

  # Create pre-push hook
  cat > "$tmpdir/hooks/pre-push" << 'EOF'
#!/bin/bash
echo "Test pre-push hook"
exit 0
EOF
  chmod +x "$tmpdir/hooks/pre-push"

  # Create stub generate-kb-stubs.sh so Step 2.7 in setup-repos.sh doesn't fail
  # when `claude` CLI is present in environment (set -euo pipefail + missing script = exit 127)
  cat > "$tmpdir/scripts/generate-kb-stubs.sh" << 'EOF'
#!/bin/bash
# Test stub — exits 0 to allow setup-repos.sh to proceed to Step 3 (hook install)
exit 0
EOF
  chmod +x "$tmpdir/scripts/generate-kb-stubs.sh"

  # Graph integration: copy the real bootstrap script + library so
  # setup-repos.sh's graph step can invoke them when called with --intellisense-setup
  # pointing at this fake setup. Tests deliberately use the real scripts (not
  # stubs) so they exercise real graph build behavior against graph-ready
  # fixtures (no bypass valves; tests use realistic
  # fake repos that pass the graph readiness threshold).
  local real_intellisense_root
  real_intellisense_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if [ -f "$real_intellisense_root/scripts/graph-bootstrap.sh" ]; then
    mkdir -p "$tmpdir/scripts/lib"
    cp "$real_intellisense_root/scripts/graph-bootstrap.sh" "$tmpdir/scripts/graph-bootstrap.sh"
    cp "$real_intellisense_root/scripts/lib/intellisense-graph.sh"  "$tmpdir/scripts/lib/intellisense-graph.sh"
    chmod +x "$tmpdir/scripts/graph-bootstrap.sh"
  fi

  # Create minimal knowledge-base stub so setup-repos.sh stub-copy warning is suppressed
  cat > "$tmpdir/templates/knowledge-base/00-system-context.stub.md" << 'EOF'
# System Context
Test stub file
EOF

  # Create VERSION file
  echo "1.0-test" > "$tmpdir/VERSION"

  echo "$tmpdir"
}

# Create minimal fake git repo
make_fake_repo() {
  local tmpdir="$1"
  local with_claude_md="${2:-false}"

  # Initialize a real git repo so `git rev-parse --is-inside-work-tree` succeeds
  git -C "$tmpdir" init --quiet --initial-branch=main 2>/dev/null || git -C "$tmpdir" init --quiet
  mkdir -p "$tmpdir/.git/hooks"

  if [ "$with_claude_md" = "true" ]; then
    cat > "$tmpdir/CLAUDE.md" << 'EOF'
# Test Repository
This is a test repo.
EOF
  fi

  echo "$tmpdir"
}

# ============================================================================
# Graph-integration test preconditions
# ============================================================================

# require_code_review_graph_or_fail — hard-fail the test suite if
# code-review-graph is missing or at the wrong version.
#
# The graph is required for intellisense-managed mandatory-stack repos (when chosen)
# (Go, Python). Tests that exercise setup-repos.sh against these stacks
# therefore require the binary; they MUST NOT use bypass valves
# (--skip-graph-build was intentionally not added; --graph-exception is
# reserved for genuine opt-out, not test convenience).
#
# Every intellisense developer should have code-review-graph==2.3.2 installed.
# This precondition enforces that assumption at suite startup.
#
# Idempotent. Returns nothing on success; calls exit 1 on failure.
require_code_review_graph_or_fail() {
  local required="2.3.2"

  # 0. Normalize PATH so ~/.local/bin and /opt/homebrew/bin are searchable
  # even when the inherited shell PATH omits them. Same fix applied in
  # setup.sh / setup-repos.sh / graph-bootstrap.sh — keeps the test suite's
  # binary-existence check consistent with what the scripts under test use.
  local _intellisense_paths_lib
  _intellisense_paths_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/lib/intellisense-paths.sh"
  if [ -f "$_intellisense_paths_lib" ]; then
    # shellcheck source=../scripts/lib/intellisense-paths.sh
    source "$_intellisense_paths_lib"
    _ensure_local_bin_on_path
  fi

  # 1. binary on PATH? code-review-graph is optional (--code-intel), so without it the test is SKIPPED (exit 77)
  # unless INTELLISENSE_REQUIRE_OPTIONAL_TOOLS=1 (CI installs the tools and sets it).
  if ! command -v code-review-graph >/dev/null 2>&1 && [ "${INTELLISENSE_REQUIRE_OPTIONAL_TOOLS:-0}" != "1" ]; then
    echo "SKIP: code-review-graph is optional and not installed (set INTELLISENSE_REQUIRE_OPTIONAL_TOOLS=1 to require it)" >&2
    exit 77
  fi
  if ! command -v code-review-graph >/dev/null 2>&1; then
    {
      echo ""
      echo -e "${RED}✗ Test precondition failed: code-review-graph not installed.${NC}"
      echo ""
      echo "  The graph tests need code-review-graph==${required} to exercise"
      echo "  setup-repos.sh against mandatory-supported stacks (Go, Python)."
      echo ""
      echo "  Install one of:"
      echo "    pipx install 'code-review-graph==${required}'"
      echo "    pip install --user 'code-review-graph==${required}'"
      echo "    uv tool install 'code-review-graph==${required}'"
      echo ""
      echo "  Or run:  bash setup.sh"
      echo ""
      echo "  Then re-run the test suite."
    } >&2
    exit 1
  fi

  # 2. version match?
  local actual
  actual="$(code-review-graph --version 2>&1 | head -1 \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([a-zA-Z0-9._-]*)?' \
    | head -1)"

  if [ "$actual" != "$required" ]; then
    {
      echo ""
      echo -e "${RED}✗ Test precondition failed: code-review-graph version mismatch.${NC}"
      echo ""
      echo "  Installed: ${actual:-<unparsed>}"
      echo "  Required:  ${required}"
      echo ""
      echo "  Upgrade one of:"
      echo "    pipx install --force 'code-review-graph==${required}'"
      echo "    pip install --user --upgrade 'code-review-graph==${required}'"
      echo "    uv tool install --force 'code-review-graph==${required}'"
      echo ""
      echo "  Or run:  bash setup.sh"
    } >&2
    exit 1
  fi

  # 3. announce success once per suite (only when not previously satisfied)
  if [ -z "${INTELLISENSE_TEST_GRAPH_PRECOND_OK:-}" ]; then
    echo -e "  ${GREEN}✓${NC} Test precondition: code-review-graph==${required} present"
    export INTELLISENSE_TEST_GRAPH_PRECOND_OK=1
  fi
}

# ============================================================================
# Graph-ready fixture helpers
# ============================================================================
#
# Tests that invoke setup-repos.sh against mandatory-supported stacks (Go, Python)
# need fixtures with enough source structure to exceed the 50-node
# readiness threshold. These helpers populate <dir> with small-but-real source
# files designed to produce ~70-100 nodes after `code-review-graph build`.
#
# Empirically:
#   - 4 Go packages → ~38 nodes (insufficient)
#   - 8 Go packages → ~75 nodes (passes)
#   - 8 Python modules → ~95 nodes (passes)
#
# Use these from tests that already call make_fake_repo, AFTER make_fake_repo,
# to top up the source surface to graph-ready.

# make_fake_go_repo_graph_ready <dir>
# Adds go.mod + 8 packages with structs/interfaces/methods/functions.
# Designed to produce >50 graph nodes reliably.
make_fake_go_repo_graph_ready() {
  local dir="$1"

  cat > "$dir/go.mod" <<'EOF'
module example.com/fixture

go 1.22
EOF

  local pkg
  for pkg in user account payment order session config notification audit; do
    mkdir -p "$dir/internal/$pkg"
    cat > "$dir/internal/$pkg/types.go" <<EOF
package $pkg

// Service represents a $pkg domain entity.
type Service struct {
  ID   string
  Name string
}

// Repository abstracts persistence of Service entities.
type Repository interface {
  Get(id string) (*Service, error)
  List() ([]*Service, error)
  Save(s *Service) error
  Delete(id string) error
}

// DefaultRepo is a stub Repository implementation.
type DefaultRepo struct{}

func (r *DefaultRepo) Get(id string) (*Service, error) {
  return &Service{ID: id, Name: ""}, nil
}
func (r *DefaultRepo) List() ([]*Service, error) { return nil, nil }
func (r *DefaultRepo) Save(s *Service) error     { return nil }
func (r *DefaultRepo) Delete(id string) error    { return nil }

// New returns a default Service for the $pkg domain.
func New() *DefaultRepo { return &DefaultRepo{} }

// Validate checks that the Service has a non-empty ID.
func (s *Service) Validate() error { return nil }

// IsActive reports whether the Service has been initialized.
func (s *Service) IsActive() bool { return s.ID != "" }
EOF
  done

  mkdir -p "$dir/cmd/server"
  cat > "$dir/cmd/server/main.go" <<'EOF'
package main

import (
  "example.com/fixture/internal/user"
  "example.com/fixture/internal/account"
  "example.com/fixture/internal/payment"
  "example.com/fixture/internal/order"
  "example.com/fixture/internal/session"
  "example.com/fixture/internal/config"
  "example.com/fixture/internal/notification"
  "example.com/fixture/internal/audit"
)

func main() {
  _ = user.New()
  _ = account.New()
  _ = payment.New()
  _ = order.New()
  _ = session.New()
  _ = config.New()
  _ = notification.New()
  _ = audit.New()
}

func helper1() error { return nil }
func helper2() error { return nil }
func helper3() error { return nil }
func helper4() error { return nil }
EOF
}

# make_fake_python_repo_graph_ready <dir>
# Adds pyproject.toml + 8 Python modules with classes/methods/functions.
# Designed to produce >50 graph nodes reliably.
make_fake_python_repo_graph_ready() {
  local dir="$1"

  # Use a different file name from the test's own pyproject.toml if present;
  # only create if missing.
  if [ ! -f "$dir/pyproject.toml" ]; then
    cat > "$dir/pyproject.toml" <<'EOF'
[project]
name = "fixture"
version = "0.1.0"
EOF
  fi

  local pkg
  for pkg in user account payment order session config notification audit; do
    mkdir -p "$dir/fixture_pkg/$pkg"
    : > "$dir/fixture_pkg/$pkg/__init__.py"
    cat > "$dir/fixture_pkg/$pkg/service.py" <<EOF
"""$pkg service module — fixture for intellisense graph readiness."""


class Service:
    def __init__(self, id: str = "", name: str = ""):
        self.id = id
        self.name = name

    def validate(self) -> bool:
        return bool(self.id)

    def is_active(self) -> bool:
        return self.id != ""


class Repository:
    def get(self, id: str) -> Service:
        return Service(id, "")

    def list(self) -> list:
        return []

    def save(self, s: Service) -> None:
        return None

    def delete(self, id: str) -> None:
        return None


def new_service(id: str = "") -> Service:
    return Service(id=id, name="default")


def helper1() -> None:
    return None


def helper2() -> None:
    return None
EOF
  done

  mkdir -p "$dir/fixture_pkg"
  : > "$dir/fixture_pkg/__init__.py"
  cat > "$dir/fixture_pkg/main.py" <<'EOF'
"""Top-level fixture entry point."""

from fixture_pkg.user.service import new_service as new_user
from fixture_pkg.account.service import new_service as new_account
from fixture_pkg.payment.service import new_service as new_payment


def main():
    u = new_user("u1")
    w = new_account("w1")
    p = new_payment("p1")
    return u, w, p


if __name__ == "__main__":
    main()
EOF
}

# Print test summary
print_test_summary() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "  Tests run:    $TESTS_RUN"
  echo -e "  ${GREEN}Passed${NC}:      $TESTS_PASSED"
  if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "  ${RED}Failed${NC}:      $TESTS_FAILED"
  fi
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if [ "$TESTS_FAILED" -gt 0 ]; then
    return 1
  fi
  return 0
}
