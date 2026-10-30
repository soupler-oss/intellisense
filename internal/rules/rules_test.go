package rules

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/soupler-oss/intellisense/internal/policy"
)

func TestEveryBuiltinStackHasItsRule(t *testing.T) {
	p := policy.Default()
	p.Stacks = policy.StackNames()
	root := t.TempDir()
	res, err := Vendor(root, p, Missing)
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Written) < len(p.Stacks) {
		t.Fatalf("wrote %d files for %d stacks", len(res.Written), len(p.Stacks))
	}
}

func TestCustomStackGlobs(t *testing.T) {
	p, err := policy.Parse([]byte(`version: 1
stacks: [elixir]
custom_stacks:
  - name: elixir
    rule: elixir-patterns.md
    globs: ['**/*.ex', '**/*.exs']
    markers: [mix.exs]
`))
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if _, err := Vendor(root, p, Missing); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, Dir, "language-specific", "elixir-patterns.md")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("# Elixir rules\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	rs, err := Discover(root, p)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rs {
		if r.Path == Dir+"/language-specific/elixir-patterns.md" {
			if len(r.Globs) != 2 || r.Globs[0] != "**/*.ex" {
				t.Fatalf("custom stack globs = %v", r.Globs)
			}
			return
		}
	}
	t.Fatal("custom stack rule not discovered")
}

func TestPolicyRejectsBadCustomStack(t *testing.T) {
	for name, src := range map[string]string{
		"shadows builtin": "version: 1\ncustom_stacks: [{name: go, rule: go2.md, globs: ['**/*.go']}]\n",
		"no globs":        "version: 1\ncustom_stacks: [{name: zig, rule: zig.md, globs: []}]\n",
		"rule path":       "version: 1\ncustom_stacks: [{name: zig, rule: ../zig.md, globs: ['**/*.zig']}]\n",
	} {
		if _, err := policy.Parse([]byte(src)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}
