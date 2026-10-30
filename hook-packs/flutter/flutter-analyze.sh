#!/bin/bash
# hook-packs/flutter/flutter-analyze.sh
# Run dart analyze on the package (pre-commit)
#
# Install with:
#   cp hook-packs/flutter/flutter-analyze.sh .claude/hooks/pre-commit-flutter-analyze.sh
#   chmod +x .claude/hooks/pre-commit-flutter-analyze.sh

set -euo pipefail

# Skip when not a Flutter/Dart project
[[ ! -f "pubspec.yaml" ]] && exit 0

# Skip when dart binary is unavailable
if ! command -v dart >/dev/null 2>&1; then
  echo "flutter-analyze: dart not found on PATH, skipping"
  exit 0
fi

# Only run when at least one Dart file is staged — keeps unrelated commits fast
modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.dart$' || true)
[[ -z "$modified_files" ]] && exit 0

echo "Running dart analyze..."
# Per flutter-patterns.md §Resolving Analyzer Errors: '--fatal-infos' is for CI,
# advisory locally — pre-commit is the local context, so info-level lints
# (e.g. prefer_const_constructors) should not block mid-iteration commits.
dart analyze
