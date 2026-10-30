#!/bin/bash
# hook-packs/react/react-typecheck-changed.sh
# Run TypeScript typecheck for changed React files (pre-commit)
#
# Install with:
#   cp hook-packs/react/react-typecheck-changed.sh .claude/hooks/pre-commit-react-typecheck.sh
#   chmod +x .claude/hooks/pre-commit-react-typecheck.sh

set -euo pipefail

modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(tsx|ts|jsx|js)$' || true)

[[ -z "$modified_files" ]] && exit 0

if [[ ! -f "tsconfig.json" ]]; then
  echo "react-typecheck: no tsconfig.json found, skipping"
  exit 0
fi

echo "Running TypeScript typecheck (tsc --noEmit)..."

if [[ -x "node_modules/.bin/tsc" ]]; then
  ./node_modules/.bin/tsc --noEmit
elif command -v npx >/dev/null 2>&1; then
  npx --no-install tsc --noEmit
elif command -v tsc >/dev/null 2>&1; then
  tsc --noEmit
else
  echo "react-typecheck: tsc not available (install via 'npm install --save-dev typescript')"
  exit 1
fi
