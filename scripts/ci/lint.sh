#!/usr/bin/env bash
# Static checks: Go formatting and vet, Bash syntax, JSON validity. Covers tracked and new (untracked,
# not ignored) files, so it can run before the first commit.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR" || exit 1
files() { git ls-files --cached --others --exclude-standard -- "$@" | while IFS= read -r f; do [ -e "$f" ] && printf "%s\n" "$f"; done; }
status=0
err() { echo "  ✗ $*"; status=1; }

echo "== gofmt / go vet"
unformatted=$(gofmt -l $(files '*.go'))
[ -z "$unformatted" ] || err "not gofmt-formatted: $unformatted"
go vet ./... || status=1

echo "== bash -n"
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || err "syntax error: $f"
done < <(files '*.sh' hooks/pre-push '.githooks/*' | sort -u)

echo "== json"
while IFS= read -r f; do
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$f" 2>/dev/null || err "invalid JSON: $f"
done < <(files '*.json')

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck (errors only)"
  files '*.sh' | xargs shellcheck -S error || status=1
fi

exit $status
