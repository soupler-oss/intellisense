package gate

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/soupler-oss/intellisense/internal/contract"
	"github.com/soupler-oss/intellisense/internal/gitx"
	"github.com/soupler-oss/intellisense/internal/policy"
	"github.com/soupler-oss/intellisense/internal/tracker"
)

// testRepo is a throwaway repository with an isolated git config.
type testRepo struct {
	t    *testing.T
	dir  string
	repo *gitx.Repo
}

func newRepo(t *testing.T) *testRepo {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("GIT_CONFIG_GLOBAL", filepath.Join(home, ".gitconfig"))
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	dir := t.TempDir()
	r := &testRepo{t: t, dir: dir}
	r.git("init", "-q", "-b", "main")
	r.git("config", "user.name", "Test")
	r.git("config", "user.email", "test@example.com")
	r.commit("initial", map[string]string{"README.md": "# x\n"})
	repo, err := gitx.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	r.repo = repo
	return r
}

func (r *testRepo) git(args ...string) string {
	r.t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = r.dir
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		r.t.Fatalf("git %v: %v\n%s", args, err, errb.String())
	}
	return strings.TrimSpace(out.String())
}

func (r *testRepo) commit(msg string, files map[string]string) string {
	r.t.Helper()
	for name, body := range files {
		path := filepath.Join(r.dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			r.t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			r.t.Fatal(err)
		}
	}
	r.git("add", "-A")
	r.git("commit", "-q", "-m", msg)
	return r.git("rev-parse", "HEAD")
}

func (r *testRepo) evaluate(base string, p *policy.Policy) *Report {
	r.t.Helper()
	rg, err := r.repo.RangeBetween(base, "HEAD")
	if err != nil {
		r.t.Fatal(err)
	}
	rep, err := Evaluate(r.repo, p, rg)
	if err != nil {
		r.t.Fatal(err)
	}
	return rep
}

func codes(rep *Report) []string {
	var out []string
	for _, f := range rep.Findings {
		out = append(out, f.Code)
	}
	return out
}

func TestTier0PassesWithoutEvidence(t *testing.T) {
	r := newRepo(t)
	base := r.git("rev-parse", "HEAD")
	r.commit("docs: typo", map[string]string{"docs/guide.md": "hello\n"})
	rep := r.evaluate(base, policy.Default())
	if rep.Tier != 0 || rep.Blocked {
		t.Fatalf("docs change should pass at Tier 0: %+v", rep)
	}
}

func TestTier2NeedsTaskAndContract(t *testing.T) {
	r := newRepo(t)
	base := r.git("rev-parse", "HEAD")
	r.commit("feat: login", map[string]string{"internal/auth/login.go": "package auth\n"})
	rep := r.evaluate(base, policy.Default())
	if rep.Tier != 2 || !rep.Blocked {
		t.Fatalf("auth change without evidence must block at Tier 2: %+v", rep)
	}
	if got := strings.Join(codes(rep), ","); got != "missing-task,missing-contract" {
		t.Fatalf("findings = %s", got)
	}
}

func TestTier2PassesWithEvidence(t *testing.T) {
	r := newRepo(t)
	base := r.git("rev-parse", "HEAD")
	r.commit("feat: login\n\nChange Contract: scope=login, risk=high, confidence=0.8\nTask: PROJ-1", map[string]string{"internal/auth/login.go": "package auth\n"})
	rep := r.evaluate(base, policy.Default())
	if rep.Blocked {
		t.Fatalf("evidence present, should pass: %v", rep.Findings)
	}
	if rep.Commits[0].Task != "PROJ-1" || !strings.HasPrefix(rep.Contract, "commit ") {
		t.Fatalf("evidence not recorded: %+v", rep)
	}
}

func TestEveryTier1CommitNeedsItsOwnTask(t *testing.T) {
	r := newRepo(t)
	base := r.git("rev-parse", "HEAD")
	r.commit("feat: a\n\nTask: PROJ-1\nChange Contract: scope=x, risk=low", map[string]string{"a.go": "package a\n"})
	second := r.commit("feat: b", map[string]string{"b.go": "package a\n"})
	r.commit("docs: c", map[string]string{"c.md": "c\n"})
	rep := r.evaluate(base, policy.Default())
	var missing []string
	for _, f := range rep.Findings {
		if f.Code == "missing-task" {
			missing = append(missing, f.Commit)
		}
	}
	if len(missing) != 1 || missing[0] != second {
		t.Fatalf("only the second commit lacks a task; got %v", missing)
	}
}

func TestContractFile(t *testing.T) {
	r := newRepo(t)
	base := r.git("rev-parse", "HEAD")
	r.commit("feat: x\n\nTask: PROJ-2", map[string]string{
		"x.go":                                 "package x\n",
		".intellisense/contracts/x-feature.md": "---\nscope: x feature\nrisk: low\nconfidence: 0.9\n---\n# Change Contract: x\n",
	})
	rep := r.evaluate(base, policy.Default())
	if rep.Blocked || rep.Contract != ".intellisense/contracts/x-feature.md" {
		t.Fatalf("contract file should satisfy the contract: %+v %v", rep.Contract, rep.Findings)
	}
}

// A contract file is validated like a commit line: a file that only mentions the marker, or an unfilled
// template, is not a contract.
func TestContractFileIsValidated(t *testing.T) {
	cases := map[string]struct{ body, want string }{
		"marker only":         {"# Change Contract\nscope: x\n", "missing-contract"},
		"unfilled template":   {contract.Template(policy.Default().Evidence.Contract), "invalid-contract"},
		"bad value":           {"---\nscope: x\nrisk: extreme\n---\n", "invalid-contract"},
		"marker line in body": {"# notes\n\nChange Contract: scope=x, risk=medium\n", ""},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			r := newRepo(t)
			base := r.git("rev-parse", "HEAD")
			r.commit("feat: x\n\nTask: PROJ-2", map[string]string{"x.go": "package x\n", ".intellisense/contracts/x.md": tc.body})
			if got := strings.Join(codes(r.evaluate(base, policy.Default())), ","); got != tc.want {
				t.Fatalf("findings = %q, want %q", got, tc.want)
			}
		})
	}
}

// A policy can add a tier above 2 and require a changed test there.
func TestCustomTierRequiresTest(t *testing.T) {
	p, err := policy.Parse([]byte(`version: 1
tiers:
  - level: 3
    name: critical
    requires: [task, contract, test]
    rules: [{pattern: '(^|/)ledger/', reason: ledger}]
  - level: 1
    name: standard
    requires: [task]
    rules: []
  - level: 0
    name: routine
    requires: []
    rules: [{pattern: '_test\.go$', reason: tests}]
`))
	if err != nil {
		t.Fatal(err)
	}
	r := newRepo(t)
	base := r.git("rev-parse", "HEAD")
	r.commit("feat: post\n\nTask: PROJ-9\nChange Contract: scope=post, risk=high", map[string]string{"ledger/post.go": "package ledger\n"})
	rep := r.evaluate(base, p)
	if rep.Tier != 3 || rep.TierName != "critical" || strings.Join(codes(rep), ",") != "missing-test" {
		t.Fatalf("tier %d %q findings %v", rep.Tier, rep.TierName, codes(rep))
	}
	r.commit("test: post\n\nTask: PROJ-9", map[string]string{"ledger/post_test.go": "package ledger\n"})
	if rep := r.evaluate(base, p); rep.Blocked {
		t.Fatalf("a changed test satisfies the tier: %v", rep.Findings)
	}
}

func TestVerifyTasks(t *testing.T) {
	saved := tracker.Verify
	defer func() { tracker.Verify = saved }()
	tracker.Verify = func(_ context.Context, tr, ref, _ string) (tracker.Result, string) {
		if tr != "github" {
			t.Errorf("tracker = %q", tr)
		}
		if ref == "#1" {
			return tracker.Found, ""
		}
		return tracker.NotFound, "no such issue"
	}
	p := policy.Default()
	p.Integrations.Tracker = "github"
	p.Evidence.VerifyTasks = true
	r := newRepo(t)
	base := r.git("rev-parse", "HEAD")
	r.commit("feat: a\n\nRefs: #1\nChange Contract: scope=a, risk=low", map[string]string{"a.go": "package a\n"})
	if rep := r.evaluate(base, p); rep.Blocked {
		t.Fatalf("an existing issue passes: %v", rep.Findings)
	}
	r.commit("feat: b\n\nRefs: #404", map[string]string{"b.go": "package b\n"})
	if got := strings.Join(codes(r.evaluate(base, p)), ","); got != "task-not-found" {
		t.Fatalf("findings = %s", got)
	}
}

func TestInvalidContract(t *testing.T) {
	r := newRepo(t)
	base := r.git("rev-parse", "HEAD")
	r.commit("feat: x\n\nTask: PROJ-3\nChange Contract: risk=extreme", map[string]string{"x.go": "package x\n"})
	if got := strings.Join(codes(r.evaluate(base, policy.Default())), ","); got != "invalid-contract" {
		t.Fatalf("findings = %s", got)
	}
}

func TestFastLaneCommentOnlyIsTier0(t *testing.T) {
	r := newRepo(t)
	r.commit("feat: x\n\nTask: PROJ-4\nChange Contract: scope=x, risk=low", map[string]string{"x.go": "package x\n\n// old note\nfunc F() {}\n"})
	base := r.git("rev-parse", "HEAD")
	r.commit("docs: comment", map[string]string{"x.go": "package x\n\n// new note\nfunc F() {}\n"})
	rep := r.evaluate(base, policy.Default())
	if rep.Tier != 0 || rep.Blocked {
		t.Fatalf("comment-only edit should be Tier 0: tier %d %v", rep.Tier, rep.Findings)
	}
}

func TestSecrets(t *testing.T) {
	r := newRepo(t)
	base := r.git("rev-parse", "HEAD")
	r.commit("docs: notes", map[string]string{"docs/notes.md": "api_key = \"abcd1234efgh5678\"\nfixture password: \"notreal12345\" # intellisense:allow-secret\n"})
	p := policy.Default()
	rep := r.evaluate(base, p)
	if len(rep.Findings) != 1 || rep.Findings[0].Line != 1 || rep.Blocked {
		t.Fatalf("one warning on line 1 expected: %+v", rep.Findings)
	}
	p.Secrets = policy.SecretsBlock
	if rep := r.evaluate(base, p); !rep.Blocked {
		t.Fatal("secrets: block must block")
	}
}

func TestPolicyFromBaseCannotBeLoosenedByTheChange(t *testing.T) {
	r := newRepo(t)
	r.commit("chore: adopt", map[string]string{policy.FileName: "version: 1\nminimum_tier: 1\n"})
	base := r.git("rev-parse", "HEAD")
	r.commit("chore: loosen", map[string]string{policy.FileName: "version: 1\nminimum_tier: 0\nevidence:\n  tier1: []\n  tier2: []\n", "x.go": "package x\n"})
	rg, _ := r.repo.RangeBetween(base, "HEAD")
	p, err := LoadPolicy(r.repo, rg, true)
	if err != nil {
		t.Fatal(err)
	}
	if p.MinimumTier != 1 {
		t.Fatalf("the base policy must judge the change, got minimum_tier %d from %s", p.MinimumTier, p.Source)
	}
	if rep, _ := Evaluate(r.repo, p, rg); !rep.Blocked || rep.Tier != 2 {
		t.Fatalf("editing the policy is Tier 2 and needs evidence: %+v", rep)
	}
}

func TestPushRangeNewBranchWithoutRemote(t *testing.T) {
	r := newRepo(t)
	head := r.commit("feat: x", map[string]string{"x.go": "package x\n"})
	rg, ok, err := PushRange(r.repo, "origin", PushedRef{"refs/heads/main", head, "refs/heads/main", gitx.ZeroSHA})
	if err != nil || !ok {
		t.Fatal(ok, err)
	}
	if rg.From != gitx.EmptyTree {
		t.Fatalf("no remote: the whole history is new, got from=%s", rg.From)
	}
	if _, ok, _ := PushRange(r.repo, "origin", PushedRef{"(delete)", gitx.ZeroSHA, "refs/heads/x", head}); ok {
		t.Fatal("a delete has nothing to check")
	}
}

func TestTrailerAndContractParsing(t *testing.T) {
	msg := "subject\n\nbody text: not a trailer key\ntask: abc-1\nchange contract: risk=low\n"
	if got := Trailer(msg, []string{"Task"}); got != "abc-1" {
		t.Errorf("Trailer = %q", got)
	}
	if body, ok := contract.Line(msg, "Change Contract"); !ok || body != "risk=low" {
		t.Errorf("contract.Line = %q %v", body, ok)
	}
	if _, ok := contract.Line("Change Contracts are great", "Change Contract"); ok {
		t.Error("a sentence is not a contract line")
	}
}

func TestGitHubFormat(t *testing.T) {
	r := newRepo(t)
	base := r.git("rev-parse", "HEAD")
	r.commit("feat: login", map[string]string{"internal/auth/login.go": "package auth\n"})
	rep := r.evaluate(base, policy.Default())
	out := filepath.Join(t.TempDir(), "out")
	sum := filepath.Join(t.TempDir(), "summary")
	t.Setenv("GITHUB_OUTPUT", out)
	t.Setenv("GITHUB_STEP_SUMMARY", sum)
	var b bytes.Buffer
	if err := Write(&b, rep, FormatGitHub); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(b.String(), "::error title=intellisense%3A missing-task::") {
		t.Errorf("annotation missing:\n%s", b.String())
	}
	if data, _ := os.ReadFile(out); string(data) != "tier=2\nblocked=true\n" {
		t.Errorf("GITHUB_OUTPUT = %q", data)
	}
	if data, _ := os.ReadFile(sum); !strings.Contains(string(data), "`internal/auth/login.go` | auth/identity") {
		t.Errorf("summary missing trigger:\n%s", data)
	}
}

func TestHistoryBeforeAdoptionNeedsNoTrailers(t *testing.T) {
	r := newRepo(t) // "initial" commit, no policy, no trailer
	r.commit("feat: before adoption", map[string]string{"x.go": "package x\n"})
	r.commit("chore: adopt\n\nTask: PROJ-1\nChange Contract: scope=x, risk=low", map[string]string{policy.FileName: "version: 1\n"})
	r.commit("feat: after adoption", map[string]string{"y.go": "package x\n"})
	rg, err := r.repo.RangeNotOnRemotes("HEAD")
	if err != nil {
		t.Fatal(err)
	}
	rep, err := Evaluate(r.repo, policy.Default(), rg)
	if err != nil {
		t.Fatal(err)
	}
	var missing []string
	for _, f := range rep.Findings {
		if f.Code == "missing-task" {
			missing = append(missing, f.Commit)
		}
	}
	if len(missing) != 1 || missing[0] != rep.Commits[3].SHA {
		t.Fatalf("only the commit after adoption needs a trailer; got %v", missing)
	}
	if !rep.Commits[1].PreAdoption || rep.Commits[2].PreAdoption {
		t.Fatalf("pre-adoption flags wrong: %+v", rep.Commits)
	}
}

func TestDeletingThePolicyDoesNotExemptLaterCommits(t *testing.T) {
	r := newRepo(t)
	r.commit("chore: adopt\n\nTask: PROJ-1\nChange Contract: scope=x, risk=low", map[string]string{policy.FileName: "version: 1\n"})
	base := r.git("rev-parse", "HEAD")
	r.git("rm", "-q", policy.FileName)
	r.git("commit", "-q", "-m", "chore: drop policy")
	r.commit("feat: sneaky", map[string]string{"z.go": "package x\n"})
	rep := r.evaluate(base, policy.Default())
	n := 0
	for _, f := range rep.Findings {
		if f.Code == "missing-task" {
			n++
		}
	}
	if n != 2 || rep.Tier != 2 {
		t.Fatalf("both commits after a policy deletion need trailers and the change is Tier 2: tier %d, %d missing", rep.Tier, n)
	}
}
