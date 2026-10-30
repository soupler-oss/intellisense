#!/usr/bin/env bash
# scripts/refresh-heartbeat-runtime.sh
#
# Re-copy the heartbeat runtime into ~/.intellisense/bin/ so the launchd /
# anacron / crontab job picks up updated parser logic, price tables, or
# payload code on the next nightly tick.
#
# Why this script exists:
#   The heartbeat runtime lives at ~/.intellisense/bin/ (a non-TCC-protected
#   dotfolder) — NOT as a symlink into INTELLISENSE_SETUP. macOS TCC denies launchd
#   from reading executables under ~/Desktop, ~/Documents, ~/Downloads, and
#   iCloud-synced folders; a symlink doesn't bypass TCC because launchd
#   evaluates the resolved real path. See commit b4380b7 (TCC 126 fix).
#
#   The copy means `git pull` in INTELLISENSE_SETUP is NOT enough — the runtime stays
#   stale until something re-copies. This script is that something.
#
# Triggers:
#   - `bash setup.sh --refresh-runtime`         (explicit dev refresh)
#   - .git/hooks/post-merge in INTELLISENSE_SETUP       (auto on `git pull`)
#   - manual: `bash scripts/refresh-heartbeat-runtime.sh`
#
# Exit codes:
#   0  — all files refreshed (or skipped because bin_dir absent and that's OK)
#   1  — copy or chmod failed for any file
#   2  — INTELLISENSE_SETUP layout is wrong (a required source file is missing)
#
# This script intentionally does NOT touch the launchd plist, the token file,
# or any other setup state. It only refreshes the COPIED files.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INTELLISENSE_SETUP_PATH="$(cd "$SCRIPT_DIR/.." && pwd)"
BIN_DIR="${INTELLISENSE_HEARTBEAT_BIN_DIR:-$HOME/.intellisense/bin}"
VERSION_DIR="$(dirname "$BIN_DIR")"

# Quiet mode for the git hook (don't pollute `git pull` output unless something
# actually changed). Pass --verbose to print everything.
VERBOSE=false
if [[ "${1:-}" == "--verbose" ]]; then
    VERBOSE=true
fi

log() {
    [[ "$VERBOSE" == true ]] && echo "[refresh-heartbeat-runtime] $*"
    return 0
}

err() {
    echo "[refresh-heartbeat-runtime] ERROR: $*" >&2
}

# If the bin dir doesn't exist, the developer has not run setup.sh yet — the
# heartbeat cron is not installed. Refresh is a no-op (exit 0), not an error.
if [[ ! -d "$BIN_DIR" ]]; then
    log "no heartbeat runtime installed at $BIN_DIR — skipping refresh (run setup.sh to install)"
    exit 0
fi

# Atomic copy: write to .tmp.$$ in the destination dir, then mv. Same pattern
# as setup.sh:_hb_atomic_install_file.
install_one() {
    local src="$1" dst="$2" mode="$3"
    if [[ ! -f "$src" ]]; then
        err "missing source file: $src"
        exit 2
    fi
    local tmp="$dst.tmp.$$"
    mkdir -p "$(dirname "$dst")"
    if ! cp "$src" "$tmp" 2>/dev/null; then
        err "copy failed: $src -> $tmp"
        exit 1
    fi
    chmod "$mode" "$tmp" 2>/dev/null || true
    if ! mv "$tmp" "$dst" 2>/dev/null; then
        rm -f "$tmp"
        err "atomic move failed: $tmp -> $dst"
        exit 1
    fi
}

install_one "$INTELLISENSE_SETUP_PATH/scripts/intellisense-heartbeat.sh"             "$BIN_DIR/intellisense-heartbeat.sh"             755
install_one "$INTELLISENSE_SETUP_PATH/scripts/lib/heartbeat-payload.sh"      "$BIN_DIR/lib/heartbeat-payload.sh"      755
install_one "$INTELLISENSE_SETUP_PATH/scripts/lib/heartbeat_usage_parser.py" "$BIN_DIR/lib/heartbeat_usage_parser.py" 755
install_one "$INTELLISENSE_SETUP_PATH/scripts/lib/heartbeat-prices.json"     "$BIN_DIR/lib/heartbeat-prices.json"     644
install_one "$INTELLISENSE_SETUP_PATH/scripts/lib/hash.sh"                   "$BIN_DIR/lib/hash.sh"                   755

# VERSION is best-effort; the heartbeat falls back to "unknown" if missing.
if [[ -f "$INTELLISENSE_SETUP_PATH/VERSION" ]]; then
    install_one "$INTELLISENSE_SETUP_PATH/VERSION" "$VERSION_DIR/VERSION" 644
fi

# Rewrite MANIFEST.sha256 so verify-setup.sh stays consistent.
# shellcheck source=lib/hash.sh
source "$INTELLISENSE_SETUP_PATH/scripts/lib/hash.sh"

manifest="$BIN_DIR/MANIFEST.sha256"
manifest_tmp="$manifest.tmp.$$"
{
    # heartbeat-prices.json is DELIBERATELY excluded from the integrity manifest:
    # hb_refresh_prices() swaps it at runtime from the repo so a
    # model release reaches devs without a git pull, so its hash legitimately
    # changes between setup runs. Integrity covers the executable files only —
    # a refreshed price table must NOT read as "runtime tampered" (verify-setup
    # Check 19c/19d are aligned with this exclusion). The bundled copy is still
    # installed above (cold-start fallback); only its manifest entry is dropped.
    for f in intellisense-heartbeat.sh \
             lib/heartbeat-payload.sh \
             lib/heartbeat_usage_parser.py; do
        if [[ -f "$BIN_DIR/$f" ]]; then
            h="$(hb_sha256 "$BIN_DIR/$f")" || { err "sha256 failed: $f"; rm -f "$manifest_tmp"; exit 1; }
            printf '%s  %s\n' "$h" "$f"
        fi
    done
} > "$manifest_tmp"
mv "$manifest_tmp" "$manifest"

log "refreshed heartbeat runtime in $BIN_DIR"
echo "[refresh-heartbeat-runtime] refreshed (cron will use new code on next tick)"
exit 0
