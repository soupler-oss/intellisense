package gate

import (
	"bufio"
	"fmt"
	"io"
	"strings"

	"github.com/soupler-oss/intellisense/internal/gitx"
)

// PushedRef is one line git gives a pre-push hook on stdin.
type PushedRef struct {
	LocalRef, LocalSHA, RemoteRef, RemoteSHA string
}

// ReadPushedRefs parses pre-push stdin: "<local ref> <local sha> <remote ref> <remote sha>" per line.
func ReadPushedRefs(r io.Reader) ([]PushedRef, error) {
	var out []PushedRef
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) == 0 {
			continue
		}
		if len(f) != 4 {
			return nil, fmt.Errorf("unexpected pre-push input line %q", sc.Text())
		}
		out = append(out, PushedRef{f[0], f[1], f[2], f[3]})
	}
	return out, sc.Err()
}

// PushRange is the range a pushed ref introduces. Deleting a ref or pushing a tag introduces nothing to check.
//
// An update of an existing remote branch is checked from the remote's old tip. A new branch is checked
// from where it leaves the remote's default branch (upstream's first, for fork workflows); with no such
// branch, from the commits no remote has.
func PushRange(repo *gitx.Repo, remote string, ref PushedRef) (gitx.Range, bool, error) {
	if ref.LocalSHA == gitx.ZeroSHA || strings.HasPrefix(ref.RemoteRef, "refs/tags/") {
		return gitx.Range{}, false, nil
	}
	if ref.RemoteSHA != gitx.ZeroSHA && repo.Exists(ref.RemoteSHA) {
		rg, err := repo.RangeBetween(ref.RemoteSHA, ref.LocalSHA)
		return rg, err == nil, err
	}
	for _, r := range []string{"upstream", remote, "origin"} {
		if def := repo.DefaultBranchRef(r); def != "" {
			if rg, err := repo.RangeBetween(def, ref.LocalSHA); err == nil {
				return rg, true, nil
			}
		}
	}
	rg, err := repo.RangeNotOnRemotes(ref.LocalSHA)
	return rg, err == nil, err
}
