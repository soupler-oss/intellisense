#!/usr/bin/env bash
# Installs the tools the Bash test suite needs, at the versions setup.sh pins: bd (Beads) from its release
# tarball with the SHA-256 check, and code-review-graph from PyPI. The pins are read from setup.sh, so they
# are never duplicated.
#
# Usage: bash scripts/ci/install-test-deps.sh [BIN_DIR]   (default ~/.local/bin; add it to PATH)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_DIR="${1:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"

pin() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "$ROOT_DIR/setup.sh" | head -1; }
BD_VERSION=$(pin BD_REQUIRED_VERSION)
CRG_VERSION=$(pin CRG_REQUIRED_VERSION)
[ -n "$BD_VERSION" ] && [ -n "$CRG_VERSION" ] || { echo "could not read the pins from setup.sh" >&2; exit 1; }

os=$(uname -s | tr '[:upper:]' '[:lower:]')
arch=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
sha_var="BD_SHA256_$(echo "${os}_${arch}" | tr '[:lower:]' '[:upper:]')"
want=$(pin "$sha_var")
[ -n "$want" ] || { echo "setup.sh has no $sha_var for this platform" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
url="https://github.com/gastownhall/beads/releases/download/v${BD_VERSION}/beads_${BD_VERSION}_${os}_${arch}.tar.gz"
curl -fsSL "$url" -o "$tmp/bd.tar.gz"
if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/bd.tar.gz" | cut -d' ' -f1); else got=$(shasum -a 256 "$tmp/bd.tar.gz" | cut -d' ' -f1); fi
[ "$got" = "$want" ] || { echo "bd checksum mismatch: got $got, want $want" >&2; exit 1; }
tar -xzf "$tmp/bd.tar.gz" -C "$tmp"
install -m 0755 "$(find "$tmp" -type f -name bd | head -1)" "$BIN_DIR/bd"
echo "installed bd $("$BIN_DIR/bd" version 2>/dev/null | head -1) to $BIN_DIR"

python3 -m pip install --quiet "code-review-graph==$CRG_VERSION"
echo "installed code-review-graph $CRG_VERSION"
