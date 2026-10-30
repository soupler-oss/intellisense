package cli

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	intellisense "github.com/soupler-oss/intellisense"
	"github.com/soupler-oss/intellisense/internal/adapters"
	"github.com/soupler-oss/intellisense/internal/hook"
	"github.com/soupler-oss/intellisense/internal/policy"
	"github.com/soupler-oss/intellisense/internal/rules"
)

func (c *cmd) writeJSON(v any) int {
	enc := json.NewEncoder(c.out)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return c.fail(err)
	}
	return ExitOK
}

// doctor checks that a repository's governance is complete and current; with --fix it repairs what it can.
func (c *cmd) doctor(args []string) int {
	fs := c.flags("doctor")
	dir := fs.String("dir", ".", "repository")
	fix := fs.Bool("fix", false, "install a missing hook, regenerate stale instructions, restore missing rules, add the CI workflow")
	if err := parseArgs(fs, args); err != nil {
		return ExitError
	}
	failed := false
	var steps []string
	ok := func(format string, a ...any) { fmt.Fprintf(c.out, "  ✓ "+format+"\n", a...) }
	warn := func(format string, a ...any) { fmt.Fprintf(c.out, "  ! "+format+"\n", a...) }
	bad := func(format string, a ...any) { failed = true; fmt.Fprintf(c.out, "  ✗ "+format+"\n", a...) }
	fixed := func(format string, a ...any) { fmt.Fprintf(c.out, "  ✓ fixed: "+format+"\n", a...) }

	fmt.Fprintf(c.out, "intellisense %s\n", intellisense.Version())
	if out, err := exec.Command("git", "--version").Output(); err != nil {
		bad("git is not installed")
		return ExitBlocked
	} else {
		ok("%s", strings.TrimSpace(string(out)))
	}
	repo, err := c.repo(*dir)
	if err != nil {
		bad("%v", err)
		c.next("cd <your repository>", "run doctor inside a git repository")
		return ExitBlocked
	}
	ok("repository %s", repo.Root)

	if _, err := os.Stat(policyPath(repo)); err != nil {
		bad("no %s", policy.FileName)
		c.next("intellisense init", "set this repository up")
		return ExitBlocked
	}
	p, err := policy.Load(policyPath(repo))
	if err != nil {
		bad("%v", err)
		c.next("intellisense policy validate", "see every problem in the policy")
		return ExitBlocked
	}
	ok("%s is valid (version %d; %d tiers; stacks: %s; agents: %s; tracker: %s)", policy.FileName, p.Version, len(p.Tiers), orNone(p.Stacks), orNone(p.Agents), p.Tracker())

	if len(p.Agents) == 0 {
		warn("no agents enabled: no instructions are generated (the gate still runs)")
	} else if missing := c.missingRules(repo.Root, p); len(missing) > 0 {
		if *fix {
			if _, err := rules.Vendor(repo.Root, p, rules.Missing); err != nil {
				bad("restoring rules: %v", err)
			} else {
				fixed("restored %d missing rule file(s)", len(missing))
			}
		} else {
			for _, m := range missing {
				bad("missing %s", m)
			}
			steps = append(steps, "intellisense doctor --fix", "restore the missing rules")
		}
	} else {
		ok("rules present for baseline and stacks")
	}
	if len(p.Skills) > 0 && !p.HasAgent("claude") {
		warn("skills are listed but the claude agent is off, so they are not installed")
	}
	if p.Evidence.VerifyTasks {
		ok("task references are verified against %s", p.Tracker())
	}

	changes, err := c.syncChanges(repo, p, true)
	switch {
	case err != nil:
		bad("%v", err)
	case len(adapters.Drift(changes)) > 0 && *fix:
		if code := c.runSync(repo, p, false, true); code != ExitOK {
			failed = true
		} else {
			fixed("regenerated agent instructions")
		}
	case len(adapters.Drift(changes)) > 0:
		bad("%d generated file(s) out of date", len(adapters.Drift(changes)))
		steps = append(steps, "intellisense sync", "regenerate them")
	default:
		ok("agent instructions are in sync (%d files)", len(changes))
	}

	if installed, path, err := hook.Installed(repo); err != nil || !installed {
		if *fix {
			if path, err := hook.Install(repo, executable(), false); err != nil && !errors.Is(err, hook.ErrAlreadyGated) {
				warn("could not install the pre-push hook: %v", err)
				steps = append(steps, "intellisense hook install --chain", "keep the existing hook and run the gate after it")
			} else {
				fixed("installed pre-push hook (%s)", path)
			}
		} else {
			warn("pre-push hook not installed (CI still enforces the gate)")
			steps = append(steps, "intellisense hook install", "check every push locally")
		}
	} else {
		ok("pre-push hook installed (%s)", path)
	}
	if hasCIGate(repo.Root) {
		ok("CI runs the intellisense gate")
	} else if *fix {
		if err := writeWorkflow(repo.Root); err != nil {
			bad("writing the CI workflow: %v", err)
		} else {
			fixed("wrote %s", ".github/workflows/intellisense.yml")
		}
	} else {
		warn("no workflow runs the gate")
		steps = append(steps, "intellisense doctor --fix", "add .github/workflows/intellisense.yml")
	}
	if len(steps) > 0 {
		c.next(dedupePairs(steps)...)
	} else if !failed {
		c.next("intellisense classify", "check the tier of your next change")
	}
	if failed {
		return ExitBlocked
	}
	return ExitOK
}

// missingRules lists the baseline and stack rule files that should be vendored but are not.
func (c *cmd) missingRules(root string, p *policy.Policy) []string {
	var out []string
	check := func(rel string) {
		if p.RuleDisabled(rules.ID(rel)) {
			return
		}
		if _, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel))); err != nil {
			out = append(out, rel)
		}
	}
	for _, name := range []string{"baseline/security.md", "baseline/reasoning-integrity.md"} {
		check(rules.Dir + "/" + name)
	}
	for _, s := range p.Stacks {
		if st, ok := p.Stack(s); ok {
			check(rules.Dir + "/language-specific/" + st.Rule)
		}
	}
	return out
}

func hasCIGate(root string) bool {
	files, _ := filepath.Glob(filepath.Join(root, ".github", "workflows", "*.y*ml"))
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err == nil && strings.Contains(string(data), "intellisense") {
			return true
		}
	}
	return false
}
