package tier

import (
	"strings"
	"testing"

	"github.com/soupler-oss/intellisense/internal/policy"
)

func TestPathTiers(t *testing.T) {
	p := policy.Default()
	cases := map[string]int{
		// Tier 2: auth, money, migrations, secrets, the policy itself.
		"internal/auth/handler.go":          2,
		"src/oauth/client.ts":               2,
		"pkg/jwt.go":                        2,
		"services/payments/refund.go":       2,
		"app/Billing/Invoice.php":           2,
		"accounts/balance.go":               2,
		"db/migrations/0001_init.sql":       2,
		"app/migrations/0002_add_index.py":  2,
		"config/secrets.yaml":               2,
		".intellisense.yml":                 2,
		".intellisense/rules/baseline/x.md": 2,
		// Component-anchored: these only contain the words.
		"docs/authors/index.md":  0,
		"internal/author.go":     1,
		"cmd/accountant/main.go": 1,
		// Tier 1: CI, containers, infra, dependencies, agent instructions.
		".github/workflows/ci.yml": 1,
		"Dockerfile":               1,
		"deploy/values.yaml":       1,
		"main.tf":                  1,
		"go.mod":                   1,
		"requirements.txt":         1,
		"AGENTS.md":                1,
		"CLAUDE.md":                1,
		".github/instructions/go.instructions.md": 1,
		".cursor/rules/x.mdc":                     1,
		// Tier 0: docs and tests by name.
		"README.md":                  0,
		"docs/guide/setup.go":        0,
		"internal/gate/gate_test.go": 0,
		"tests/test_tiers.py":        0,
		"web/src/App.test.tsx":       0,
		"src/test/java/FooTest.java": 0,
		// Default: ordinary code is Tier 1, and "test" inside a name is not a test.
		"internal/gate/gate.go":        1,
		"internal/attestation/sign.go": 1,
		"web/src/latest.ts":            1,
	}
	for path, want := range cases {
		if got := Path(p, path); got.Tier != want {
			t.Errorf("%s: tier %d (%s %q), want %d", path, got.Tier, got.By, got.Pattern, want)
		}
	}
}

func TestClassifyTakesMaxAndPolicyFloor(t *testing.T) {
	p := policy.Default()
	r := Classify(p, []string{"README.md", "internal/x.go", "internal/auth/y.go"}, nil)
	if r.Tier != 2 || len(r.Triggers()) != 1 || r.Triggers()[0].Reason != "auth/identity" {
		t.Fatalf("got %+v", r)
	}
	p.MinimumTier = 1
	r = Classify(p, []string{"README.md"}, nil)
	if r.Tier != 1 || r.PathTier != 0 || r.PolicyTier != 1 {
		t.Fatalf("policy floor not applied: %+v", r)
	}
}

func TestFastLane(t *testing.T) {
	p := policy.Default()
	comment := "--- a/x.go\n+++ b/x.go\n@@ -1,2 +1,2 @@\n-// old words\n+// new words\n"
	code := "--- a/x.go\n+++ b/x.go\n@@ -1 +1 @@\n-return 1\n+return 2\n"
	disable := "--- a/x.go\n+++ b/x.go\n@@ -1 +1 @@\n-check()\n+// check() disabled for now\n"
	diffs := map[string]string{"a.go": comment, "b.go": code, "c.go": disable, "auth/d.go": comment}
	r := Classify(p, []string{"a.go", "b.go", "c.go", "auth/d.go"}, func(path string) (string, bool) {
		d, ok := diffs[path]
		return d, ok
	})
	want := map[string]struct {
		tier int
		by   string
	}{"a.go": {0, ByFast}, "b.go": {1, ByDefault}, "c.go": {1, ByDefault}, "auth/d.go": {2, ByTier2}}
	for _, f := range r.Files {
		if w := want[f.Path]; f.Tier != w.tier || f.By != w.by {
			t.Errorf("%s: got tier %d by %s, want %d by %s", f.Path, f.Tier, f.By, w.tier, w.by)
		}
	}

	p.FastLane = false
	r = Classify(p, []string{"a.go"}, func(string) (string, bool) { return comment, true })
	if r.Tier != 1 {
		t.Errorf("fast_lane: false must keep the default tier, got %d", r.Tier)
	}
}

// A comment that silences a linter, type checker, scanner or coverage tool is not a harmless comment edit.
func TestFastLaneSilencingDirectives(t *testing.T) {
	p := policy.Default()
	for _, line := range []string{
		"// nolint:gosec", "// NOLINT", "# noqa: E501", "# nosec B105", "// #nosec G101", "// @ts-ignore",
		"// @ts-expect-error", "// @ts-nocheck", "# type: ignore", "/* istanbul ignore next */", "/* c8 ignore next */",
		"# pragma: no cover", "// eslint-disable-next-line no-eval", "# pylint: disable=broad-except",
		"# rubocop:disable Security/Eval", "// swiftlint:disable force_cast", "// NOSONAR", "// noinspection SqlInjection",
		"// phpcs:ignore", "// @phpstan-ignore-next-line", "// @psalm-suppress TaintedSql", "// nosemgrep",
		"// gitleaks:allow", "// intellisense:allow-secret", "// deno-lint-ignore no-explicit-any",
		"// biome-ignore lint/security", "//lint:ignore SA1019 reason",
	} {
		path := "x.go"
		if strings.HasPrefix(line, "#") {
			path = "x.py"
		}
		diff := "--- a/" + path + "\n+++ b/" + path + "\n@@ -1 +1 @@\n+" + line + "\n"
		if !CommentOnly(path, diff) {
			t.Fatalf("%q should be a comment-only diff in %s", line, path)
		}
		r := Classify(p, []string{path}, func(string) (string, bool) { return diff, true })
		if r.Tier != 1 || r.Files[0].By != ByDefault {
			t.Errorf("%q: got tier %d by %s, want 1 by %s", line, r.Tier, r.Files[0].By, ByDefault)
		}
	}
	// An ordinary comment still takes the fast lane.
	r := Classify(p, []string{"x.go"}, func(string) (string, bool) {
		return "--- a/x.go\n+++ b/x.go\n@@ -1 +1 @@\n+// Greet returns a friendly greeting.\n", true
	})
	if r.Tier != 0 {
		t.Errorf("an ordinary comment should be Tier 0, got %d", r.Tier)
	}
}

func TestCommentOnly(t *testing.T) {
	cases := []struct {
		path, diff string
		want       bool
	}{
		{"x.py", "+# note\n- # gone\n+\n", true},
		{"x.py", "+x = 1\n", false},
		{"x.html", "+<!-- note -->\n", true},
		{"x.html", "+<div>\n", false},
		{"x.ts", "+/* one line */\n", true},
		{"x.ts", "+/* starts a block\n", false},
		{"x.bin", "+// looks like a comment\n", false},
		{"x.go", "", false},
		{"x.go", " context only\n", false},
	}
	for _, c := range cases {
		if got := CommentOnly(c.path, c.diff); got != c.want {
			t.Errorf("CommentOnly(%s, %q) = %v, want %v", c.path, c.diff, got, c.want)
		}
	}
}
