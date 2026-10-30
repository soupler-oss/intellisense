#!/bin/sh
# install.sh — download and install the intellisense binary.
#
#   curl -fsSL https://raw.githubusercontent.com/soupler-oss/intellisense/main/install.sh | sh
#
# It picks the release archive for this OS and CPU, checks it against the release's checksums.txt, and puts
# the binary in $INTELLISENSE_INSTALL_DIR, else /usr/local/bin when writable, else ~/.local/bin. It changes
# nothing else: run `intellisense init` in a repository afterwards.
#
# Environment:
#   INTELLISENSE_VERSION        a release such as 1.0.0 (default: the latest release)
#   INTELLISENSE_INSTALL_DIR    where to put the binary
#   INTELLISENSE_DOWNLOAD_BASE  where the release files are (default: the GitHub release for the version);
#                               a mirror, or file:///path for a local build — needs INTELLISENSE_VERSION
set -eu

REPO="soupler-oss/intellisense"

say() { printf '%s\n' "$*"; }
die() { printf 'intellisense install: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }

need uname
need tar
if command -v curl >/dev/null 2>&1; then
  fetch() { curl -fsSL "$1" -o "$2"; }
  fetch_stdout() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then
  fetch() { wget -qO "$2" "$1"; }
  fetch_stdout() { wget -qO- "$1"; }
else
  die "curl or wget is required"
fi
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "sha256sum or shasum is required to verify the download"
fi

os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  darwin|linux) ;;
  *) die "unsupported OS $os (on Windows: scoop install intellisense, or download the .zip from https://github.com/$REPO/releases)" ;;
esac
arch=$(uname -m)
case "$arch" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) die "unsupported CPU $arch" ;;
esac

version="${INTELLISENSE_VERSION:-}"
if [ -z "$version" ] && [ -n "${INTELLISENSE_DOWNLOAD_BASE:-}" ]; then
  die "INTELLISENSE_DOWNLOAD_BASE needs INTELLISENSE_VERSION"
fi
if [ -z "$version" ]; then
  version=$(fetch_stdout "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -1)
  [ -n "$version" ] || die "could not find the latest release; set INTELLISENSE_VERSION"
fi
version="${version#v}"

name="intellisense_${version}_${os}_${arch}"
base="${INTELLISENSE_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/v$version}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

say "Downloading intellisense $version for ${os}/${arch}…"
fetch "$base/$name.tar.gz" "$tmp/$name.tar.gz" || die "download failed: $base/$name.tar.gz"
fetch "$base/checksums.txt" "$tmp/checksums.txt" || die "download failed: $base/checksums.txt"
want=$(grep " $name.tar.gz\$" "$tmp/checksums.txt" | cut -d' ' -f1)
[ -n "$want" ] || die "$name.tar.gz is not listed in checksums.txt"
got=$(sha256 "$tmp/$name.tar.gz")
[ "$want" = "$got" ] || die "checksum mismatch for $name.tar.gz (want $want, got $got)"
tar -xzf "$tmp/$name.tar.gz" -C "$tmp"

dir="${INTELLISENSE_INSTALL_DIR:-}"
if [ -z "$dir" ]; then
  if [ -w /usr/local/bin ]; then dir=/usr/local/bin; else dir="$HOME/.local/bin"; fi
fi
mkdir -p "$dir"
install -m 0755 "$tmp/$name/intellisense" "$dir/intellisense" 2>/dev/null || {
  cp "$tmp/$name/intellisense" "$dir/intellisense" && chmod 0755 "$dir/intellisense"
}

say "✓ installed $dir/intellisense ($("$dir/intellisense" version))"
case ":$PATH:" in
  *":$dir:"*) ;;
  *) say "! $dir is not on your PATH. Add it, e.g.: echo 'export PATH=\"$dir:\$PATH\"' >> ~/.profile" ;;
esac
say ""
say "Next:"
say "  cd <your repository> && intellisense init   set up a repository (any AI agent)"
say "  intellisense live install                   add live checks inside Claude Code (optional)"
say "  intellisense help                           every command, with examples"
