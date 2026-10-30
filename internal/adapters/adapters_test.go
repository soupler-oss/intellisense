package adapters

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/soupler-oss/intellisense/internal/policy"
	"github.com/soupler-oss/intellisense/internal/rules"
)

func setup(t *testing.T, agents ...string) (string, *policy.Policy) {
	t.Helper()
	root := t.TempDir()
	p := policy.Default()
	p.Stacks = []string{"go", "java"}
	p.Agents = agents
	if _, err := rules.Vendor(root, p, rules.Missing); err != nil {
		t.Fatal(err)
	}
	return root, p
}

func syncAll(t *testing.T, root string, p *policy.Policy, check bool) []Change {
	t.Helper()
	rs, err := rules.Discover(root, p)
	if err != nil {
		t.Fatal(err)
	}
	ch, err := Sync(root, Generate(p, rs), check)
	if err != nil {
		t.Fatal(err)
	}
	return ch
}

func read(t *testing.T, root, rel string) string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(rel)))
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestAllAgentsGenerateAndStayInSync(t *testing.T) {
	root, p := setup(t, policy.KnownAgents...)
	if len(Drift(syncAll(t, root, p, true))) == 0 {
		t.Fatal("check before the first sync must report drift")
	}
	syncAll(t, root, p, false)
	if d := Drift(syncAll(t, root, p, true)); len(d) != 0 {
		t.Fatalf("a second sync must be a no-op, got %v", d)
	}

	claude := read(t, root, "CLAUDE.md")
	for _, want := range []string{"@.intellisense/rules/workflow.md", "@.intellisense/rules/baseline/security.md", "`.intellisense/rules/language-specific/go-patterns.md`"} {
		if !strings.Contains(claude, want) {
			t.Errorf("CLAUDE.md lacks %q", want)
		}
	}
	agents := read(t, root, "AGENTS.md")
	if !strings.Contains(agents, "#### ") || !strings.Contains(agents, "Change Contract:") {
		t.Errorf("AGENTS.md should inline the workflow and baseline with demoted headings")
	}
	if len(agents) > 32*1024 {
		t.Errorf("AGENTS.md is %d bytes; Codex reads 32 KiB by default", len(agents))
	}
	goRule := read(t, root, ".github/instructions/intellisense-language-specific-go-patterns.instructions.md")
	if !strings.HasPrefix(goRule, "---\napplyTo: \"**/*.go\"\n---\n") {
		t.Errorf("Copilot rule must start with its applyTo front matter:\n%.120s", goRule)
	}
	javaSub := read(t, root, ".cursor/rules/intellisense-language-specific-java-spring-boot.mdc")
	if !strings.Contains(javaSub, "globs: **/*.java,") || !strings.Contains(javaSub, "alwaysApply: false") {
		t.Errorf("Java sub-rule should take the Java globs:\n%.200s", javaSub)
	}
	if core := read(t, root, ".cursor/rules/intellisense-core.mdc"); !strings.Contains(core, "alwaysApply: true") {
		t.Error("Cursor core rule must always apply")
	}
}

func TestUserTextAroundTheBlockIsKept(t *testing.T) {
	root, p := setup(t, "claude")
	if err := os.WriteFile(filepath.Join(root, "CLAUDE.md"), []byte("# My project\n\nOur notes.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	syncAll(t, root, p, false)
	got := read(t, root, "CLAUDE.md")
	if !strings.HasPrefix(got, "# My project\n\nOur notes.\n\n"+BeginMarker) {
		t.Fatalf("own text must stay above the block:\n%s", got)
	}
	// Editing inside the block is drift; editing outside it is not.
	if err := os.WriteFile(filepath.Join(root, "CLAUDE.md"), []byte(strings.Replace(got, "Our notes.", "Our better notes.", 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	if d := Drift(syncAll(t, root, p, true)); len(d) != 0 {
		t.Fatalf("text outside the block is the user's: %v", d)
	}
}

func TestTurningAnAgentOffRemovesOnlyItsFiles(t *testing.T) {
	root, p := setup(t, policy.KnownAgents...)
	if err := os.WriteFile(filepath.Join(root, "AGENTS.md"), []byte("# Mine\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mine := filepath.Join(root, ".github", "instructions", "intellisense-handwritten.instructions.md")
	syncAll(t, root, p, false)
	if err := os.WriteFile(mine, []byte("not generated\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	p.Agents = []string{"claude"}
	syncAll(t, root, p, false)
	if got := read(t, root, "AGENTS.md"); got != "# Mine\n" {
		t.Errorf("AGENTS.md should keep the user's text only, got %q", got)
	}
	for _, gone := range []string{".github/copilot-instructions.md", ".github/instructions/intellisense-operational-testing.instructions.md", ".cursor/rules/intellisense-core.mdc"} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(gone))); !os.IsNotExist(err) {
			t.Errorf("%s should be removed", gone)
		}
	}
	if _, err := os.Stat(mine); err != nil {
		t.Error("a file without the generated line must never be removed")
	}
}

func TestSpliceRejectsBrokenMarkers(t *testing.T) {
	if _, err := Splice("x\n"+EndMarker+"\n"+BeginMarker+"\n", "b"); err == nil {
		t.Fatal("reversed markers must be an error")
	}
}

func TestOrganizationRulesReachEveryAgent(t *testing.T) {
	root, p := setup(t, "copilot", "codex")
	org := filepath.Join(root, ".intellisense", "rules", "organization", "payments.md")
	if err := os.WriteFile(org, []byte("---\nglobs: [\"billing/**\"]\n---\n# Payments rules\nUse integer cents.\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	syncAll(t, root, p, false)
	got := read(t, root, ".github/instructions/intellisense-organization-payments.instructions.md")
	if !strings.Contains(got, "applyTo: \"billing/**\"") || !strings.Contains(got, "Use integer cents.") {
		t.Errorf("org rule not scoped:\n%s", got)
	}
	if !strings.Contains(read(t, root, "AGENTS.md"), "`.intellisense/rules/organization/payments.md` — Payments rules (`billing/**`)") {
		t.Error("AGENTS.md should list the org rule")
	}
}

func TestVendoredLinksResolve(t *testing.T) {
	root, p := setup(t)
	rs, err := rules.Discover(root, p)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range rs {
		if strings.Contains(r.Body, "~/.intellisense/") {
			t.Errorf("%s still points at the Live-mode install", r.Path)
		}
		for _, m := range linkTargets(r.Body) {
			target := filepath.Join(root, filepath.FromSlash(filepath.ToSlash(filepath.Join(filepath.Dir(r.Path), m))))
			if _, err := os.Stat(target); err != nil {
				t.Errorf("%s links to %s, which is not vendored", r.Path, m)
			}
		}
	}
}

func linkTargets(md string) []string {
	var out []string
	for _, part := range strings.Split(md, "](")[1:] {
		end := strings.IndexAny(part, ")# ")
		if end <= 0 {
			continue
		}
		t := part[:end]
		if !strings.Contains(t, "://") && !strings.HasPrefix(t, "mailto:") {
			out = append(out, t)
		}
	}
	return out
}

func TestNoAgentsGeneratesNothingAndCleansUp(t *testing.T) {
	root, p := setup(t, "codex")
	syncAll(t, root, p, false)
	p.Agents = nil
	syncAll(t, root, p, false)
	for _, gone := range []string{rules.WorkflowFile, "AGENTS.md"} {
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(gone))); !os.IsNotExist(err) {
			t.Errorf("%s should be removed when no agent is enabled", gone)
		}
	}
}
