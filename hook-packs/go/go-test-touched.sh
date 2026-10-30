#!/bin/bash
# hook-packs/go/go-test-touched.sh
# Run tests for changed Go files (pre-commit)
#
# Install with:
#   cp hook-packs/go/go-test-touched.sh .claude/hooks/pre-commit-go-test.sh
#   chmod +x .claude/hooks/pre-commit-go-test.sh

set -euo pipefail

# Get list of modified Go files
modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep '\.go$' || true)

[[ -z "$modified_files" ]] && exit 0

echo "Running go test for modified files..."
go test -race -timeout=30s ./...
