#!/bin/bash
# hook-packs/flutter/flutter-analyze-session.sh
# Stop hook — run `dart analyze lib/` at session end so analyzer errors surface
# before the session closes.
#
# Self-gating: unlike a raw `dart analyze lib/` inline command, this no-ops on
# non-Flutter repos and on machines without the Dart toolchain, so it is safe
# to leave enabled in a shared/global settings.json across every stack.
#
# Advisory only: analyzer findings are printed but never block the session from
# stopping (avoids the Stop-hook exit-code-2 blocking semantics).
#
# Install with:
#   cp hook-packs/flutter/flutter-analyze-session.sh ~/.claude/hooks/flutter-analyze-session.sh
#   chmod +x ~/.claude/hooks/flutter-analyze-session.sh

set -euo pipefail

# Skip when not a Flutter/Dart project
[[ -f "pubspec.yaml" ]] || exit 0

# Skip when there is no lib/ to analyze
[[ -d "lib" ]] || exit 0

# Skip when the dart binary is unavailable
command -v dart >/dev/null 2>&1 || exit 0

echo "Running dart analyze lib/ (session end)..."
# Advisory: surface findings without blocking the session stop
dart analyze lib/ || true
