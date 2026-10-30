#!/bin/bash
# hook-packs/angular/angular-smoke.sh
# Run Angular linting and quick build (pre-commit)
#
# Install with:
#   cp hook-packs/angular/angular-smoke.sh .claude/hooks/pre-commit-angular-smoke.sh
#   chmod +x .claude/hooks/pre-commit-angular-smoke.sh

set -euo pipefail

# Check if Angular project exists
[[ ! -f "angular.json" ]] && exit 0

modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(ts|html)$' || true)

[[ -z "$modified_files" ]] && exit 0

echo "Running Angular lint..."
ng lint --fix || true

echo "Checking build..."
ng build --configuration development --aot 2>&1 | head -20 || true
