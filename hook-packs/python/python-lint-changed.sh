#!/bin/bash
# hook-packs/python/python-lint-changed.sh
# Lint changed Python files with ruff (pre-commit)
#
# Install with:
#   cp hook-packs/python/python-lint-changed.sh .claude/hooks/pre-commit-python-lint.sh
#   chmod +x .claude/hooks/pre-commit-python-lint.sh

set -euo pipefail

# Get list of modified Python files
modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep '\.py$' || true)

[[ -z "$modified_files" ]] && exit 0

echo "Linting modified Python files..."

# Use Poetry if available (pyproject.toml present), otherwise fall back to plain ruff
if [[ -f "pyproject.toml" ]] && command -v poetry >/dev/null 2>&1; then
  poetry run ruff check $modified_files
else
  ruff check $modified_files
fi
