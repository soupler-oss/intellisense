#!/bin/bash
# hook-packs/node/node-test-changed.sh
# Run jest for changed Node files (pre-commit)
#
# Install with:
#   cp hook-packs/node/node-test-changed.sh .claude/hooks/pre-commit-node-test.sh
#   chmod +x .claude/hooks/pre-commit-node-test.sh

set -euo pipefail

# Get list of modified TS/JS files (skip if none)
modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(ts|tsx|js|jsx)$' || true)

[[ -z "$modified_files" ]] && exit 0

# Detect test runner — prefer jest, fall back to npm test
if [[ -x "node_modules/.bin/jest" ]]; then
  echo "Running jest (changed files only, --bail)..."
  ./node_modules/.bin/jest --bail --findRelatedTests $modified_files
elif command -v npx >/dev/null 2>&1 && [[ -f "package.json" ]] && grep -q '"jest"' package.json 2>/dev/null; then
  echo "Running jest via npx --no-install..."
  npx --no-install jest --bail --findRelatedTests $modified_files
elif [[ -f "package.json" ]] && grep -q '"test"' package.json 2>/dev/null; then
  echo "Running npm test..."
  npm test --silent
else
  echo "node-test: no test runner detected, skipping"
  exit 0
fi
