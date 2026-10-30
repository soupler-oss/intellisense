package adapters

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/soupler-oss/intellisense/internal/rules"
)

// Change actions.
const (
	Created   = "created"
	Updated   = "updated"
	Removed   = "removed"
	Unchanged = "unchanged"
)

// Change is what Sync did, or in check mode would do, to one file.
type Change struct {
	Path   string
	Action string
}

// Sync writes the outputs under root and removes generated files the outputs no longer include: a managed
// block whose agent was turned off, or a fully generated file. A file without the generated line or the
// markers is never removed. With check set it changes nothing and only reports.
func Sync(root string, outputs []Output, check bool) ([]Change, error) {
	var changes []Change
	want := map[string]bool{}
	for _, o := range outputs {
		want[o.Path] = true
		path := filepath.Join(root, filepath.FromSlash(o.Path))
		old, err := os.ReadFile(path)
		exists := err == nil
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		next := o.Content
		if o.Block {
			next, err = Splice(string(old), o.Content)
			if err != nil {
				return nil, fmt.Errorf("%s: %w", o.Path, err)
			}
		}
		action := Unchanged
		switch {
		case !exists:
			action = Created
		case string(old) != next:
			action = Updated
		}
		changes = append(changes, Change{o.Path, action})
		if check || action == Unchanged {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return nil, err
		}
		if err := os.WriteFile(path, []byte(next), 0o644); err != nil {
			return nil, err
		}
	}

	stale, err := staleOutputs(root, want)
	if err != nil {
		return nil, err
	}
	for _, s := range stale {
		changes = append(changes, Change{s.path, Removed})
		if check {
			continue
		}
		full := filepath.Join(root, filepath.FromSlash(s.path))
		if s.rest == "" {
			if err := os.Remove(full); err != nil {
				return nil, err
			}
		} else if err := os.WriteFile(full, []byte(s.rest), 0o644); err != nil {
			return nil, err
		}
	}
	sort.SliceStable(changes, func(i, j int) bool { return changes[i].Path < changes[j].Path })
	return changes, nil
}

// Drift is the changes that are not Unchanged.
func Drift(changes []Change) []Change {
	var out []Change
	for _, c := range changes {
		if c.Action != Unchanged {
			out = append(out, c)
		}
	}
	return out
}

// Splice puts block between the markers in existing text: replacing the old block, or appended after the
// existing text when there is none.
func Splice(existing, block string) (string, error) {
	wrapped := BeginMarker + "\n" + strings.TrimRight(block, "\n") + "\n" + EndMarker + "\n"
	begin, end := strings.Index(existing, BeginMarker), strings.Index(existing, EndMarker)
	switch {
	case begin < 0 && end < 0:
		if strings.TrimSpace(existing) == "" {
			return wrapped, nil
		}
		return strings.TrimRight(existing, "\n") + "\n\n" + wrapped, nil
	case begin < 0 || end < begin:
		return "", errors.New("intellisense markers are unbalanced; fix or remove them by hand")
	}
	after := existing[end+len(EndMarker):]
	after = strings.TrimPrefix(after, "\n")
	return existing[:begin] + wrapped + after, nil
}

// Unsplice removes the managed block, returning the rest ("" when nothing else is left).
func Unsplice(existing string) string {
	begin, end := strings.Index(existing, BeginMarker), strings.Index(existing, EndMarker)
	if begin < 0 || end < begin {
		return existing
	}
	rest := strings.TrimRight(existing[:begin], "\n") + "\n" + strings.TrimLeft(existing[end+len(EndMarker):], "\n")
	if strings.TrimSpace(rest) == "" {
		return ""
	}
	return strings.TrimLeft(rest, "\n")
}

type staleFile struct {
	path string
	// rest is what remains of a shared file after its block is removed; "" deletes the file.
	rest string
}

func staleOutputs(root string, want map[string]bool) ([]staleFile, error) {
	var out []staleFile
	for _, shared := range []string{"CLAUDE.md", "AGENTS.md"} {
		if want[shared] {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, shared))
		if err != nil || !strings.Contains(string(data), BeginMarker) {
			continue
		}
		out = append(out, staleFile{shared, Unsplice(string(data))})
	}
	candidates := []string{CopilotCore, rules.WorkflowFile}
	for _, g := range []struct{ dir, prefix, suffix string }{
		{CopilotDir, CopilotPrefix, CopilotSuffix},
		{CursorDir, CursorPrefix, CursorSuffix},
	} {
		entries, err := os.ReadDir(filepath.Join(root, filepath.FromSlash(g.dir)))
		if err != nil {
			continue
		}
		for _, e := range entries {
			if !e.IsDir() && strings.HasPrefix(e.Name(), g.prefix) && strings.HasSuffix(e.Name(), g.suffix) {
				candidates = append(candidates, g.dir+e.Name())
			}
		}
	}
	for _, c := range candidates {
		if want[c] {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(c)))
		if err == nil && strings.Contains(string(data), GeneratedLine) {
			out = append(out, staleFile{c, ""})
		}
	}
	return append(out, staleSkills(root, want)...), nil
}

// SkillsDir is where generated Claude Code skills live.
const SkillsDir = ".claude/skills/"

// staleSkills are the files of generated skills the policy no longer lists. A skill counts as generated when
// its SKILL.md carries the generated line; a skill someone wrote by hand is never touched.
func staleSkills(root string, want map[string]bool) []staleFile {
	var out []staleFile
	entries, err := os.ReadDir(filepath.Join(root, filepath.FromSlash(SkillsDir)))
	if err != nil {
		return nil
	}
	for _, e := range entries {
		skill := SkillsDir + e.Name() + "/"
		if !e.IsDir() || want[skill+"SKILL.md"] {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(skill+"SKILL.md")))
		if err != nil || !strings.Contains(string(data), GeneratedLine) {
			continue
		}
		_ = filepath.WalkDir(filepath.Join(root, filepath.FromSlash(skill)), func(p string, d os.DirEntry, err error) error {
			if err == nil && !d.IsDir() {
				rel, _ := filepath.Rel(root, p)
				out = append(out, staleFile{filepath.ToSlash(rel), ""})
			}
			return nil
		})
	}
	return out
}
