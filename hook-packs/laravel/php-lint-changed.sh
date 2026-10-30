#!/bin/bash
# hook-packs/laravel/php-lint-changed.sh
# Lint changed PHP files (pre-commit)
#
# Install with:
#   cp hook-packs/laravel/php-lint-changed.sh .claude/hooks/pre-commit-php-lint.sh
#   chmod +x .claude/hooks/pre-commit-php-lint.sh

set -euo pipefail

# Get list of modified PHP files
modified_files=$(git diff --cached --name-only --diff-filter=ACMR | grep '\.php$' || true)

[[ -z "$modified_files" ]] && exit 0

echo "Linting modified PHP files..."

# Use php artisan if available, otherwise php -l
if [[ -f "artisan" ]]; then
  php artisan pint --test -- $modified_files
else
  php -l $modified_files
fi
