#!/bin/bash

# intellisense Fork Check Script
# Verifies that origin points to a personal fork, not the upstream org repo
# (INTELLISENSE_UPSTREAM_ORGS, space-separated; default: soupler-oss)
# Usage: ./scripts/check-fork.sh
# Exit codes: 0 = fork OK, 1 = no fork (needs creation)

set -e

# Get repo info from git
ORIGIN_URL=$(git remote get-url origin 2>/dev/null || echo "")
REPO_NAME=$(basename "$ORIGIN_URL" .git 2>/dev/null || echo "")
ORIGIN_OWNER=$(echo "$ORIGIN_URL" | sed 's/.*[:\/]\([^\/]*\)\/.*$/\1/')

if [ -z "$ORIGIN_URL" ]; then
    echo "✗ ERROR: No origin remote configured"
    echo "   Set up origin first: git remote add origin git@github.com:<username>/<repo>.git"
    exit 1
fi

if [ -z "$REPO_NAME" ]; then
    echo "✗ ERROR: Could not parse repo name from origin"
    exit 1
fi

# Check: is origin pointing to main org repo (NO FORK)?
if [[ " ${INTELLISENSE_UPSTREAM_ORGS:-soupler-oss} " == *" $ORIGIN_OWNER "* ]]; then
    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║  FORK CHECK FAILED                               ║"
    echo "╠══════════════════════════════════════════════════╣"
    echo "║  origin points to main org repo: $ORIGIN_OWNER/$REPO_NAME"
    echo "║  You need a PERSONAL fork, not the main repo.    ║"
    echo "║                                                  ║"
    echo "║  Enter your GitHub username to fix:              ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""

    read -p "  Your GitHub username: " GITHUB_USERNAME

    if [ -z "$GITHUB_USERNAME" ]; then
        echo "✗ Cancelled"
        exit 1
    fi

    # Update origin to personal fork
    NEW_ORIGIN="git@github.com:$GITHUB_USERNAME/$REPO_NAME.git"
    git remote set-url origin "$NEW_ORIGIN"

    echo ""
    echo "✓ Updated origin to: $NEW_ORIGIN"
    echo ""
fi

# Verify final state
FINAL_ORIGIN=$(git remote get-url origin)
FINAL_OWNER=$(echo "$FINAL_ORIGIN" | sed 's/.*[:\/]\([^\/]*\)\/.*$/\1/')

echo "✓ Fork check passed"
echo "  origin: $FINAL_OWNER/$REPO_NAME"
echo ""

exit 0
