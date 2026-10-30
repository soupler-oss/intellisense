// Package rules vendors the portable rule set into a repository and reads back what is there.
//
// A governed repository keeps its rules in .intellisense/rules/, committed, so every agent and every
// reviewer reads the same text and a rule change shows up in review like any other change:
//
//	.intellisense/rules/
//	  workflow.md              generated from .intellisense.yml by `intellisense sync`
//	  baseline/                always on: security, reasoning integrity
//	  operational/             coding style, testing, proof standards, AI regression patterns
//	  language-specific/       one file (or folder) per stack in the policy
//	  organization/            your own rules; intellisense never writes here
//
// Only rules that make sense to every agent are vendored. The rest of rules/operational/ describes the
// Live-mode machinery (skills, hooks, the code graph, Beads) and stays with that mode.
package rules

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	intellisense "github.com/soupler-oss/intellisense"
	"github.com/soupler-oss/intellisense/internal/policy"
)

// Dir is the vendored rules directory, relative to the repository root.
const Dir = ".intellisense/rules"

// WorkflowFile is the generated workflow rule, relative to the repository root.
const WorkflowFile = Dir + "/workflow.md"

// Rule kinds.
const (
	KindBaseline     = "baseline"
	KindOperational  = "operational"
	KindStack        = "language-specific"
	KindOrganization = "organization"
)

// Portable are the operational rules every agent gets.
var Portable = []string{"coding-style.md", "testing.md", "proof-standards.md", "ai-regression-patterns.md"}

// Rule is one vendored rule file.
type Rule struct {
	// Path is repo-relative with / separators.
	Path  string
	Kind  string
	Title string
	// Globs scope the rule to matching files; empty means every file.
	Globs []string
	// Body is the file without its front matter.
	Body string
}

// Slug names the rule in generated file names, e.g. "language-specific-go-patterns".
func (r Rule) Slug() string {
	rel := strings.TrimPrefix(r.Path, Dir+"/")
	return strings.ReplaceAll(strings.TrimSuffix(rel, ".md"), "/", "-")
}

// Mode says what Vendor does with a rule file that already exists.
type Mode int

const (
	// Missing writes only files that do not exist yet (init).
	Missing Mode = iota
	// Update also refreshes files intellisense wrote and nobody has edited since; edited files are kept.
	Update
	// Force overwrites every built-in file, edited or not.
	Force
)

// Result lists what Vendor did, by repo-relative path.
type Result struct {
	Written []string // created or refreshed
	Kept    []string // left alone because they were edited locally (or predate the checksum record)
	Removed []string // disabled rules that were unedited copies
}

// Sources are the built-in files the policy asks for, as paths inside the embedded rules tree.
func Sources(p *policy.Policy) ([]string, error) {
	var sources []string
	for _, name := range []string{"reasoning-integrity.md", "security.md"} {
		sources = append(sources, "rules/baseline/"+name)
	}
	for _, name := range Portable {
		sources = append(sources, "rules/operational/"+name)
	}
	for _, s := range p.Stacks {
		st, ok := p.Stack(s)
		if !ok || st.Custom {
			continue // a custom stack's rule is the repository's own file
		}
		sources = append(sources, "rules/language-specific/"+st.Rule)
		if st.Dir != "" {
			entries, err := fs.ReadDir(intellisense.Rules, "rules/language-specific/"+st.Dir)
			if err != nil {
				return nil, err
			}
			for _, e := range entries {
				if !e.IsDir() && strings.HasSuffix(e.Name(), ".md") {
					sources = append(sources, "rules/language-specific/"+st.Dir+"/"+e.Name())
				}
			}
		}
	}
	return sources, nil
}

// ID is a vendored file's rule id: its path under .intellisense/rules/ without ".md".
func ID(rel string) string { return strings.TrimSuffix(strings.TrimPrefix(rel, Dir+"/"), ".md") }

// Vendor copies the built-in rules for the policy's stacks into root/.intellisense/rules. organization/ is
// never touched, disabled rules are skipped, and in Update mode a file someone edited is kept: the checksum
// of every file intellisense writes is recorded in .intellisense/rules/.checksums.json.
func Vendor(root string, p *policy.Policy, mode Mode) (Result, error) {
	var res Result
	sources, err := Sources(p)
	if err != nil {
		return res, err
	}
	vendored := map[string]bool{}
	for _, src := range sources {
		vendored[Dir+"/"+strings.TrimPrefix(src, "rules/")] = true
	}
	sums, err := LoadChecksums(root)
	if err != nil {
		return res, err
	}
	for _, src := range sources {
		rel := Dir + "/" + strings.TrimPrefix(src, "rules/")
		if p.RuleDisabled(ID(rel)) {
			if removed, err := sums.removeUnedited(root, rel); err != nil {
				return res, err
			} else if removed {
				res.Removed = append(res.Removed, rel)
			}
			continue
		}
		data, err := fs.ReadFile(intellisense.Rules, src)
		if err != nil {
			return res, fmt.Errorf("built-in rule %s: %w", src, err)
		}
		data = []byte(Localize(string(data), rel, vendored))
		wrote, kept, err := sums.write(root, rel, data, mode)
		if err != nil {
			return res, err
		}
		if wrote {
			res.Written = append(res.Written, rel)
		}
		if kept {
			res.Kept = append(res.Kept, rel)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, filepath.FromSlash(Dir), KindOrganization), 0o755); err != nil {
		return res, err
	}
	readme := filepath.Join(root, filepath.FromSlash(Dir), KindOrganization, "README.md")
	if _, err := os.Stat(readme); errors.Is(err, os.ErrNotExist) {
		if err := os.WriteFile(readme, []byte(orgReadme), 0o644); err != nil {
			return res, err
		}
		res.Written = append(res.Written, Dir+"/"+KindOrganization+"/README.md")
	}
	return res, sums.Save(root)
}

var mdLink = regexp.MustCompile(`\[([^\]]+)\]\(([^)\s]+)\)`)

// Localize adapts a built-in rule to live at rel inside a repository: Live-mode install paths
// (~/.intellisense/rules/...) become repo paths, and a relative link to a file that is not vendored becomes its
// plain text, so a governed repository never carries a dead link.
func Localize(text, rel string, vendored map[string]bool) string {
	text = strings.ReplaceAll(text, "~/.intellisense/rules/", Dir+"/")
	return mdLink.ReplaceAllStringFunc(text, func(m string) string {
		sub := mdLink.FindStringSubmatch(m)
		label, target := sub[1], sub[2]
		if strings.Contains(target, "://") || strings.HasPrefix(target, "#") || strings.HasPrefix(target, "mailto:") {
			return m
		}
		file, _, _ := strings.Cut(target, "#")
		resolved := path.Clean(path.Join(path.Dir(rel), file))
		if vendored[resolved] {
			return m
		}
		for v := range vendored {
			if strings.HasPrefix(v, strings.TrimSuffix(resolved, "/")+"/") {
				return m
			}
		}
		return label
	})
}

const orgReadme = `# Organization rules

Put your own rules here: one Markdown file per topic (compliance, internal libraries, domain terms).
` + "`intellisense sync`" + ` gives every file in this folder, except this README, to every enabled agent,
and ` + "`intellisense rules update`" + ` never touches this folder.

Optional front matter scopes a rule to some files:

    ---
    globs: ["**/*.go", "migrations/**"]
    ---
`

// Discover reads the vendored rules under root, sorted by kind then path. workflow.md, READMEs and rules the
// policy disables are skipped. A rule under language-specific/ takes its stack's globs (custom stacks
// included); an organization rule takes the globs in its front matter.
func Discover(root string, p *policy.Policy) ([]Rule, error) {
	base := filepath.Join(root, filepath.FromSlash(Dir))
	var out []Rule
	err := filepath.WalkDir(base, func(file string, d fs.DirEntry, err error) error {
		if errors.Is(err, os.ErrNotExist) {
			return fs.SkipAll
		}
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(file, ".md") || strings.EqualFold(d.Name(), "README.md") {
			return nil
		}
		relFS, _ := filepath.Rel(root, file)
		rel := filepath.ToSlash(relFS)
		if rel == WorkflowFile || p.RuleDisabled(ID(rel)) {
			return nil
		}
		data, err := os.ReadFile(file)
		if err != nil {
			return err
		}
		front, body := SplitFrontMatter(string(data))
		r := Rule{Path: rel, Body: body, Title: title(body, d.Name())}
		inner := strings.TrimPrefix(rel, Dir+"/")
		r.Kind = strings.SplitN(inner, "/", 2)[0]
		switch r.Kind {
		case KindStack:
			r.Globs = stackGlobs(p, strings.TrimPrefix(inner, KindStack+"/"))
		case KindOrganization:
			r.Globs = frontGlobs(front)
		}
		out = append(out, r)
		return nil
	})
	if err != nil {
		return nil, err
	}
	order := map[string]int{KindBaseline: 0, KindOperational: 1, KindStack: 2, KindOrganization: 3}
	sort.SliceStable(out, func(i, j int) bool {
		if order[out[i].Kind] != order[out[j].Kind] {
			return order[out[i].Kind] < order[out[j].Kind]
		}
		return out[i].Path < out[j].Path
	})
	return out, nil
}

func stackGlobs(p *policy.Policy, rel string) []string {
	first := strings.SplitN(rel, "/", 2)[0]
	for _, st := range p.AllStacks() {
		if first == st.Rule || (st.Dir != "" && first == st.Dir) {
			return st.Globs
		}
	}
	return nil
}

// SplitFrontMatter separates a leading "---" YAML block from the body.
func SplitFrontMatter(s string) (front, body string) {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	if !strings.HasPrefix(s, "---\n") {
		return "", s
	}
	end := strings.Index(s[4:], "\n---\n")
	if end < 0 {
		return "", s
	}
	return s[4 : 4+end], strings.TrimLeft(s[4+end+5:], "\n")
}

// frontGlobs reads `globs: [..]` or `globs: a, b` from front matter.
func frontGlobs(front string) []string {
	for _, line := range strings.Split(front, "\n") {
		k, v, ok := strings.Cut(line, ":")
		if !ok || strings.TrimSpace(k) != "globs" {
			continue
		}
		v = strings.Trim(strings.TrimSpace(v), "[]")
		var out []string
		for _, g := range strings.Split(v, ",") {
			if g = strings.Trim(strings.TrimSpace(g), `"'`); g != "" {
				out = append(out, g)
			}
		}
		return out
	}
	return nil
}

func title(body, fallback string) string {
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "# ") {
			return strings.TrimSpace(line[2:])
		}
	}
	return strings.TrimSuffix(path.Base(fallback), ".md")
}
