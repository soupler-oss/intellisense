// Package hook installs the pre-push hook that runs `intellisense gate --pre-push`.
//
// The hook goes where git looks for hooks (honouring core.hooksPath). An existing pre-push hook that is
// not intellisense's is never overwritten: with chain set it is kept as pre-push.local and runs first,
// receiving the same input; otherwise Install refuses.
package hook

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/soupler-oss/intellisense/internal/gitx"
)

// Marker identifies a hook intellisense wrote.
const Marker = "# intellisense:hook"

// Name is the hook file intellisense manages.
const Name = "pre-push"

// LocalSuffix names a chained hook: pre-push.local.
const LocalSuffix = ".local"

// ErrForeignHook means a pre-push hook that intellisense did not write is already installed.
var ErrForeignHook = errors.New("a pre-push hook that intellisense did not install already exists")

// ErrAlreadyGated means the existing pre-push hook is not intellisense's but already runs the gate (for example
// the one repo-governance manages in .githooks/), so nothing needs installing.
var ErrAlreadyGated = errors.New("the existing pre-push hook already runs the intellisense gate")

// runsGate matches a hook body that calls the gate: `intellisense gate --pre-push`, or `go run ./cmd/intellisense
// gate --pre-push` in intellisense's own repository.
var runsGate = regexp.MustCompile(`intellisense["']?\s+gate\s+--pre-push`)

// RunsGate reports whether a hook body runs the intellisense gate.
func RunsGate(body string) bool { return strings.Contains(body, Marker) || runsGate.MatchString(body) }

// Script is the hook body. fallback is an absolute path to the binary, used when intellisense is not on
// PATH at push time (git runs hooks with a reduced environment on some systems).
func Script(fallback string) string {
	fallback = strings.ReplaceAll(filepath.ToSlash(fallback), "'", "")
	return `#!/bin/sh
` + Marker + ` — installed by "intellisense hook install"; remove with "intellisense hook uninstall".
# Blocks a push whose commits lack the evidence their risk tier needs. See .intellisense.yml.
INTELLISENSE=$(command -v intellisense 2>/dev/null)
[ -n "$INTELLISENSE" ] || INTELLISENSE='` + fallback + `'
if [ ! -x "$INTELLISENSE" ]; then
  echo "intellisense: the CLI is not installed or not on PATH, so this push cannot be checked." >&2
  echo "Install it: https://github.com/soupler-oss/intellisense#install" >&2
  exit 1
fi
input=$(cat)
if [ -x "$0` + LocalSuffix + `" ]; then
  printf '%s\n' "$input" | "$0` + LocalSuffix + `" "$@" || exit $?
fi
printf '%s\n' "$input" | "$INTELLISENSE" gate --pre-push "$@"
`
}

// Path is where the pre-push hook lives for the repository.
func Path(repo *gitx.Repo) (string, error) {
	dir, err := repo.HooksDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, Name), nil
}

// Installed reports whether the pre-push hook runs the gate: intellisense's own hook, or one that calls it.
func Installed(repo *gitx.Repo) (bool, string, error) {
	path, err := Path(repo)
	if err != nil {
		return false, "", err
	}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, path, nil
	}
	if err != nil {
		return false, path, err
	}
	return RunsGate(string(data)), path, nil
}

// Install writes the hook, chaining an existing foreign hook when chain is set.
func Install(repo *gitx.Repo, fallback string, chain bool) (string, error) {
	path, err := Path(repo)
	if err != nil {
		return "", err
	}
	if data, err := os.ReadFile(path); err == nil && !strings.Contains(string(data), Marker) {
		if RunsGate(string(data)) {
			return path, ErrAlreadyGated
		}
		if !chain {
			return path, fmt.Errorf("%w (%s); rerun with --chain to keep it as %s%s and run it first", ErrForeignHook, path, Name, LocalSuffix)
		}
		local := path + LocalSuffix
		if _, err := os.Stat(local); err == nil {
			return path, fmt.Errorf("both %s and %s exist; merge them by hand", path, local)
		}
		if err := os.Rename(path, local); err != nil {
			return path, err
		}
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return path, err
	}
	return path, os.WriteFile(path, []byte(Script(fallback)), 0o755)
}

// Uninstall removes intellisense's hook and restores a chained one.
func Uninstall(repo *gitx.Repo) (string, error) {
	path, err := Path(repo)
	if err != nil {
		return path, err
	}
	if data, err := os.ReadFile(path); err != nil || !strings.Contains(string(data), Marker) {
		return path, errors.New("no pre-push hook installed by intellisense (a hook that calls the gate itself is left alone)")
	}
	if err := os.Remove(path); err != nil {
		return path, err
	}
	if _, err := os.Stat(path + LocalSuffix); err == nil {
		return path, os.Rename(path+LocalSuffix, path)
	}
	return path, nil
}
