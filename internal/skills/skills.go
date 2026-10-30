// Package skills installs the portable Claude Code skills into a repository.
//
// A skill is a slash command (/plan, /tdd …) Claude Code loads from .claude/skills/<name>/SKILL.md. The ones
// listed in Portable work in any repository; the rest rely on Live mode (the code graph, session contracts,
// the service map) and come only with `intellisense live install`.
package skills

import (
	"fmt"
	"io/fs"
	"path"
	"sort"
	"strings"

	intellisense "github.com/soupler-oss/intellisense"
	"github.com/soupler-oss/intellisense/internal/adapters"
	"github.com/soupler-oss/intellisense/internal/policy"
)

// Dir is where Claude Code reads repository skills.
const Dir = ".claude/skills"

// Portable are the skills that need nothing but the repository.
var Portable = []string{"diagnose", "document-service", "e2e-test", "incident", "load-test", "performance-test", "plan", "security-scan", "tdd", "verify"}

// Info is one skill for `intellisense skills list`.
type Info struct {
	Name        string
	Description string
	Portable    bool
}

// List describes every built-in skill.
func List() ([]Info, error) {
	entries, err := fs.ReadDir(intellisense.Skills, "skills")
	if err != nil {
		return nil, err
	}
	var out []Info
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		data, err := fs.ReadFile(intellisense.Skills, "skills/"+e.Name()+"/SKILL.md")
		if err != nil {
			continue
		}
		out = append(out, Info{Name: e.Name(), Description: description(string(data)), Portable: contains(Portable, e.Name())})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out, nil
}

func description(skill string) string {
	if !strings.HasPrefix(skill, "---\n") {
		return ""
	}
	end := strings.Index(skill[4:], "\n---")
	if end < 0 {
		return ""
	}
	for _, line := range strings.Split(skill[4:4+end], "\n") {
		if v, ok := strings.CutPrefix(line, "description:"); ok {
			return strings.TrimSpace(v)
		}
	}
	return ""
}

// Validate rejects names that are not portable skills.
func Validate(names []string) error {
	for _, n := range names {
		if !contains(Portable, n) {
			return fmt.Errorf("skill %q cannot be installed per repository (portable skills: %s; the others come with `intellisense live install`)",
				n, strings.Join(Portable, ", "))
		}
	}
	return nil
}

// Outputs are the files `intellisense sync` writes for the policy's skills. Skills are a Claude Code format,
// so nothing is written unless the claude agent is enabled.
func Outputs(p *policy.Policy) ([]adapters.Output, error) {
	if err := Validate(p.Skills); err != nil {
		return nil, err
	}
	if !p.HasAgent("claude") {
		return nil, nil
	}
	var out []adapters.Output
	for _, name := range p.Skills {
		root := "skills/" + name
		err := fs.WalkDir(intellisense.Skills, root, func(file string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return err
			}
			data, err := fs.ReadFile(intellisense.Skills, file)
			if err != nil {
				return err
			}
			content := string(data)
			if strings.HasSuffix(file, ".md") {
				content = markGenerated(content)
			}
			out = append(out, adapters.Output{Path: path.Join(Dir, strings.TrimPrefix(file, "skills/")), Content: content, Agent: "claude"})
			return nil
		})
		if err != nil {
			return nil, fmt.Errorf("skill %s: %w", name, err)
		}
	}
	return out, nil
}

// markGenerated puts the generated line after the front matter, which Claude Code needs first.
func markGenerated(md string) string {
	if strings.HasPrefix(md, "---\n") {
		if end := strings.Index(md[4:], "\n---\n"); end >= 0 {
			cut := 4 + end + 5
			return md[:cut] + "\n" + adapters.GeneratedLine + "\n" + md[cut:]
		}
	}
	return adapters.GeneratedLine + "\n\n" + md
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
