package cli

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	intellisense "github.com/soupler-oss/intellisense"
	"github.com/soupler-oss/intellisense/internal/adapters"
	"github.com/soupler-oss/intellisense/internal/contract"
	"github.com/soupler-oss/intellisense/internal/gitx"
	"github.com/soupler-oss/intellisense/internal/hook"
	"github.com/soupler-oss/intellisense/internal/policy"
	"github.com/soupler-oss/intellisense/internal/skills"
	"github.com/soupler-oss/intellisense/internal/tier"
)

// ── status: what `intellisense` with no arguments prints ────────────────────────

func (c *cmd) status(args []string) int {
	fs := c.flags("status")
	dir := fs.String("dir", ".", "repository")
	if err := parseArgs(fs, args); err != nil {
		return ExitError
	}
	fmt.Fprintf(c.out, "intellisense %s — risk tiers and evidence gates for AI-assisted development\n\n", intellisense.Version())
	repo, err := c.repo(*dir)
	if err != nil {
		fmt.Fprintln(c.out, "You are not inside a git repository.")
		c.next("cd <your repository>", "intellisense works one repository at a time",
			"intellisense init", "then set it up there",
			"intellisense live install", "or add live checks to Claude Code on this machine",
			"intellisense help", "every command, with examples")
		return ExitOK
	}
	if _, err := os.Stat(policyPath(repo)); err != nil {
		fmt.Fprintf(c.out, "%s is not set up yet (no %s).\n", repo.Root, policy.FileName)
		c.next("intellisense init", "set it up: a few questions, then policy, rules, agent instructions and the push hook",
			"intellisense help init", "what init does, and its flags")
		return ExitOK
	}
	p, err := policy.Load(policyPath(repo))
	if err != nil {
		fmt.Fprintf(c.out, "✗ %v\n", err)
		c.next("intellisense policy validate", "see every problem in the policy")
		return ExitBlocked
	}
	fmt.Fprintf(c.out, "Repository  %s\n", repo.Root)
	fmt.Fprintf(c.out, "Policy      %s (%d tiers; stacks: %s; agents: %s; tracker: %s)\n", policy.FileName, len(p.Tiers), orNone(p.Stacks), orNone(p.Agents), p.Tracker())

	var steps []string
	if installed, _, err := hook.Installed(repo); err != nil || !installed {
		fmt.Fprintln(c.out, "Push hook   ✗ not installed")
		steps = append(steps, "intellisense hook install", "check every push")
	} else {
		fmt.Fprintln(c.out, "Push hook   ✓ installed")
	}
	if changes, err := c.syncChanges(repo, p, true); err == nil {
		if drift := adapters.Drift(changes); len(drift) > 0 {
			fmt.Fprintf(c.out, "Agents      ✗ %d instruction file(s) out of date\n", len(drift))
			steps = append(steps, "intellisense sync", "regenerate the agent instructions")
		} else {
			fmt.Fprintf(c.out, "Agents      ✓ %d instruction files in sync\n", len(changes))
		}
	}
	files, diff, err := workingChanges(repo)
	if err == nil && len(files) > 0 {
		res := tier.Classify(p, files, diff)
		fmt.Fprintf(c.out, "Changes     %d file(s), Tier %d — %s", len(files), res.Tier, p.TierName(res.Tier))
		if req := p.Required(res.Tier); len(req) > 0 {
			fmt.Fprintf(c.out, " (needs %s)", strings.Join(req, " + "))
		}
		fmt.Fprintln(c.out)
		steps = append(steps, "intellisense classify", "why each file has its tier")
	} else {
		fmt.Fprintln(c.out, "Changes     none")
	}
	steps = append(steps, "intellisense gate", "check this branch the way the push hook will", "intellisense help", "every command")
	c.next(steps...)
	return ExitOK
}

// ── contract ─────────────────────────────────────────────────────────────────

func (c *cmd) contract(args []string) int {
	if len(args) == 0 {
		return c.help([]string{"contract"})
	}
	fs := c.flags("contract " + args[0])
	dir := fs.String("dir", ".", "repository")
	if err := parseArgs(fs, args[1:]); err != nil {
		return ExitError
	}
	repo, err := c.repo(*dir)
	if err != nil {
		return c.fail(err)
	}
	p, err := policy.Load(policyPath(repo))
	if err != nil {
		return c.fail(err)
	}
	spec := p.Evidence.Contract
	switch args[0] {
	case "new":
		title := strings.TrimSpace(strings.Join(fs.Args(), " "))
		if title == "" {
			return c.fail(errors.New(`give the change a title: intellisense contract new "refund API"`))
		}
		rel, err := contract.New(repo.Root, p, title, time.Now())
		if err != nil {
			return c.fail(err)
		}
		fmt.Fprintf(c.out, "✓ wrote %s\n", rel)
		c.next("$EDITOR "+rel, "fill in the front matter ("+strings.Join(requiredFields(spec), ", ")+" are required)",
			"intellisense contract check "+rel, "check it is complete",
			"git add "+rel, "commit it with the change")
	case "check":
		if fs.NArg() == 0 {
			return c.checkCommitContract(repo, spec)
		}
		failed := false
		for _, file := range fs.Args() {
			data, err := os.ReadFile(file)
			if err != nil {
				return c.fail(err)
			}
			fields, found, err := contract.ParseMarkdown(data, spec.Marker)
			switch {
			case !found:
				fmt.Fprintf(c.out, "✗ %s has no contract: no front matter and no \"%s:\" line\n", file, spec.Marker)
				failed = true
			case err != nil:
				fmt.Fprintf(c.out, "✗ %s: %v\n", file, err)
				failed = true
			default:
				if err := contract.Validate(fields, spec); err != nil {
					fmt.Fprintf(c.out, "✗ %s: %v\n", file, err)
					failed = true
				} else {
					fmt.Fprintf(c.out, "✓ %s is a valid contract\n", file)
				}
			}
		}
		if failed {
			c.next("intellisense contract fields", "what each field must hold")
			return ExitBlocked
		}
	case "show":
		// The contract's front matter as JSON, types intact. Live mode's validator and gate read it this way.
		if fs.NArg() != 1 {
			return c.fail(errors.New("usage: intellisense contract show FILE"))
		}
		data, err := os.ReadFile(fs.Arg(0))
		if err != nil {
			return c.fail(err)
		}
		fm, err := contract.FrontMatter(data)
		if err != nil {
			return c.fail(fmt.Errorf("%s: %v", fs.Arg(0), err))
		}
		return c.writeJSON(fm)
	case "set":
		// set FILE key=value... — update front-matter keys in place (Live mode flips state to active).
		if fs.NArg() < 2 {
			return c.fail(errors.New("usage: intellisense contract set FILE key=value [key=value...]"))
		}
		data, err := os.ReadFile(fs.Arg(0))
		if err != nil {
			return c.fail(err)
		}
		for _, kv := range fs.Args()[1:] {
			k, v, ok := strings.Cut(kv, "=")
			if !ok || strings.TrimSpace(k) == "" {
				return c.fail(fmt.Errorf("%q is not key=value", kv))
			}
			if data, err = contract.Set(data, strings.TrimSpace(k), v); err != nil {
				return c.fail(fmt.Errorf("%s: %v", fs.Arg(0), err))
			}
		}
		if err := os.WriteFile(fs.Arg(0), data, 0o644); err != nil {
			return c.fail(err)
		}
		return ExitOK
	case "fields":
		for _, line := range contract.Describe(spec) {
			fmt.Fprintf(c.out, "  %s\n", line)
		}
		fmt.Fprintf(c.out, "\nAs a commit line:  %s\n", contract.Example(spec))
		if len(spec.Paths) > 0 {
			fmt.Fprintf(c.out, "As a file:         intellisense contract new \"<title>\"   (writes under %s)\n", spec.Paths[0])
		}
		fmt.Fprintf(c.out, "Change the fields in %s under evidence.contract.fields.\n", policy.FileName)
	default:
		return c.fail(fmt.Errorf("unknown contract command %q (new, check, fields, show or set)", args[0]))
	}
	return ExitOK
}

func (c *cmd) checkCommitContract(repo *gitx.Repo, spec policy.Contract) int {
	msg, err := repo.Message("HEAD")
	if err != nil {
		return c.fail(errors.New("no commit to check; pass a contract file: intellisense contract check FILE"))
	}
	body, ok := contract.Line(msg, spec.Marker)
	if !ok {
		fmt.Fprintf(c.out, "✗ the last commit has no \"%s:\" line\n", spec.Marker)
		c.next("intellisense contract new \"<title>\"", "write the contract as a file instead",
			"git commit --amend", "or add: "+contract.Example(spec))
		return ExitBlocked
	}
	if err := contract.Validate(contract.ParseLine(body), spec); err != nil {
		fmt.Fprintf(c.out, "✗ the contract in the last commit is invalid: %v\n", err)
		return ExitBlocked
	}
	fmt.Fprintln(c.out, "✓ the last commit carries a valid contract")
	return ExitOK
}

func requiredFields(spec policy.Contract) []string {
	var out []string
	for _, f := range spec.Fields {
		if f.Required {
			out = append(out, f.Name)
		}
	}
	if len(out) == 0 {
		return []string{"none"}
	}
	return out
}

// ── policy ───────────────────────────────────────────────────────────────────

func (c *cmd) policy(args []string) int {
	if len(args) == 0 {
		return c.help([]string{"policy"})
	}
	fs := c.flags("policy " + args[0])
	dir := fs.String("dir", ".", "repository")
	if err := parseArgs(fs, args[1:]); err != nil {
		return ExitError
	}
	path := policyPath(c.looseRepo(*dir))
	switch args[0] {
	case "show":
		p, err := policy.Load(path)
		if err != nil {
			return c.fail(err)
		}
		if p.Source == "" {
			fmt.Fprintf(c.out, "# no %s: this is the built-in default\n", policy.FileName)
		}
		fmt.Fprint(c.out, policy.Render(p))
	case "validate":
		if _, err := os.Stat(path); err != nil {
			return c.fail(fmt.Errorf("no %s; run `intellisense init`", policy.FileName))
		}
		if _, err := policy.Load(path); err != nil {
			fmt.Fprintf(c.out, "✗ %v\n", err)
			return ExitBlocked
		}
		fmt.Fprintf(c.out, "✓ %s is valid\n", policy.FileName)
	case "get":
		if fs.NArg() != 1 {
			return c.fail(errors.New("usage: intellisense policy get KEY"))
		}
		p, err := policy.Load(path)
		if err != nil {
			return c.fail(err)
		}
		v, ok := policyValue(p, fs.Arg(0))
		if !ok {
			return c.fail(fmt.Errorf("unknown key %q (minimum_tier, default_tier, max_tier, tracker, code_intel, task_trailers, contract_marker, contract_paths, rules_disable)", fs.Arg(0)))
		}
		fmt.Fprintln(c.out, v)
	default:
		return c.fail(fmt.Errorf("unknown policy command %q (show, validate or get)", args[0]))
	}
	return ExitOK
}

func policyValue(p *policy.Policy, key string) (string, bool) {
	switch key {
	case "minimum_tier":
		return fmt.Sprint(p.MinimumTier), true
	case "default_tier":
		return fmt.Sprint(p.DefaultTier), true
	case "max_tier":
		return fmt.Sprint(p.MaxTier()), true
	case "tracker":
		return p.Tracker(), true
	case "code_intel":
		if p.Integrations.CodeIntel == "" {
			return "none", true
		}
		return p.Integrations.CodeIntel, true
	case "task_trailers":
		return strings.Join(p.Evidence.TaskTrailers, " "), true
	case "contract_marker":
		return p.Evidence.Contract.Marker, true
	case "contract_paths":
		return strings.Join(p.Evidence.Contract.Paths, " "), true
	case "rules_disable":
		return strings.Join(p.Rules.Disable, " "), true
	}
	return "", false
}

// ── skills ───────────────────────────────────────────────────────────────────

func (c *cmd) skills(args []string) int {
	if len(args) == 0 || args[0] != "list" {
		return c.help([]string{"skills"})
	}
	list, err := skills.List()
	if err != nil {
		return c.fail(err)
	}
	fmt.Fprintln(c.out, "Portable (add to skills: in .intellisense.yml, then `intellisense sync`):")
	for _, s := range list {
		if s.Portable {
			fmt.Fprintf(c.out, "  %-18s %s\n", s.Name, s.Description)
		}
	}
	fmt.Fprintln(c.out, "\nLive mode only (`intellisense live install`):")
	for _, s := range list {
		if !s.Portable {
			fmt.Fprintf(c.out, "  %-18s %s\n", s.Name, s.Description)
		}
	}
	return ExitOK
}

// ── doctor --fix helpers ─────────────────────────────────────────────────────

func ciWorkflowPath(root string) string {
	return filepath.Join(root, ".github", "workflows", "intellisense.yml")
}
