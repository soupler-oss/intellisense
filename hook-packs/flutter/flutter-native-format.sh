#!/bin/bash
# hook-packs/flutter/flutter-native-format.sh
# Best-effort lint of staged ios/*.swift and android/*.kt files (pre-commit).
#
# Skip semantics: this script is OPT-IN per machine. If the relevant native
# formatter (swiftformat / swift-format / ktlint) is absent from PATH it
# skips silently — Flutter teams shouldn't be forced to install native
# toolchains they don't use.
#
# Install with:
#   cp hook-packs/flutter/flutter-native-format.sh .claude/hooks/pre-commit-flutter-native-format.sh
#   chmod +x .claude/hooks/pre-commit-flutter-native-format.sh

set -euo pipefail

# Skip when not a Flutter project
[[ ! -f "pubspec.yaml" ]] && exit 0

modified=$(git diff --cached --name-only --diff-filter=ACMR || true)
[[ -z "$modified" ]] && exit 0

# ----- iOS: Swift files under ios/ -----
swift_files=$(echo "$modified" | grep -E '^ios/.*\.swift$' || true)
if [[ -n "$swift_files" ]]; then
  if command -v swiftformat >/dev/null 2>&1; then
    echo "Running swiftformat --lint on staged ios/ Swift files..."
    echo "$swift_files" | xargs swiftformat --lint
  elif command -v swift-format >/dev/null 2>&1; then
    echo "Running swift-format lint --strict on staged ios/ Swift files..."
    echo "$swift_files" | xargs swift-format lint --strict
  else
    echo "flutter-native-format: ios Swift files staged but no swiftformat / swift-format on PATH, skipping"
  fi
fi

# ----- Android: Kotlin files under android/ -----
kt_files=$(echo "$modified" | grep -E '^android/.*\.kt$' || true)
if [[ -n "$kt_files" ]]; then
  if command -v ktlint >/dev/null 2>&1; then
    echo "Running ktlint on staged android/ Kotlin files..."
    echo "$kt_files" | xargs ktlint
  else
    echo "flutter-native-format: android Kotlin files staged but no ktlint on PATH, skipping"
  fi
fi
