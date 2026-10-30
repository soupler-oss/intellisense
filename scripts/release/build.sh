#!/usr/bin/env bash
# build.sh VERSION [DIST_DIR] — build the release archives and checksums.txt.
#
# One archive per target: intellisense_<version>_<os>_<arch>.tar.gz (.zip for Windows), each holding the binary,
# LICENSE, NOTICE and README.md. TARGETS (space-separated os/arch) narrows the set, e.g. for a local test.
set -euo pipefail
cd "$(dirname "$0")/../.."
version="${1:?usage: build.sh VERSION [DIST_DIR]}"
version="${version#v}"
dist="${2:-dist}"
targets="${TARGETS:-linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64 windows/arm64}"
rm -rf "$dist" build
mkdir -p "$dist"
for target in $targets; do
  os=${target%/*} arch=${target#*/}
  name="intellisense_${version}_${os}_${arch}"
  exe=intellisense; [ "$os" = windows ] && exe=intellisense.exe
  mkdir -p "build/$name"
  GOOS=$os GOARCH=$arch CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o "build/$name/$exe" ./cmd/intellisense
  cp LICENSE NOTICE README.md "build/$name/"
  if [ "$os" = windows ]; then
    (cd build && zip -qr "../$dist/$name.zip" "$name")
  else
    tar -C build -czf "$dist/$name.tar.gz" "$name"
  fi
done
rm -rf build
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$dist" && sha256sum ./* | sed 's# \./# #' > checksums.txt)
else
  (cd "$dist" && shasum -a 256 ./* | sed 's# \./# #' > checksums.txt)
fi
echo "built $(ls "$dist" | grep -vc checksums) archive(s) in $dist"
