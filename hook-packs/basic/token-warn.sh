#!/bin/bash
# hook-packs/basic/token-warn.sh
# Warn if token budget exceeded before commit
#
# Install with:
#   cp hook-packs/basic/token-warn.sh .claude/hooks/pre-commit-token-warn.sh
#   chmod +x .claude/hooks/pre-commit-token-warn.sh

set -euo pipefail

# Only warn if scripts/check-token-budget.sh exists
[[ -f "scripts/check-token-budget.sh" ]] || exit 0

# Run token budget check (warning mode, don't fail)
./scripts/check-token-budget.sh 2>/dev/null || true
