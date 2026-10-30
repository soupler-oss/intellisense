#!/bin/bash
# Cross-platform sha256 helper.
#
# macOS ships /usr/bin/shasum but not sha256sum.
# Linux ships sha256sum but not always shasum.
# Returns the hex digest on stdout, exit 1 if no hasher available.
#
# Usage: hash="$(hb_sha256 /path/to/file)"

hb_sha256() {
    local path="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{print $1}'
        return ${PIPESTATUS[0]:-$?}
    fi
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{print $1}'
        return ${PIPESTATUS[0]:-$?}
    fi
    return 1
}
