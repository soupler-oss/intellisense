// Package gate decides whether a range of commits carries the evidence its risk tier requires.
//
// What it checks:
//   - each evidence kind the change's tier requires is checked (see checks): a task trailer on every commit
//     at such a tier (one commit's trailer never covers the others), a valid change contract, a changed test;
//   - likely secrets in added lines warn or block, as the policy says.
//
// Merge commits are skipped: their content is checked through the commits they merge.
package gate

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/soupler-oss/intellisense/internal/contract"
	"github.com/soupler-oss/intellisense/internal/gitx"
	"github.com/soupler-oss/intellisense/internal/policy"
	"github.com/soupler-oss/intellisense/internal/tier"
	"github.com/soupler-oss/intellisense/internal/tracker"
)

// Finding levels.
const (
	LevelError   = "error"
	LevelWarning = "warning"
)

// Finding is one problem the gate reports.
type Finding struct {
	Level   string `json:"level"`
	Code    string `json:"code"`
	Message string `json:"message"`
	Fix     string `json:"fix,omitempty"`
	File    string `json:"file,omitempty"`
	Line    int    `json:"line,omitempty"`
	Commit  string `json:"commit,omitempty"`
}

// Commit is one evaluated commit.
type Commit struct {
	SHA     string `json:"sha"`
	Subject string `json:"subject"`
	Tier    int    `json:"tier"`
	Task    string `json:"task,omitempty"`
	// PreAdoption marks a commit made before the policy file existed: it needs no task trailer.
	PreAdoption bool `json:"pre_adoption,omitempty"`
}

// Report is the gate's verdict on a range.
type Report struct {
	From           string      `json:"from"`
	Head           string      `json:"head"`
	PolicySource   string      `json:"policy_source"`
	Tier           int         `json:"tier"`
	TierName       string      `json:"tier_name"`
	Required       []string    `json:"required"`
	Blocked        bool        `json:"blocked"`
	Classification tier.Result `json:"classification"`
	Commits        []Commit    `json:"commits"`
	Contract       string      `json:"contract,omitempty"`
	// Tests is a changed test file, when a tier requires `test`.
	Tests    string    `json:"tests,omitempty"`
	Findings []Finding `json:"findings"`

	policy *policy.Policy
}

// Policy is the policy the report was evaluated against.
func (r *Report) Policy() *policy.Policy { return r.policy }

func (r *Report) add(f Finding) {
	r.Findings = append(r.Findings, f)
	if f.Level == LevelError {
		r.Blocked = true
	}
}

// Evaluate runs the gate over a range.
func Evaluate(repo *gitx.Repo, p *policy.Policy, rg gitx.Range) (*Report, error) {
	rep := &Report{From: rg.From, Head: rg.Head, PolicySource: p.Source, TierName: p.TierName(0), Findings: []Finding{}, Commits: []Commit{}, policy: p}
	if rg.From == rg.Head {
		rep.Classification = tier.Result{PolicyTier: p.MinimumTier, Files: []tier.File{}}
		rep.Required = []string{}
		return rep, nil
	}

	files, err := repo.ChangedFiles(rg)
	if err != nil {
		return nil, err
	}
	rep.Classification = tier.Classify(p, files, func(path string) (string, bool) {
		d, err := repo.FileDiff(rg, path)
		return d, err == nil
	})
	rep.Tier = rep.Classification.Tier
	rep.TierName = p.TierName(rep.Tier)
	rep.Required = append([]string{}, p.Required(rep.Tier)...)

	shas, err := repo.Commits(rg)
	if err != nil {
		return nil, err
	}
	// History from before the repository adopted intellisense cannot carry trailers: when the range contains
	// the adoption (the base has no policy file and a commit in the range adds it), the commits before that
	// one are exempt from the per-commit task trailer. When the base already has the policy (every ordinary
	// pull request), or no commit has it (the gate runs on the default policy), nothing is exempt.
	adoptedAt := 0
	if rg.From == gitx.EmptyTree || !hasPolicy(repo, rg.From) {
		for i, sha := range shas {
			if hasPolicy(repo, sha) {
				adoptedAt = i
				break
			}
		}
	}
	ev := &evaluation{repo: repo, p: p, rg: rg, files: files, rep: rep}
	for i, sha := range shas {
		c, msg, err := evaluateCommit(repo, p, sha)
		if err != nil {
			return nil, err
		}
		c.PreAdoption = i < adoptedAt
		ev.messages = append(ev.messages, msg)
		rep.Commits = append(rep.Commits, c)
	}
	for _, kind := range policy.KnownEvidence {
		if p.AnyRequires(kind) {
			checks[kind](ev)
		}
	}
	if p.Secrets != policy.SecretsOff {
		if err := scanSecrets(repo, p, rg, rep); err != nil {
			return nil, err
		}
	}
	return rep, nil
}

// evaluation is what an evidence check reads.
type evaluation struct {
	repo     *gitx.Repo
	p        *policy.Policy
	rg       gitx.Range
	files    []string
	messages []string
	rep      *Report
}

// checks are the evidence kinds, by name. Adding a kind is a policy.KnownEvidence entry and a function here.
var checks = map[string]func(*evaluation){
	policy.EvidenceTask:     checkTasks,
	policy.EvidenceContract: checkContract,
	policy.EvidenceTest:     checkTests,
}

// checkTasks: every commit whose own changes are at a tier that requires `task` carries its own trailer.
func checkTasks(ev *evaluation) {
	p, rep := ev.p, ev.rep
	for _, c := range rep.Commits {
		if c.PreAdoption || !p.Requires(c.Tier, policy.EvidenceTask) {
			continue
		}
		if c.Task == "" {
			rep.add(Finding{
				Level:   LevelError,
				Code:    "missing-task",
				Commit:  c.SHA,
				Message: fmt.Sprintf("commit %s %q is Tier %d and has no task trailer", short(c.SHA), c.Subject, c.Tier),
				Fix: fmt.Sprintf("add a trailer line such as \"%s: PROJ-123\" to that commit's message (accepted keys: %s), "+
					"then `git commit --amend` (or `git rebase -i` for older commits)",
					p.Evidence.TaskTrailers[0], strings.Join(p.Evidence.TaskTrailers, ", ")),
			})
			continue
		}
		if p.Evidence.VerifyTasks {
			verifyTask(ev, c)
		}
	}
}

func verifyTask(ev *evaluation, c Commit) {
	tr := ev.p.Tracker()
	for _, id := range tracker.IDs(c.Task) {
		switch res, why := tracker.Verify(context.Background(), tr, id, ev.repo.Root); res {
		case tracker.NotFound:
			ev.rep.add(Finding{Level: LevelError, Code: "task-not-found", Commit: c.SHA,
				Message: fmt.Sprintf("commit %s refers to %s, which %s does not have (%s)", short(c.SHA), id, tr, why),
				Fix:     "use the reference of a task that exists in " + tr + ", then `git commit --amend`"})
		case tracker.Unverified:
			ev.rep.add(Finding{Level: LevelWarning, Code: "task-unverified", Commit: c.SHA,
				Message: fmt.Sprintf("could not check %s in %s: %s", id, tr, why)})
		}
	}
}

// checkContract: a change at a tier that requires `contract` carries one valid contract, in a commit message
// or in a changed .md file under a contract path.
func checkContract(ev *evaluation) {
	p, rep := ev.p, ev.rep
	if !p.Requires(rep.Tier, policy.EvidenceContract) {
		return
	}
	spec := p.Evidence.Contract
	for i, msg := range ev.messages {
		body, ok := contract.Line(msg, spec.Marker)
		if !ok {
			continue
		}
		if err := contract.Validate(contract.ParseLine(body), spec); err != nil {
			rep.add(Finding{Level: LevelError, Code: "invalid-contract", Commit: rep.Commits[i].SHA,
				Message: fmt.Sprintf("the change contract in commit %s is invalid: %v", short(rep.Commits[i].SHA), err),
				Fix:     contractFix(p)})
			return
		}
		rep.Contract = "commit " + short(rep.Commits[i].SHA)
		return
	}
	for _, f := range ev.files {
		if !strings.HasSuffix(strings.ToLower(f), ".md") || !underAny(f, spec.Paths) {
			continue
		}
		data, err := ev.repo.Show(ev.rg.Head, f)
		if err != nil {
			continue // deleted in this range
		}
		fields, found, err := contract.ParseMarkdown(data, spec.Marker)
		if !found {
			continue
		}
		if err == nil {
			err = contract.Validate(fields, spec)
		}
		if err != nil {
			rep.add(Finding{Level: LevelError, Code: "invalid-contract", File: f,
				Message: fmt.Sprintf("the change contract in %s is invalid: %v", f, err),
				Fix:     "fill in the fields in its front matter (`intellisense contract check " + f + "` shows what is wrong)"})
			return
		}
		rep.Contract = f
		return
	}
	rep.add(Finding{Level: LevelError, Code: "missing-contract",
		Message: fmt.Sprintf("this change is Tier %d and has no change contract", rep.Tier),
		Fix:     contractFix(p)})
}

func contractFix(p *policy.Policy) string {
	spec := p.Evidence.Contract
	fix := fmt.Sprintf("add a line \"%s\" to a commit message", contract.Example(spec))
	if len(spec.Paths) > 0 {
		fix += fmt.Sprintf(", or run `intellisense contract new \"<title>\"` and commit the file it writes under %s", spec.Paths[0])
	}
	return fix
}

// checkTests: a change at a tier that requires `test` adds or changes at least one test file.
func checkTests(ev *evaluation) {
	p, rep := ev.p, ev.rep
	if !p.Requires(rep.Tier, policy.EvidenceTest) {
		return
	}
	for _, f := range ev.files {
		for _, r := range p.Evidence.TestPatterns {
			if r.Match(f) {
				rep.Tests = f
				return
			}
		}
	}
	rep.add(Finding{Level: LevelError, Code: "missing-test",
		Message: fmt.Sprintf("this change is Tier %d and changes no test", rep.Tier),
		Fix:     "add or update a test that fails without this change (paths that count: evidence.test_patterns)"})
}

func evaluateCommit(repo *gitx.Repo, p *policy.Policy, sha string) (Commit, string, error) {
	files, err := repo.CommitFiles(sha)
	if err != nil {
		return Commit{}, "", err
	}
	msg, err := repo.Message(sha)
	if err != nil {
		return Commit{}, "", err
	}
	cls := tier.Classify(p, files, func(path string) (string, bool) {
		d, err := repo.CommitFileDiff(sha, path)
		return d, err == nil
	})
	return Commit{SHA: sha, Subject: repo.Subject(sha), Tier: cls.Tier, Task: Trailer(msg, p.Evidence.TaskTrailers)}, msg, nil
}

func hasPolicy(repo *gitx.Repo, rev string) bool {
	_, err := repo.Git("cat-file", "-e", rev+":"+policy.FileName)
	return err == nil
}

// Trailer returns the value of the first "Key: value" line whose key is one of keys (case-insensitive).
func Trailer(msg string, keys []string) string {
	for _, line := range strings.Split(msg, "\n") {
		k, v, ok := strings.Cut(strings.TrimSpace(line), ":")
		if !ok {
			continue
		}
		v = strings.TrimSpace(v)
		if v == "" {
			continue
		}
		for _, key := range keys {
			if strings.EqualFold(strings.TrimSpace(k), key) {
				return v
			}
		}
	}
	return ""
}

func underAny(path string, dirs []string) bool {
	for _, d := range dirs {
		d = strings.TrimSuffix(filepath.ToSlash(d), "/") + "/"
		if strings.HasPrefix(path, d) {
			return true
		}
	}
	return false
}

// AllowSecretMarker on a line suppresses the secret check for that line.
const AllowSecretMarker = "intellisense:allow-secret"

var secretPatterns = []struct {
	name string
	re   *regexp.Regexp
}{
	{"private key", regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----`)},
	{"AWS access key", regexp.MustCompile(`\bAKIA[0-9A-Z]{16}\b`)},
	{"GitHub token", regexp.MustCompile(`\bgh[pousr]_[A-Za-z0-9]{36,}\b`)},
	{"Slack token", regexp.MustCompile(`\bxox[baprs]-[A-Za-z0-9-]{10,}`)},
	{"hard-coded credential", regexp.MustCompile(`(?i)\b(api[_-]?key|secret|passw(or)?d|access[_-]?token|auth[_-]?token|private[_-]?key)\b["']?\s*[:=]\s*["'][^"'\s]{8,}["']`)},
}

func scanSecrets(repo *gitx.Repo, p *policy.Policy, rg gitx.Range, rep *Report) error {
	diff, err := repo.Diff(rg)
	if err != nil {
		return err
	}
	level := LevelWarning
	if p.Secrets == policy.SecretsBlock {
		level = LevelError
	}
	for _, l := range gitx.AddedLines(diff) {
		if strings.Contains(l.Text, AllowSecretMarker) {
			continue
		}
		for _, sp := range secretPatterns {
			if sp.re.MatchString(l.Text) {
				rep.add(Finding{Level: level, Code: "possible-secret", File: l.File, Line: l.Line,
					Message: fmt.Sprintf("possible %s added at %s:%d", sp.name, l.File, l.Line),
					Fix:     "move it to a secret store or environment variable; if it is a test fixture, add the comment " + AllowSecretMarker + " to the line"})
				break
			}
		}
	}
	return nil
}

// LoadPolicy picks the policy a range is judged by. With fromBase, it is the policy at the range's base, so
// a change cannot loosen the rules it is checked against; a repository adopting intellisense in this very
// change has no base policy, so the head's committed policy is used. Without fromBase it is the working
// tree's file. Either way a missing file means the default policy.
func LoadPolicy(repo *gitx.Repo, rg gitx.Range, fromBase bool) (*policy.Policy, error) {
	if !fromBase {
		return policy.Load(filepath.Join(repo.Root, policy.FileName))
	}
	for _, rev := range []string{rg.From, rg.Head} {
		if rev == "" || rev == gitx.EmptyTree {
			continue
		}
		data, err := repo.Show(rev, policy.FileName)
		if err != nil {
			continue
		}
		p, err := policy.Parse(data)
		if err != nil {
			return nil, fmt.Errorf("%s at %s: %w", policy.FileName, short(rev), err)
		}
		p.Source = policy.FileName + " @ " + short(rev)
		return p, nil
	}
	if _, err := os.Stat(filepath.Join(repo.Root, policy.FileName)); err == nil {
		// Present in the working tree but not committed in the range: still judge by the default.
		p := policy.Default()
		p.Source = "default (" + policy.FileName + " is not committed)"
		return p, nil
	}
	return policy.Default(), nil
}

// Sorted returns findings errors-first, then by file and line.
func Sorted(fs []Finding) []Finding {
	out := append([]Finding(nil), fs...)
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Level != out[j].Level {
			return out[i].Level == LevelError
		}
		if out[i].File != out[j].File {
			return out[i].File < out[j].File
		}
		return out[i].Line < out[j].Line
	})
	return out
}

func short(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	return sha
}
