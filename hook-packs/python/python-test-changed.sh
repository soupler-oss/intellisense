#!/bin/bash
# hook-packs/python/python-test-changed.sh
# Run pytest for changed Python files (pre-commit)
#
# Install with:
#   cp hook-packs/python/python-test-changed.sh .claude/hooks/pre-commit-python-test.sh
#   chmod +x .claude/hooks/pre-commit-python-test.sh

set -euo pipefail

# Get list of modified Python files
modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep '\.py$' || true)

[[ -z "$modified_files" ]] && exit 0

echo "Running pytest for modified Python files..."

# Use Poetry if available (pyproject.toml present), otherwise fall back to plain pytest
if [[ -f "pyproject.toml" ]] && command -v poetry >/dev/null 2>&1; then
  poetry run pytest -x --timeout=30
else
  pytest -x --timeout=30
fi
