#!/bin/bash
# hook-packs/node/node-typecheck-changed.sh
# Run TypeScript typecheck for changed Node files (pre-commit)
#
# Install with:
#   cp hook-packs/node/node-typecheck-changed.sh .claude/hooks/pre-commit-node-typecheck.sh
#   chmod +x .claude/hooks/pre-commit-node-typecheck.sh

set -euo pipefail

# Get list of modified TS/JS files
modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(ts|tsx|js|jsx)$' || true)

[[ -z "$modified_files" ]] && exit 0

# Skip when no tsconfig — repo isn't TS or hasn't been configured yet
if [[ ! -f "tsconfig.json" ]]; then
  echo "node-typecheck: no tsconfig.json found, skipping"
  exit 0
fi

echo "Running TypeScript typecheck (tsc --noEmit)..."

# Use locally-installed tsc when present (no global install required)
if [[ -x "node_modules/.bin/tsc" ]]; then
  ./node_modules/.bin/tsc --noEmit
elif command -v npx >/dev/null 2>&1; then
  npx --no-install tsc --noEmit
elif command -v tsc >/dev/null 2>&1; then
  tsc --noEmit
else
  echo "node-typecheck: tsc not available (install via 'npm install --save-dev typescript')"
  exit 1
fi
