#!/bin/bash
# hook-packs/flutter/flutter-format-changed.sh
# Verify staged Dart files are formatted with `dart format` (pre-commit)
#
# Install with:
#   cp hook-packs/flutter/flutter-format-changed.sh .claude/hooks/pre-commit-flutter-format.sh
#   chmod +x .claude/hooks/pre-commit-flutter-format.sh

set -euo pipefail

# Skip when not a Flutter/Dart project
[[ ! -f "pubspec.yaml" ]] && exit 0

# Skip when dart binary is unavailable (developer skipped Flutter install)
if ! command -v dart >/dev/null 2>&1; then
  echo "flutter-format: dart not found on PATH, skipping"
  exit 0
fi

modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.dart$' \
  | grep -vE '\.(g|freezed|gr|config|chopper|mocks)\.dart$' || true)

[[ -z "$modified_files" ]] && exit 0

echo "Running dart format on staged Dart files..."
# --set-exit-if-changed: fail when any file would be reformatted
# --output=none: don't rewrite files; we want the developer to run format themselves
echo "$modified_files" | xargs dart format --set-exit-if-changed --output=none
