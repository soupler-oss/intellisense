#!/bin/bash
# hook-packs/react/react-test-changed.sh
# Run jest/vitest for changed React files (pre-commit)
#
# Install with:
#   cp hook-packs/react/react-test-changed.sh .claude/hooks/pre-commit-react-test.sh
#   chmod +x .claude/hooks/pre-commit-react-test.sh

set -euo pipefail

modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(tsx|ts|jsx|js)$' || true)

[[ -z "$modified_files" ]] && exit 0

# Detect runner — vitest preferred when present, then jest, then npm test
if [[ -x "node_modules/.bin/vitest" ]]; then
  echo "Running vitest (changed files only, --run)..."
  ./node_modules/.bin/vitest run --bail=1 $modified_files
elif [[ -x "node_modules/.bin/jest" ]]; then
  echo "Running jest (changed files only, --bail)..."
  ./node_modules/.bin/jest --bail --findRelatedTests $modified_files
elif command -v npx >/dev/null 2>&1 && [[ -f "package.json" ]] && grep -qE '"(vitest|jest)"' package.json 2>/dev/null; then
  echo "Running test runner via npx --no-install..."
  npx --no-install vitest run --bail=1 $modified_files 2>/dev/null \
    || npx --no-install jest --bail --findRelatedTests $modified_files
elif [[ -f "package.json" ]] && grep -q '"test"' package.json 2>/dev/null; then
  echo "Running npm test..."
  npm test --silent
else
  echo "react-test: no test runner detected, skipping"
  exit 0
fi
