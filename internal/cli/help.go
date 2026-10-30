package cli

import (
	"fmt"
	"strings"
)

// command is one entry in `intellisense help`.
type command struct {
	name     string
	summary  string // one line, for the command list
	usage    string
	about    string // what it does, in plain words
	examples []example
	hidden   bool // used by scripts, not listed
}

type example struct{ cmd, what string }

var commands = []command{
	{name: "init", summary: "set up this repository: policy, rules, agent instructions, push hook",
		usage: "intellisense init [--stack go,react] [--agents claude,codex,copilot,cursor] [--tracker github] [--skills plan,tdd] [--minimum-tier N] [--ci] [--no-hook] [--chain] [--force] [--yes]",
		about: "Writes .intellisense.yml (the policy), copies the coding rules for your stack into .intellisense/rules/, " +
			"writes each AI agent's instruction file and installs the pre-push hook. In a terminal it asks a few " +
			"questions first; flags answer them, and --yes accepts the defaults. Nothing outside the repository changes.",
		examples: []example{
			{"intellisense init", "answer a few questions, then set everything up"},
			{"intellisense init --yes --ci", "accept the defaults and add the GitHub check"},
			{"intellisense init --stack go --agents claude,copilot --tracker github", "decide everything with flags"},
		}},
	{name: "classify", summary: "show the risk tier of your changes, and why",
		usage: "intellisense classify [--base REF] [--head REF] [--format text|json] [--tier-only] [PATH...]",
		about: "Works out the tier of each changed file from the rules in .intellisense.yml, and the evidence the " +
			"change will need at push time. With no arguments it looks at your uncommitted changes.",
		examples: []example{
			{"intellisense classify", "your uncommitted changes"},
			{"intellisense classify src/auth/login.go", "one file"},
			{"intellisense classify --base origin/main", "everything on this branch"},
		}},
	{name: "gate", summary: "check that a range of commits carries the evidence its tier needs",
		usage: "intellisense gate [--base REF] [--head REF] [--format text|json|github] [--policy base|working]",
		about: "Runs the same check as the pre-push hook and CI: each commit at a tier that needs a task has a task " +
			"trailer, the change has a valid contract if its tier needs one, and no likely secret was added. " +
			"It exits 1 and prints the fix when something is missing.",
		examples: []example{
			{"intellisense gate", "this branch against the remote's default branch"},
			{"intellisense gate --base main --format json", "machine-readable"},
		}},
	{name: "contract", summary: "write or check a change contract",
		usage: "intellisense contract new \"<title>\" | check [FILE] | fields | show FILE | set FILE key=value...",
		about: "A change contract states what a change does and how risky it is. `new` writes one as a Markdown file " +
			"from the template (fill in the front matter and commit it with the change); `check` validates a file " +
			"or, with no file, your latest commit message; `fields` lists what the policy requires; `show` prints a " +
			"contract file's front matter as JSON and `set` changes one of its keys (Live mode uses both).",
		examples: []example{
			{"intellisense contract new \"refund API\"", "write .intellisense/contracts/<date>-refund-api.md"},
			{"intellisense contract check .intellisense/contracts/2026-10-30-refund-api.md", "is it complete?"},
			{"intellisense contract fields", "which fields are required"},
		}},
	{name: "sync", summary: "regenerate every agent's instructions from the policy and rules",
		usage: "intellisense sync [--check]",
		about: "Writes CLAUDE.md, AGENTS.md, Copilot and Cursor instructions (and any skills) from .intellisense.yml " +
			"and .intellisense/rules/. Your own text in CLAUDE.md and AGENTS.md is kept: only the block between the " +
			"intellisense markers is rewritten. --check reports drift without writing (CI uses it).",
		examples: []example{
			{"intellisense sync", "after editing the policy or a rule"},
			{"intellisense sync --check", "fail if the generated files are stale"},
		}},
	{name: "check", summary: "CI: the gate plus the instructions-drift check",
		usage:    "intellisense check --base REF --head REF [--format github] [--no-sync]",
		about:    "What the GitHub Action runs on a pull request: `gate` for the range, then `sync --check`.",
		examples: []example{{"intellisense check --base origin/main --head HEAD", "what CI will say"}}},
	{name: "rules", summary: "list the rules, or update them to this version",
		usage: "intellisense rules list | update [--force]",
		about: "`list` shows every rule and the files it applies to. `update` refreshes the built-in rules to this " +
			"version of intellisense; a rule file you edited is kept (it is your override), unless you pass --force. " +
			"Your own rules in .intellisense/rules/organization/ are never touched. To switch a rule off, add it to " +
			"rules.disable in .intellisense.yml.",
		examples: []example{
			{"intellisense rules list", "what each agent is told"},
			{"intellisense rules update", "pick up new rules, keep your edits"},
		}},
	{name: "skills", summary: "list the Claude Code skills you can add to this repository",
		usage: "intellisense skills list",
		about: "Skills are slash commands for Claude Code (/plan, /tdd …). List them here, add the ones you want to " +
			"skills: in .intellisense.yml, and run `intellisense sync`.",
		examples: []example{{"intellisense skills list", "what is available"}}},
	{name: "policy", summary: "show, check or query the policy",
		usage: "intellisense policy show | validate | get KEY",
		about: "`show` prints the policy in effect (defaults filled in). `validate` checks it. `get` prints one value, for scripts: minimum_tier, default_tier, " +
			"max_tier, tracker, code_intel, task_trailers, contract_marker.",
		examples: []example{
			{"intellisense policy show", "every setting, with defaults"},
			{"intellisense policy validate", "check the policy file"},
		}},
	{name: "hook", summary: "install, remove or inspect the pre-push hook",
		usage: "intellisense hook install [--chain] | uninstall | status",
		about: "The hook runs the gate on every `git push`. An existing hook is never overwritten: --chain keeps it " +
			"and runs it first.",
		examples: []example{{"intellisense hook install", "check every push"}, {"intellisense hook status", "is it there?"}}},
	{name: "doctor", summary: "check the setup, and fix what it can",
		usage: "intellisense doctor [--fix]",
		about: "Checks git, the policy, the rules, the generated instructions, the hook and the CI workflow. --fix " +
			"installs a missing hook, regenerates stale instructions, restores missing rules and adds the CI workflow.",
		examples: []example{{"intellisense doctor", "what is missing?"}, {"intellisense doctor --fix", "fix it"}}},
	{name: "live", summary: "install Live mode: live checks inside Claude Code on this machine",
		usage: "intellisense live install [--tracker beads|github|jira|linear|none] [--code-intel code-review-graph|none] [--no-heartbeat] [--yes] | status | uninstall | templates check|update [--force]",
		about: "Live mode adds what only Claude Code's hooks can do: it classifies each prompt, stops Claude editing a " +
			"risky file before a contract is approved, and adds the slash-command skills and architect agents, for " +
			"every repository on this machine. It needs bash (macOS, Linux or WSL). Beads and code-review-graph are " +
			"optional: install them only if you choose them. `templates check|update` refreshes the workflow files " +
			"setup-repos.sh copied into a repository, keeping files the team edited.",
		examples: []example{
			{"intellisense live install", "answer a few questions, then install"},
			{"intellisense live install --tracker github --code-intel none --yes", "no questions"},
			{"intellisense live status", "what is installed"},
			{"intellisense live templates update", "refresh this repository's Live-mode workflow files"},
		}},
	{name: "version", summary: "print the version", usage: "intellisense version"},
	{name: "help", summary: "help for a command", usage: "intellisense help [COMMAND]"},
	{name: "check-comment-only", hidden: true, usage: "intellisense check-comment-only [PATH] < DIFF",
		about: "Exits 0 when the unified diff on stdin only changes comments in its file's language (used by Live mode)."},
	{name: "check-phrase", hidden: true, usage: "intellisense check-phrase < TEXT",
		about: "Exits 0 when the text on stdin contains a phrase that disables or bypasses something (used by Live mode)."},
}

func findCommand(name string) (command, bool) {
	for _, c := range commands {
		if c.name == name {
			return c, true
		}
	}
	return command{}, false
}

func usageText() string {
	var b strings.Builder
	b.WriteString("intellisense — risk tiers and evidence gates for AI-assisted development\n\n")
	b.WriteString("Commands:\n")
	for _, c := range commands {
		if !c.hidden {
			fmt.Fprintf(&b, "  %-10s %s\n", c.name, c.summary)
		}
	}
	b.WriteString("\nStart here:  intellisense init        (in a git repository)\n")
	b.WriteString("Then:        intellisense classify    (what tier is my change?)\n")
	b.WriteString("More:        intellisense help <command>\n\n")
	b.WriteString("Exit codes: 0 passed, 1 blocked or out of date, 2 error.\n")
	b.WriteString("Docs: https://github.com/soupler-oss/intellisense\n")
	return b.String()
}

func helpText(c command) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s\n\nUsage:\n  %s\n", c.summary, c.usage)
	if c.summary == "" {
		b.Reset()
		fmt.Fprintf(&b, "Usage:\n  %s\n", c.usage)
	}
	if c.about != "" {
		fmt.Fprintf(&b, "\n%s\n", wrap(c.about, 100))
	}
	if len(c.examples) > 0 {
		b.WriteString("\nExamples:\n")
		width := 0
		for _, e := range c.examples {
			width = max(width, len(e.cmd))
		}
		for _, e := range c.examples {
			fmt.Fprintf(&b, "  %-*s   %s\n", width, e.cmd, e.what)
		}
	}
	return b.String()
}

func wrap(s string, width int) string {
	var lines []string
	line := ""
	for _, word := range strings.Fields(s) {
		if line != "" && len(line)+1+len(word) > width {
			lines = append(lines, line)
			line = word
			continue
		}
		if line != "" {
			line += " "
		}
		line += word
	}
	if line != "" {
		lines = append(lines, line)
	}
	return strings.Join(lines, "\n")
}

func (c *cmd) help(args []string) int {
	if len(args) == 0 {
		fmt.Fprint(c.out, usageText())
		return ExitOK
	}
	entry, ok := findCommand(args[0])
	if !ok {
		fmt.Fprintf(c.err, "intellisense: no command %q\n\n%s", args[0], usageText())
		return ExitError
	}
	fmt.Fprint(c.out, helpText(entry))
	return ExitOK
}

// next prints what to run after a command: pairs of command and reason.
func (c *cmd) next(steps ...string) {
	if len(steps) == 0 {
		return
	}
	fmt.Fprintln(c.out, "\nNext:")
	width := 0
	for i := 0; i+1 < len(steps); i += 2 {
		width = max(width, len(steps[i]))
	}
	for i := 0; i+1 < len(steps); i += 2 {
		fmt.Fprintf(c.out, "  %-*s   %s\n", width, steps[i], steps[i+1])
	}
}
