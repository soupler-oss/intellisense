#!/usr/bin/env bash
# scripts/install-intellisense-commit-stamping.sh
#
# Install the intellisense commit-stamping hook into a target repo so that FUTURE
# commits carry an honest `Intellisense-Metadata` trailer. This is forward-only:
#   - it does NOT rewrite, amend, or stamp any existing commits
#   - it installs the REAL hooks/prepare-commit-msg, which stamps the TRUE
#     author_type (no_session_signal for non-intellisense commits, claude_with_intellisense
#     only when an actual intellisense session made the commit)
#
# Idempotent: re-running refreshes the intellisense block, preserving any existing
# (e.g. Beads) prepare-commit-msg content.
#
# Usage:
#   install-intellisense-commit-stamping.sh --repo /path/to/repo [--intellisense-setup /path/to/intellisense]

set -uo pipefail

REPO=""
INTELLISENSE_SETUP="${INTELLISENSE_SETUP_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)        REPO="$2"; shift 2 ;;
    --intellisense-setup)  INTELLISENSE_SETUP="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$REPO" ]] && { echo "ERROR: --repo is required" >&2; exit 2; }
[[ -d "$REPO/.git" ]] || { echo "ERROR: $REPO is not a git repo" >&2; exit 2; }

INTELLISENSE_HOOK="$INTELLISENSE_SETUP/hooks/prepare-commit-msg"
[[ -x "$INTELLISENSE_HOOK" ]] || { echo "ERROR: intellisense hook not found/executable: $INTELLISENSE_HOOK" >&2; exit 2; }

# Resolve the active hooks dir: core.hooksPath if set, else .git/hooks.
HOOKS_DIR="$(git -C "$REPO" config --get core.hooksPath || true)"
[[ -z "$HOOKS_DIR" ]] && HOOKS_DIR="$REPO/.git/hooks"
mkdir -p "$HOOKS_DIR"
PCM="$HOOKS_DIR/prepare-commit-msg"

INTELLISENSE_BLOCK="$(cat <<EOF

# --- BEGIN intellisense INTEGRATION ---
# Managed by install-intellisense-commit-stamping.sh. Chains to the real intellisense hook,
# which stamps the TRUE author_type. Propagates its exit code (do not swallow).
INTELLISENSE_HOOK="$INTELLISENSE_HOOK"
if [ -x "\$INTELLISENSE_HOOK" ]; then
  "\$INTELLISENSE_HOOK" "\$@"
  _intellisense_rc=\$?
  [ \$_intellisense_rc -ne 0 ] && exit \$_intellisense_rc
fi
# --- END intellisense INTEGRATION ---
EOF
)"

if [[ -f "$PCM" ]]; then
  # Refresh: strip any prior intellisense block, then re-append.
  if grep -q '^# --- BEGIN intellisense INTEGRATION ---$' "$PCM"; then
    sed -i.intellisensebak '/^# --- BEGIN intellisense INTEGRATION ---$/,/^# --- END intellisense INTEGRATION ---$/d' "$PCM"
    rm -f "$PCM.intellisensebak"
  fi
  printf '%s\n' "$INTELLISENSE_BLOCK" >> "$PCM"
  echo "[UPDATED] $PCM (intellisense block refreshed; existing hook preserved)"
else
  # Fresh wrapper.
  {
    echo "#!/usr/bin/env sh"
    echo "# Managed by install-intellisense-commit-stamping.sh — fresh wrapper."
    printf '%s\n' "$INTELLISENSE_BLOCK"
  } > "$PCM"
  echo "[INSTALLED] $PCM (fresh intellisense stamping wrapper)"
fi
chmod +x "$PCM"

echo "Done. Future commits in $REPO will carry an honest Intellisense-Metadata trailer."
echo "Existing history is untouched."
