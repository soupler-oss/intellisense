package adapters

import (
	"fmt"
	"sort"
	"strings"

	"github.com/soupler-oss/intellisense/internal/contract"
	"github.com/soupler-oss/intellisense/internal/policy"
	"github.com/soupler-oss/intellisense/internal/tier"
)

// Workflow renders .intellisense/rules/workflow.md: the policy, in words an agent can follow.
func Workflow(p *policy.Policy) string {
	var b strings.Builder
	w := func(format string, a ...any) { fmt.Fprintf(&b, format, a...) }

	w("# Change workflow\n\n")
	w("Every change in this repository has a risk tier, worked out from the files it touches (`%s`). ", policy.FileName)
	w("The pre-push hook and CI block a change that lacks the evidence its tier needs, so check the tier ")
	w("before you start: `intellisense classify` (working tree) or `intellisense classify <path>...`.\n\n")

	w("## Tiers\n\n")
	w("| Tier | What | Needs |\n|---|---|---|\n")
	for _, t := range p.Tiers {
		what := reasons(t.Rules, "")
		if t.Level == p.DefaultTier && t.Level > 0 {
			what = joinText(what, "any other file that matches no rule")
		}
		if t.Level == 0 {
			what = joinText(what, "edits that only change comments")
		}
		w("| %d — %s | %s | %s |\n", t.Level, t.Name, orText(what, "files matching its rules"), needs(p, t.Level))
	}
	w("\n")
	if p.MinimumTier > 0 {
		w("This repository sets `minimum_tier: %d`: every change is at least Tier %d.\n\n", p.MinimumTier, p.MinimumTier)
	}
	w("A comment-only edit stays at its tier when the comment disables or bypasses something (%s).\n\n",
		quoteList(tier.DangerousPhrases[:4]))

	w("## How to work\n\n")
	w("1. **Plan.** Say what changes, which files, and the risk. For Tier 1+, write the change contract before the code.\n")
	w("2. **Test first.** Add or change a test that fails without your change; then make it pass.\n")
	w("3. **Change only what the plan says.** Keep unrelated edits out of the commit.\n")
	w("4. **Verify.** Build, run the tests and linters, and quote their real output. Never claim a result you did not see.\n")
	w("5. **Review your own diff** against `baseline/security.md` before you commit.\n\n")

	w("## Evidence\n\n")
	if p.AnyRequires(policy.EvidenceTask) {
		w("**Task trailer** — each Tier %d+ commit carries its own (one commit's trailer never covers another):\n\n", p.LowestRequiring(policy.EvidenceTask))
		w("```\n%s: PROJ-123\n```\n\n", p.Evidence.TaskTrailers[0])
		if len(p.Evidence.TaskTrailers) > 1 {
			w("Accepted keys: %s.\n\n", quoteList(p.Evidence.TaskTrailers))
		}
	}
	if p.AnyRequires(policy.EvidenceContract) {
		spec := p.Evidence.Contract
		w("**Change contract** — once per change, as a commit-message line:\n\n")
		w("```\n%s\n```\n\n", contract.Example(spec))
		if len(spec.Paths) > 0 {
			w("or as a Markdown file under `%s` with the fields as front matter: `intellisense contract new \"<title>\"` writes one.\n\n", spec.Paths[0])
		}
		if lines := contract.Describe(spec); len(lines) > 0 {
			w("Fields: %s.\n\n", strings.Join(lines, "; "))
		}
	}
	if p.AnyRequires(policy.EvidenceTest) {
		w("**Test** — a change at Tier %d+ adds or changes a test.\n\n", p.LowestRequiring(policy.EvidenceTest))
	}
	w("## Never\n\n")
	w("- Skip the gate (`git push --no-verify`) or edit `%s` to get a change through. A wrong tier is fixed in the policy, as its own Tier 2 change.\n", policy.FileName)
	w("- Commit secrets, tokens or credentials, even in tests.\n")
	w("- Weaken, skip or delete a test to make it pass.\n\n")

	w("## Rule references\n\n")
	w("The rules mention Claude Code skills. In any agent, do the step the skill names: `/plan` is step 1, ")
	w("`/tdd` is step 2, `/code-review` is step 5, `/verify` is step 4 and `/security-scan` is the security review in step 5.\n")
	return b.String()
}

func reasons(rs []policy.Rule, fallback string) string {
	seen := map[string]bool{}
	var out []string
	for _, r := range rs {
		if r.Reason != "" && !seen[r.Reason] {
			seen[r.Reason] = true
			out = append(out, r.Reason)
		}
	}
	if len(out) == 0 {
		return fallback
	}
	return strings.Join(out, ", ")
}

func needs(p *policy.Policy, t int) string {
	req := append([]string(nil), p.Required(t)...)
	if len(req) == 0 {
		return "nothing extra"
	}
	sort.Strings(req)
	names := map[string]string{policy.EvidenceTask: "task trailer on each commit", policy.EvidenceContract: "change contract", policy.EvidenceTest: "a changed test"}
	for i, k := range req {
		req[i] = names[k]
	}
	return strings.Join(req, " + ")
}

func quoteList(list []string) string {
	q := make([]string, len(list))
	for i, s := range list {
		q[i] = "`" + s + "`"
	}
	return strings.Join(q, ", ")
}

func joinText(a, b string) string {
	if a == "" {
		return b
	}
	return a + ", " + b
}

func orText(s, fallback string) string {
	if s == "" {
		return fallback
	}
	return s
}
