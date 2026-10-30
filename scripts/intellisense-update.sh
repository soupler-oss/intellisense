#!/bin/bash
# intellisense-update.sh — Update intellisense to the latest version on this machine
# Run: bash scripts/intellisense-update.sh (from any directory)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG_FILE="$HOME/.claude/config.json"

# Read intellisense setup path from config
if [ ! -f "$CONFIG_FILE" ]; then
  echo -e "${RED}ERROR: intellisense not installed. Run setup.sh first.${NC}"
  exit 1
fi

INTELLISENSE_PATH="$(grep '"intellisense_setup_path"' "$CONFIG_FILE" | sed 's/.*: *"\(.*\)".*/\1/')"
if [ -z "$INTELLISENSE_PATH" ] || [ ! -d "$INTELLISENSE_PATH" ]; then
  echo -e "${RED}ERROR: intellisense path not found or missing: $INTELLISENSE_PATH${NC}"
  exit 1
fi

CURRENT_VERSION="$(grep '"version"' "$CONFIG_FILE" | sed 's/.*: *"\(.*\)".*/\1/')"

echo -e "${BOLD}intellisense Update${NC}"
echo -e "Current version : ${YELLOW}$CURRENT_VERSION${NC}"
echo -e "intellisense path       : $INTELLISENSE_PATH"
echo ""

# Pull latest from remote
echo -e "${BLUE}→ Pulling latest intellisense...${NC}"
git -C "$INTELLISENSE_PATH" pull origin main

# Read new version
NEW_VERSION="$(cat "$INTELLISENSE_PATH/VERSION" 2>/dev/null | tr -d '[:space:]')"
if [ -z "$NEW_VERSION" ]; then
  echo -e "${RED}ERROR: VERSION file missing after pull.${NC}"
  exit 1
fi

if [ "$NEW_VERSION" = "$CURRENT_VERSION" ]; then
  echo -e "${GREEN}Already up to date (version $CURRENT_VERSION).${NC}"
else
  echo -e "${GREEN}Updated: $CURRENT_VERSION → $NEW_VERSION${NC}"

  # Show what changed between versions (read from CHANGELOG.md)
  echo ""
  echo -e "${BLUE}→ Changes in $NEW_VERSION:${NC}"
  CHANGELOG="$INTELLISENSE_PATH/CHANGELOG.md"
  if [ -f "$CHANGELOG" ]; then
    awk "/^## \[$NEW_VERSION\]/{found=1; next} found && /^## \[/{exit} found{print}" "$CHANGELOG" | grep -v '^$' | head -20
  else
    git -C "$INTELLISENSE_PATH" log --oneline -10
  fi

  # Update version in config.json
  TMP="$(mktemp)"
  sed "s/\"version\": \"$CURRENT_VERSION\"/\"version\": \"$NEW_VERSION\"/" "$CONFIG_FILE" > "$TMP"
  mv "$TMP" "$CONFIG_FILE"
  echo ""
  echo -e "${GREEN}✓ config.json updated to $NEW_VERSION${NC}"
fi

# Symlinks resolve automatically after git pull — verify them
echo ""
echo -e "${BLUE}→ Verifying installation...${NC}"
bash "$INTELLISENSE_PATH/verify-setup.sh"

echo ""
echo -e "${BOLD}${GREEN}intellisense is up to date (version $NEW_VERSION).${NC}"
echo -e "All rules and skills are live — symlinks updated automatically."
