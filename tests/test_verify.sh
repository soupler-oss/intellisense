#!/bin/bash

# test_verify.sh — Tests for verify-setup.sh --repo mode
# Tests verify-setup.sh with fixture-based test cases

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test counter
PASS=0
FAIL=0

# Root directories
INTELLISENSE_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$INTELLISENSE_ROOT/verify-setup.sh"
TEMP_DIR="/tmp/intellisense-test-fixtures-$$"

# Create temp directory for fixtures
mkdir -p "$TEMP_DIR"
cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Helper: run_test
run_test() {
  local name="$1"
  local expected_exit="$2"
  local match_str="$3"
  local fixture_dir="$4"

  local output
  set +e
  output=$("$VERIFY" --repo "$fixture_dir" 2>&1)
  local actual_exit=$?
  set -e

  if [[ "$actual_exit" -eq "$expected_exit" ]] && \
     ([ -z "$match_str" ] || echo "$output" | grep -q "$match_str"); then
    echo -e "${GREEN}✓ PASS${NC}: $name"
    ((PASS++))
  else
    echo -e "${RED}✗ FAIL${NC}: $name"
    echo "  Expected exit: $expected_exit, got: $actual_exit"
    if [ -n "$match_str" ]; then
      echo "  Expected output to contain: '$match_str'"
    fi
    echo "  Output:"
    echo "$output" | sed 's/^/    /'
    ((FAIL++))
  fi
  return 0
}

# Helper: create_fixture (pre-creates .intellisense/ for the new layout).
create_fixture() {
  local name="$1"
  local fixture_dir="$TEMP_DIR/$name"
  mkdir -p "$fixture_dir/.intellisense"
  echo "$fixture_dir"
}

# Helper: install_beads_infra
# Beads policy (when the tracker is beads):
# With tracker beads, verify-setup `--repo` mode HARD-FAILS on missing .beads/config.yaml AND
# unset core.hooksPath AND pre-push lacking BEADS/intellisense integration blocks.
# Tests that expect EXIT 0 must set up this infrastructure in the fixture.
# Tests that expect non-zero exit (1 manifest, 2 missing, etc.) don't need
# it because check-repo.sh returns early before the beads check.
install_beads_infra() {
  local fixture_dir="$1"
  # git init (silent) and set core.hooksPath
  (cd "$fixture_dir" && git init -q 2>/dev/null && \
   git config user.email "test@test" && git config user.name "test" && \
   git config core.hooksPath "$fixture_dir/.beads/hooks")
  # .beads/config.yaml (the marker check-repo.sh looks for)
  mkdir -p "$fixture_dir/.beads/hooks"
  cat > "$fixture_dir/.beads/config.yaml" <<EOF
# Test fixture beads config (satisfies the Beads check)
version: 1
EOF
  # pre-push hook with BEADS + intellisense integration markers
  cat > "$fixture_dir/.beads/hooks/pre-push" <<'EOF'
#!/bin/bash
# BEGIN BEADS INTEGRATION
# BEGIN intellisense INTEGRATION
# Test fixture pre-push — markers only; no real enforcement.
exit 0
EOF
  chmod +x "$fixture_dir/.beads/hooks/pre-push"
}

echo "Running verify-setup.sh --repo tests..."
echo ""

# Test 1: Missing manifest → exit 2, "NOT INITIALIZED"
echo "Test 1: Missing manifest..."
fixture=$(create_fixture "test1_missing_manifest")
run_test "test_missing_manifest (exit 2, NOT INITIALIZED)" 2 "NOT INITIALIZED" "$fixture"

# Test 2: Unknown manifest version → exit 1, "Unsupported manifest version"
echo "Test 2: Unknown manifest version..."
fixture=$(create_fixture "test2_unknown_version")
cat > "$fixture/.intellisense/manifest.json" << 'EOF'
{
  "intellisense_manifest_version": "99",
  "stack": "go",
  "components": []
}
EOF
run_test "test_unknown_manifest_version (exit 1, unsupported)" 1 "Unsupported manifest" "$fixture"

# Test 3: Missing CLAUDE.md when in components → exit 1
echo "Test 3: Missing CLAUDE.md when in components..."
fixture=$(create_fixture "test3_missing_claude_md")
cat > "$fixture/.intellisense/manifest.json" << 'EOF'
{
  "intellisense_manifest_version": "1",
  "stack": "go",
  "components": ["claude-md"]
}
EOF
install_beads_infra "$fixture"
run_test "test_missing_claude_md_when_in_components (exit 1)" 1 "CLAUDE.md" "$fixture"

# Test 4: CLAUDE.md present when in components → exit 0
echo "Test 4: CLAUDE.md present when in components..."
fixture=$(create_fixture "test4_present_claude_md")
cat > "$fixture/.intellisense/manifest.json" << 'EOF'
{
  "intellisense_manifest_version": "1",
  "stack": "go",
  "components": ["claude-md"]
}
EOF
touch "$fixture/CLAUDE.md"
install_beads_infra "$fixture"
run_test "test_present_claude_md (exit 0)" 0 "" "$fixture"

# Test 5: Missing knowledge-base when in components → exit 1
echo "Test 5: Missing knowledge-base when in components..."
fixture=$(create_fixture "test5_missing_kb")
cat > "$fixture/.intellisense/manifest.json" << 'EOF'
{
  "intellisense_manifest_version": "1",
  "stack": "go",
  "components": ["knowledge-base"]
}
EOF
install_beads_infra "$fixture"
run_test "test_missing_knowledge_base (exit 1)" 1 "knowledge-base" "$fixture"

# Test 6: knowledge-base present when in components → exit 0
echo "Test 6: knowledge-base present when in components..."
fixture=$(create_fixture "test6_present_kb")
cat > "$fixture/.intellisense/manifest.json" << 'EOF'
{
  "intellisense_manifest_version": "1",
  "stack": "go",
  "components": ["knowledge-base"]
}
EOF
mkdir -p "$fixture/knowledge-base"
install_beads_infra "$fixture"
run_test "test_present_knowledge_base (exit 0)" 0 "" "$fixture"

# Test 7: Missing hooks when in components → warns (exit 0 but with warning output)
echo "Test 7: Missing hooks when in components..."
fixture=$(create_fixture "test7_missing_hooks")
cat > "$fixture/.intellisense/manifest.json" << 'EOF'
{
  "intellisense_manifest_version": "1",
  "stack": "go",
  "components": ["hooks"]
}
EOF
install_beads_infra "$fixture"
run_test "test_hooks_missing_when_in_components (warns)" 0 "WARN\|hooks" "$fixture"

# Test 8: Version mismatch → exit 0 (advisory), output includes "mismatch" or "WARN"
echo "Test 8: Version mismatch..."
fixture=$(create_fixture "test8_version_mismatch")
mkdir -p "$fixture/.git/hooks"
cat > "$fixture/.intellisense/manifest.json" << 'EOF'
{
  "intellisense_manifest_version": "1",
  "stack": "go",
  "components": []
}
EOF
cat > "$fixture/.intellisense/local.json" << 'EOF'
{
  "intellisense_setup_path": "/some/path",
  "installed_by": "testuser",
  "installed_date": "2026-01-01T00:00:00Z",
  "intellisense_version": "0.9.0"
}
EOF
install_beads_infra "$fixture"
run_test "test_version_mismatch (exit 0, advisory)" 0 "WARN\|version\|mismatch" "$fixture"

# Test 9: Stack go, missing go.mod → warns (exit 0)
echo "Test 9: Stack go, missing go.mod..."
fixture=$(create_fixture "test9_missing_go_mod")
cat > "$fixture/.intellisense/manifest.json" << 'EOF'
{
  "intellisense_manifest_version": "1",
  "stack": "go",
  "components": []
}
EOF
install_beads_infra "$fixture"
run_test "test_stack_go_missing_go_mod (warns)" 0 "WARN\|go.mod" "$fixture"

# Test 10: Full valid Go repo → exit 0
echo "Test 10: Full valid Go repo..."
fixture=$(create_fixture "test10_full_valid_go")
mkdir -p "$fixture/knowledge-base"
touch "$fixture/CLAUDE.md"
touch "$fixture/go.mod"
cat > "$fixture/.intellisense/manifest.json" << 'EOF'
{
  "intellisense_manifest_version": "1",
  "stack": "go",
  "components": ["claude-md", "knowledge-base"]
}
EOF
install_beads_infra "$fixture"
run_test "test_full_valid_go_repo (exit 0)" 0 "" "$fixture"

# Summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test Results: ${GREEN}$PASS PASS${NC}, ${RED}$FAIL FAIL${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ $FAIL -eq 0 ]; then
  echo -e "${GREEN}✓ All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}✗ $FAIL test(s) failed${NC}"
  exit 1
fi
