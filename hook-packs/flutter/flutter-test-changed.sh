#!/bin/bash
# hook-packs/flutter/flutter-test-changed.sh
# Run flutter tests for changed Dart files (pre-commit)
#
# Install with:
#   cp hook-packs/flutter/flutter-test-changed.sh .claude/hooks/pre-commit-flutter-test.sh
#   chmod +x .claude/hooks/pre-commit-flutter-test.sh
#
# Resolution strategy:
#   1. Maps each staged lib/foo/bar.dart → test/foo/bar_test.dart when present.
#   2. Includes any directly staged *_test.dart files.
#   3. Falls back to the full `flutter test` when the staged set looks unsafe
#      to scope (touches lib/main.dart, lib/app.dart, or files with no test mate).

set -euo pipefail

# Skip when not a Flutter/Dart project
[[ ! -f "pubspec.yaml" ]] && exit 0

# Skip when no test directory exists
[[ ! -d "test" ]] && exit 0

# Skip when flutter binary is unavailable
if ! command -v flutter >/dev/null 2>&1; then
  echo "flutter-test: flutter not found on PATH, skipping"
  exit 0
fi

modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.dart$' \
  | grep -vE '\.(g|freezed|gr|config|chopper|mocks)\.dart$' || true)

[[ -z "$modified_files" ]] && exit 0

# Build the set of test files to run
test_files=""
fallback_to_full=false

while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    test/*_test.dart)
      test_files="$test_files $f"
      ;;
    lib/main.dart|lib/app.dart)
      # Touching app entry — safer to run the full suite
      fallback_to_full=true
      break
      ;;
    lib/*)
      # Map lib/foo/bar.dart → test/foo/bar_test.dart
      mate="test/${f#lib/}"
      mate="${mate%.dart}_test.dart"
      if [[ -f "$mate" ]]; then
        test_files="$test_files $mate"
      else
        # No test mate found — be safe, run full suite
        fallback_to_full=true
        break
      fi
      ;;
    *)
      # Dart files outside lib/ and test/ (integration_test/, bin/, tool/,
      # web/, example/, root-level) — no clean mapping; fall back to full suite
      # rather than silently skipping. integration_test/ is the standard
      # cross-stack contract layer, so this matters most there.
      fallback_to_full=true
      break
      ;;
  esac
done <<< "$modified_files"

if $fallback_to_full; then
  echo "Running flutter test (full suite — staged change touches entry point or untested file)..."
  flutter test --reporter compact
else
  # De-duplicate test paths
  test_files=$(echo $test_files | tr ' ' '\n' | sort -u | tr '\n' ' ')
  [[ -z "$test_files" ]] && exit 0
  echo "Running flutter test (changed-file scope):$test_files"
  flutter test --reporter compact $test_files
fi
