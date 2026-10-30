package contract

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/soupler-oss/intellisense/internal/policy"
)

func TestValidateUsesThePolicyFields(t *testing.T) {
	spec := policy.Default().Evidence.Contract
	cases := map[string]string{
		"scope=x, risk=low, confidence=0.9":          "",
		"scope=x, risk=HIGH":                         "",
		"risk=low":                                   "scope is required",
		"scope=x, risk=extreme":                      "risk must be low, medium, high",
		"scope=x, risk=low, confidence=2":            "confidence must be from 0 to 1",
		"scope=x, risk=low, files_affected=three":    "files_affected must be a whole number",
		"scope=x, risk=low, note=anything goes here": "",
	}
	for line, want := range cases {
		err := Validate(ParseLine(line), spec)
		if (want == "") != (err == nil) || (err != nil && !strings.Contains(err.Error(), want)) {
			t.Errorf("%q: got %v, want %q", line, err, want)
		}
	}
}

func TestCustomFields(t *testing.T) {
	p, err := policy.Parse([]byte(`version: 1
evidence:
  contract:
    marker: 'Change Contract'
    paths: ['.intellisense/contracts/']
    fields:
      - name: rollback
        required: true
      - name: reviewers
        type: integer
        min: 2
`))
	if err != nil {
		t.Fatal(err)
	}
	spec := p.Evidence.Contract
	if err := Validate(ParseLine("rollback=revert, reviewers=1"), spec); err == nil || !strings.Contains(err.Error(), "reviewers must be at least 2") {
		t.Fatalf("got %v", err)
	}
	if err := Validate(ParseLine("rollback=revert"), spec); err != nil {
		t.Fatal(err)
	}
}

func TestParseMarkdown(t *testing.T) {
	f, found, err := ParseMarkdown([]byte("---\nscope: refunds\nrisk: high\nconfidence: 0.7\n---\n# x\n"), "Change Contract")
	if err != nil || !found || f["scope"] != "refunds" || f["confidence"] != "0.7" {
		t.Fatalf("front matter: %v %v %v", f, found, err)
	}
	if _, found, _ := ParseMarkdown([]byte("# Change Contract\njust prose\n"), "Change Contract"); found {
		t.Fatal("a heading that mentions the marker is not a contract")
	}
}

func TestNewWritesTheTemplateAndItFailsUntilFilled(t *testing.T) {
	root := t.TempDir()
	p := policy.Default()
	rel, err := New(root, p, "Refund API!", time.Date(2026, 10, 30, 0, 0, 0, 0, time.UTC))
	if err != nil || rel != ".intellisense/contracts/2026-10-30-refund-api.md" {
		t.Fatalf("New = %q %v", rel, err)
	}
	data, _ := os.ReadFile(filepath.Join(root, rel))
	fields, found, err := ParseMarkdown(data, p.Evidence.Contract.Marker)
	if err != nil || !found {
		t.Fatalf("template must parse: %v", err)
	}
	if err := Validate(fields, p.Evidence.Contract); err == nil {
		t.Fatal("an unfilled template must not validate")
	}
	if _, err := New(root, p, "Refund API!", time.Date(2026, 10, 30, 0, 0, 0, 0, time.UTC)); err == nil {
		t.Fatal("New must not overwrite an existing contract")
	}
}

func TestFrontMatterAndSet(t *testing.T) {
	src := []byte("---\nscope: refunds\nrisk: high\nfiles_affected: [a.go, b.go]\nestimated_lines: 40\nfinancial_impact: true\nstate: approved\n---\n# Body\n\ntext\n")
	fm, err := FrontMatter(src)
	if err != nil {
		t.Fatal(err)
	}
	if files, ok := fm["files_affected"].([]any); !ok || len(files) != 2 || fm["estimated_lines"] != 40 || fm["financial_impact"] != true {
		t.Fatalf("types lost: %#v", fm)
	}
	out, err := Set(src, "state", "active")
	if err != nil {
		t.Fatal(err)
	}
	out, err = Set(out, "approval_received_at", "2026-10-30T10:00:00Z")
	if err != nil {
		t.Fatal(err)
	}
	fm, _ = FrontMatter(out)
	if fm["state"] != "active" || fm["scope"] != "refunds" || !strings.HasSuffix(string(out), "# Body\n\ntext\n") {
		t.Fatalf("set lost data:\n%s", out)
	}
	if strings.Index(string(out), "scope:") > strings.Index(string(out), "state:") {
		t.Fatalf("set reordered keys:\n%s", out)
	}
}

// A contract written by Live mode's /contract (requirement, risk_level) is valid evidence for the gate.
func TestLiveFieldNamesCount(t *testing.T) {
	f, found, err := ParseMarkdown([]byte("---\nrequirement: fix refunds\nrisk_level: medium\nstate: approved\n---\n"), "Change Contract")
	if err != nil || !found {
		t.Fatal(err)
	}
	if err := Validate(f, policy.Default().Evidence.Contract); err != nil {
		t.Fatalf("live contract rejected: %v", err)
	}
}
