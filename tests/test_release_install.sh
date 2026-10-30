#!/usr/bin/env bash
# test_release_install.sh — the release path end to end, offline:
#   scripts/release/build.sh builds a real archive for this machine + checksums.txt;
#   install.sh installs it from a file:// "release", runs it, and refuses a tampered archive;
#   scripts/release/packaging.sh writes a Homebrew formula, a Scoop manifest and winget manifests that point
#   at the right archives with the right checksums.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
command -v go >/dev/null 2>&1 || { echo "SKIP: go is not installed" >&2; exit 77; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; arm64|aarch64) arch=arm64 ;; *) echo "SKIP: unsupported CPU" >&2; exit 77 ;; esac

echo "1. build"
if TARGETS="$os/$arch" bash "$ROOT/scripts/release/build.sh" 9.9.9 "$WORK/dist" >/dev/null 2>&1 \
   && [ -f "$WORK/dist/intellisense_9.9.9_${os}_${arch}.tar.gz" ] && grep -q "intellisense_9.9.9_${os}_${arch}.tar.gz" "$WORK/dist/checksums.txt"; then
    ok "archive + checksums.txt for $os/$arch"
else
    bad "build.sh did not produce the archive"
fi

echo "2. install.sh from a local release"
out="$(INTELLISENSE_VERSION=9.9.9 INTELLISENSE_DOWNLOAD_BASE="file://$WORK/dist" INTELLISENSE_INSTALL_DIR="$WORK/bin" sh "$ROOT/install.sh" 2>&1)"
if [ -x "$WORK/bin/intellisense" ] && "$WORK/bin/intellisense" version | grep -q "intellisense"; then
    ok "installed and runs"
else
    bad "install failed: $out"
fi
[[ "$out" == *"Next:"* && "$out" == *"intellisense init"* ]] && ok "says what to run next" || bad "no next steps: $out"

cp -R "$WORK/dist" "$WORK/tampered"
printf 'extra' >> "$WORK/tampered/intellisense_9.9.9_${os}_${arch}.tar.gz"
if INTELLISENSE_VERSION=9.9.9 INTELLISENSE_DOWNLOAD_BASE="file://$WORK/tampered" INTELLISENSE_INSTALL_DIR="$WORK/bin2" sh "$ROOT/install.sh" >"$WORK/t.out" 2>&1; then
    bad "a tampered archive was installed"
else
    grep -q "checksum mismatch" "$WORK/t.out" && ok "tampered archive refused (checksum mismatch)" || bad "refused, but not for the checksum: $(cat "$WORK/t.out")"
fi
if INTELLISENSE_DOWNLOAD_BASE="file://$WORK/dist" sh "$ROOT/install.sh" >/dev/null 2>&1; then
    bad "a download base without a version was accepted"
else
    ok "download base without a version is refused"
fi

echo "3. package manifests"
mkdir -p "$WORK/pkg"
for t in darwin_arm64 darwin_amd64 linux_arm64 linux_amd64; do echo "$t" > "$WORK/pkg/intellisense_9.9.9_$t.tar.gz"; done
for t in windows_amd64 windows_arm64; do echo "$t" > "$WORK/pkg/intellisense_9.9.9_$t.zip"; done
(cd "$WORK/pkg" && shasum -a 256 ./* | sed 's# \./# #' > checksums.txt)
if bash "$ROOT/scripts/release/packaging.sh" v9.9.9 "$WORK/pkg" >/dev/null 2>&1; then
    darwin_sha="$(grep ' intellisense_9.9.9_darwin_arm64.tar.gz$' "$WORK/pkg/checksums.txt" | cut -d' ' -f1)"
    grep -q "sha256 \"$darwin_sha\"" "$WORK/pkg/intellisense.rb" && ok "Homebrew formula carries the darwin/arm64 checksum" || bad "formula checksum wrong"
    if command -v ruby >/dev/null 2>&1; then
        ruby -c "$WORK/pkg/intellisense.rb" >/dev/null 2>&1 && ok "formula is valid Ruby" || bad "formula is not valid Ruby"
    fi
    jq -e '.version == "9.9.9" and (.architecture."64bit".url | endswith("windows_amd64.zip"))' "$WORK/pkg/intellisense.json" >/dev/null \
        && ok "Scoop manifest is valid JSON for 9.9.9" || bad "Scoop manifest wrong"
    win_sha="$(grep ' intellisense_9.9.9_windows_amd64.zip$' "$WORK/pkg/checksums.txt" | cut -d' ' -f1 | tr '[:lower:]' '[:upper:]')"
    grep -q "InstallerSha256: $win_sha" "$WORK/pkg/winget/Soupler.Intellisense.installer.yaml" \
        && [ -f "$WORK/pkg/winget/Soupler.Intellisense.yaml" ] && [ -f "$WORK/pkg/winget/Soupler.Intellisense.locale.en-US.yaml" ] \
        && ok "winget manifests (version, installer, locale) with the right checksum" || bad "winget manifests wrong"
else
    bad "packaging.sh failed"
fi

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
