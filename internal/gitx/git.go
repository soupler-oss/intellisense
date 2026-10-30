// Package gitx is the small set of git queries the gate needs, run through the git binary.
package gitx

import (
	"bytes"
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// EmptyTree is git's well-known empty tree object; diffing against it shows every file as added.
const EmptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

// ZeroSHA is what git passes to pre-push for a ref that does not exist on one side.
const ZeroSHA = "0000000000000000000000000000000000000000"

// Repo runs git in one working tree.
type Repo struct {
	Root string
}

// Open finds the repository containing dir.
func Open(dir string) (*Repo, error) {
	out, err := run(dir, "rev-parse", "--show-toplevel")
	if err != nil {
		return nil, fmt.Errorf("not a git repository: %s", dir)
	}
	return &Repo{Root: filepath.Clean(strings.TrimSpace(out))}, nil
}

func run(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return stdout.String(), fmt.Errorf("git %s: %s", strings.Join(args, " "), msg)
	}
	return stdout.String(), nil
}

// Git runs a git command in the repository and returns stdout.
func (r *Repo) Git(args ...string) (string, error) { return run(r.Root, args...) }

// Exists reports whether rev names an object.
func (r *Repo) Exists(rev string) bool {
	_, err := r.Git("cat-file", "-e", rev+"^{object}")
	return err == nil
}

// Resolve returns the full SHA of a commit-ish.
func (r *Repo) Resolve(rev string) (string, error) {
	out, err := r.Git("rev-parse", "--verify", "--quiet", rev+"^{commit}")
	if err != nil {
		return "", fmt.Errorf("unknown revision %q", rev)
	}
	return strings.TrimSpace(out), nil
}

// MergeBase is the best common ancestor of a and b.
func (r *Repo) MergeBase(a, b string) (string, error) {
	out, err := r.Git("merge-base", a, b)
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(out), nil
}

// DefaultBranchRef finds the remote-tracking ref of a remote's default branch, e.g. "origin/main".
func (r *Repo) DefaultBranchRef(remote string) string {
	if out, err := r.Git("symbolic-ref", "--quiet", "--short", "refs/remotes/"+remote+"/HEAD"); err == nil {
		return strings.TrimSpace(out)
	}
	for _, b := range []string{"main", "master", "develop"} {
		if r.Exists("refs/remotes/" + remote + "/" + b) {
			return remote + "/" + b
		}
	}
	return ""
}

// Range is the set of changes under evaluation: everything from From (a commit, or EmptyTree for a
// history with no base) up to Head.
type Range struct {
	From string
	Head string
}

// RangeBetween builds the range a pull request or push introduces: from the merge base of base and head.
func (r *Repo) RangeBetween(base, head string) (Range, error) {
	h, err := r.Resolve(head)
	if err != nil {
		return Range{}, err
	}
	b, err := r.Resolve(base)
	if err != nil {
		return Range{}, err
	}
	mb, err := r.MergeBase(b, h)
	if err != nil {
		return Range{}, fmt.Errorf("no common history between %s and %s", base, head)
	}
	return Range{From: mb, Head: h}, nil
}

// RangeNotOnRemotes is the range of commits reachable from head that no remote-tracking ref has: what a
// first push of a new branch introduces when there is no base to compare with.
func (r *Repo) RangeNotOnRemotes(head string) (Range, error) {
	h, err := r.Resolve(head)
	if err != nil {
		return Range{}, err
	}
	out, err := r.Git("rev-list", "--topo-order", "--reverse", h, "--not", "--remotes")
	if err != nil {
		return Range{}, err
	}
	commits := strings.Fields(out)
	if len(commits) == 0 {
		return Range{From: h, Head: h}, nil
	}
	if parent, err := r.Resolve(commits[0] + "^"); err == nil {
		return Range{From: parent, Head: h}, nil
	}
	return Range{From: EmptyTree, Head: h}, nil
}

// ChangedFiles lists paths that differ between From and Head. Renames are reported as a delete and an add,
// so both the old and new path are classified.
func (r *Repo) ChangedFiles(rg Range) ([]string, error) {
	out, err := r.Git("diff", "--name-only", "--no-renames", "-z", rg.From, rg.Head)
	if err != nil {
		return nil, err
	}
	return splitZ(out), nil
}

// FileDiff is the unified diff of one path over the range.
func (r *Repo) FileDiff(rg Range, path string) (string, error) {
	return r.Git("diff", "--no-renames", "--no-color", rg.From, rg.Head, "--", path)
}

// Diff is the unified diff of the whole range.
func (r *Repo) Diff(rg Range) (string, error) {
	return r.Git("diff", "--no-renames", "--no-color", rg.From, rg.Head)
}

// Commits lists the non-merge commits in the range, oldest first.
func (r *Repo) Commits(rg Range) ([]string, error) {
	args := []string{"rev-list", "--no-merges", "--topo-order", "--reverse", rg.Head}
	if rg.From != EmptyTree {
		args = append(args, "^"+rg.From)
	}
	out, err := r.Git(args...)
	if err != nil {
		return nil, err
	}
	return strings.Fields(out), nil
}

// CommitFiles lists the paths one commit changes.
func (r *Repo) CommitFiles(sha string) ([]string, error) {
	out, err := r.Git("diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", "-z", "--root", sha)
	if err != nil {
		return nil, err
	}
	return splitZ(out), nil
}

// CommitFileDiff is the diff one commit makes to one path.
func (r *Repo) CommitFileDiff(sha, path string) (string, error) {
	return r.Git("show", "--no-renames", "--no-color", "--format=", sha, "--", path)
}

// Message is a commit's full message.
func (r *Repo) Message(sha string) (string, error) { return r.Git("log", "-1", "--format=%B", sha) }

// Subject is a commit's first line.
func (r *Repo) Subject(sha string) string {
	out, _ := r.Git("log", "-1", "--format=%s", sha)
	return strings.TrimSpace(out)
}

// Show returns a file's content at a revision.
func (r *Repo) Show(rev, path string) ([]byte, error) {
	out, err := r.Git("show", rev+":"+path)
	if err != nil {
		return nil, err
	}
	return []byte(out), nil
}

// HooksDir is the directory git runs hooks from, honouring core.hooksPath.
func (r *Repo) HooksDir() (string, error) {
	out, err := r.Git("rev-parse", "--git-path", "hooks")
	if err != nil {
		return "", err
	}
	dir := strings.TrimSpace(out)
	if !filepath.IsAbs(dir) {
		dir = filepath.Join(r.Root, dir)
	}
	return filepath.Clean(dir), nil
}

// AddedLine is a line a diff adds, with its line number in the new file.
type AddedLine struct {
	File string
	Line int
	Text string
}

// AddedLines parses a unified diff into the lines it adds.
func AddedLines(diff string) []AddedLine {
	var out []AddedLine
	file, line, prev := "", 0, ""
	for _, l := range strings.Split(diff, "\n") {
		header := strings.HasPrefix(prev, "--- ")
		prev = l
		switch {
		case header && strings.HasPrefix(l, "+++ "):
			file = strings.TrimPrefix(strings.TrimPrefix(l, "+++ "), "b/")
			if file == "/dev/null" {
				file = ""
			}
		case strings.HasPrefix(l, "@@"):
			line = hunkStart(l)
		case strings.HasPrefix(l, "+"):
			if file != "" {
				out = append(out, AddedLine{File: file, Line: line, Text: l[1:]})
			}
			line++
		case strings.HasPrefix(l, "-"), strings.HasPrefix(l, `\`):
		default:
			line++
		}
	}
	return out
}

// hunkStart reads the new-file start line from "@@ -a,b +c,d @@".
func hunkStart(h string) int {
	i := strings.Index(h, "+")
	if i < 0 {
		return 0
	}
	rest := h[i+1:]
	if j := strings.IndexAny(rest, ", "); j >= 0 {
		rest = rest[:j]
	}
	n, err := strconv.Atoi(rest)
	if err != nil {
		return 0
	}
	return n
}

func splitZ(s string) []string {
	var out []string
	for _, p := range strings.Split(s, "\x00") {
		if p != "" {
			out = append(out, p)
		}
	}
	return out
}
