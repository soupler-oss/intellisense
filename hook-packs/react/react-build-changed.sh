#!/bin/bash
# hook-packs/react/react-build-changed.sh
# Run production build for changed React files (pre-push, optional)
#
# Install with:
#   cp hook-packs/react/react-build-changed.sh .claude/hooks/pre-push-react-build.sh
#   chmod +x .claude/hooks/pre-push-react-build.sh
#
# This is heavier than typecheck/test — pair with pre-push, not pre-commit.

set -euo pipefail

modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(tsx|ts|jsx|js|css|html|json)$' || true)

[[ -z "$modified_files" ]] && exit 0

if [[ ! -f "package.json" ]]; then
  echo "react-build: no package.json, skipping"
  exit 0
fi

# Prefer the project's declared build script
if grep -q '"build"' package.json 2>/dev/null; then
  echo "Running npm run build..."
  npm run build --silent
else
  echo "react-build: no build script in package.json, skipping"
  exit 0
fi
