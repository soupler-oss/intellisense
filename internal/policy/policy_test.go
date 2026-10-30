package policy

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestDefaultIsValid(t *testing.T) {
	if err := Default().Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestRenderRoundTrips(t *testing.T) {
	p := Default()
	p.Stacks = []string{"go", "react"}
	p.Agents = []string{"claude", "codex"}
	p.BlockedRemotes = []string{"upstream"}
	p.Evidence.Contract.Marker = "It's a contract"
	p.Skills = []string{"plan"}
	p.Integrations.Tracker = "github"
	p.Rules.Disable = []string{"operational/proof-standards"}
	p.CustomStacks = []Stack{{Name: "elixir", Rule: "elixir-patterns.md", Globs: []string{"**/*.ex"}, Markers: []string{"mix.exs"}}}
	p.Stacks = append(p.Stacks, "elixir")
	p.Tiers = append(p.Tiers, Tier{Level: 3, Name: "critical", Requires: []string{EvidenceTask, EvidenceContract, EvidenceTest}, Rules: []Rule{{Pattern: `(^|/)ledger/`, Reason: "ledger"}}})
	if err := p.Validate(); err != nil {
		t.Fatal(err)
	}
	got, err := Parse([]byte(Render(p)))
	if err != nil {
		t.Fatalf("rendered policy does not parse: %v\n%s", err, Render(p))
	}
	if !reflect.DeepEqual(strip(got), strip(p)) {
		t.Fatalf("round trip changed the policy:\n got %+v\nwant %+v", got, p)
	}
}

// strip drops the compiled regexps, which reflect.DeepEqual cannot compare meaningfully.
func strip(p *Policy) Policy {
	c := *p
	plain := func(rs []Rule) []Rule {
		out := make([]Rule, len(rs))
		for i, r := range rs {
			out[i] = Rule{Pattern: r.Pattern, Reason: r.Reason}
		}
		return out
	}
	c.Tiers = append([]Tier(nil), c.Tiers...)
	for i := range c.Tiers {
		c.Tiers[i].Rules = plain(c.Tiers[i].Rules)
	}
	c.Evidence.TestPatterns = plain(c.Evidence.TestPatterns)
	return c
}

func TestParseOverlaysDefault(t *testing.T) {
	p, err := Parse([]byte("version: 1\nminimum_tier: 1\n"))
	if err != nil {
		t.Fatal(err)
	}
	if p.MinimumTier != 1 {
		t.Errorf("minimum_tier = %d, want 1", p.MinimumTier)
	}
	if len(p.Tiers) != len(Default().Tiers) {
		t.Errorf("keys the file omits must keep their defaults")
	}
}

func TestParseRejects(t *testing.T) {
	cases := map[string]string{
		"typo key":        "version: 1\nminimun_tier: 1\n",
		"bad tier":        "version: 1\nminimum_tier: 3\n",
		"bad version":     "version: 3\n",
		"bad regexp":      "version: 1\ntier2:\n  - pattern: '(['\n",
		"bad agent":       "version: 1\nagents: [vim]\n",
		"bad stack":       "version: 1\nstacks: [cobol]\n",
		"bad evidence":    "version: 1\nevidence:\n  tier1: [vibes]\n",
		"no trailers":     "version: 1\nevidence:\n  task_trailers: []\n",
		"bad trailer key": "version: 1\nevidence:\n  task_trailers: ['two words']\n",
		"bad secrets":     "version: 1\nsecrets: maybe\n",
	}
	for name, src := range cases {
		if _, err := Parse([]byte(src)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestLoadMissingFileIsDefault(t *testing.T) {
	p, err := Load(filepath.Join(t.TempDir(), FileName))
	if err != nil {
		t.Fatal(err)
	}
	if p.Source != "" || p.DefaultTier != 1 {
		t.Fatalf("missing file should give the default policy, got %+v", p)
	}
}

func TestLoadReportsPath(t *testing.T) {
	path := filepath.Join(t.TempDir(), FileName)
	if err := os.WriteFile(path, []byte("version: 9\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err := Load(path)
	if err == nil || !strings.Contains(err.Error(), path) {
		t.Fatalf("error should name the file, got %v", err)
	}
}

func TestDetectStacks(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{"go.mod": "module x\n", "package.json": `{"dependencies":{"react":"18"}}`} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if got := DetectStacks(dir); !reflect.DeepEqual(got, []string{"go", "react"}) {
		t.Fatalf("DetectStacks = %v", got)
	}
}

func TestLookupStackAlias(t *testing.T) {
	if s, ok := LookupStack("Laravel"); !ok || s.Name != "php" {
		t.Fatalf("laravel should resolve to php, got %+v %v", s, ok)
	}
}

func TestVersionAndUnknownKeys(t *testing.T) {
	if _, err := Parse([]byte("version: 7\n")); err == nil {
		t.Fatal("an unknown version must be rejected")
	}
	if _, err := Parse([]byte("version: 1\ntier2: []\n")); err == nil {
		t.Fatal("an unknown key must be rejected")
	}
}

func TestTierValidation(t *testing.T) {
	for name, src := range map[string]string{
		"duplicate level":   "version: 1\ntiers: [{level: 1, name: a, requires: []}, {level: 1, name: b, requires: []}]\n",
		"level too high":    "version: 1\ntiers: [{level: 10, name: a, requires: []}]\n",
		"default above":     "version: 1\ndefault_tier: 3\n",
		"unknown tracker":   "version: 1\nintegrations: {tracker: trello}\n",
		"verify no tracker": "version: 1\nevidence: {verify_tasks: true}\n",
		"bad field type":    "version: 1\nevidence: {contract: {marker: X, paths: [], fields: [{name: x, type: date}]}}\n",
	} {
		if _, err := Parse([]byte(src)); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
	p, err := Parse([]byte("version: 1\ntiers: [{level: 3, name: critical, requires: [task, test], rules: []}, {level: 0, name: routine, requires: [], rules: []}]\ndefault_tier: 3\n"))
	if err != nil {
		t.Fatal(err)
	}
	if p.MaxTier() != 3 || p.TierName(3) != "critical" || len(p.Required(2)) != 0 || !p.Requires(3, EvidenceTest) {
		t.Fatalf("custom tiers: max %d", p.MaxTier())
	}
}
