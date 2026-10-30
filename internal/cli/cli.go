// Package cli is the intellisense command line.
package cli

import (
	"bufio"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	intellisense "github.com/soupler-oss/intellisense"
	"github.com/soupler-oss/intellisense/internal/adapters"
	"github.com/soupler-oss/intellisense/internal/gate"
	"github.com/soupler-oss/intellisense/internal/gitx"
	"github.com/soupler-oss/intellisense/internal/hook"
	"github.com/soupler-oss/intellisense/internal/policy"
	"github.com/soupler-oss/intellisense/internal/rules"
	"github.com/soupler-oss/intellisense/internal/skills"
	"github.com/soupler-oss/intellisense/internal/tier"
)

// Exit codes.
const (
	ExitOK      = 0
	ExitBlocked = 1 // the gate blocked, or generated files drifted
	ExitError   = 2 // bad usage or an error running the command
)

// Run executes one command and returns its exit code.
func Run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	c := &cmd{stdin: stdin, out: stdout, err: stderr}
	if len(args) == 0 {
		return c.status(nil)
	}
	run := map[string]func([]string) int{
		"init": c.init, "sync": c.sync, "classify": c.classify, "gate": c.gate, "check": c.check,
		"hook": c.hook, "rules": c.rules, "doctor": c.doctor, "contract": c.contract, "policy": c.policy,
		"skills": c.skills, "live": c.live, "status": c.status, "check-phrase": c.checkPhrase, "check-comment-only": c.checkCommentOnly,
		"version": func([]string) int { fmt.Fprintf(stdout, "intellisense %s\n", intellisense.Version()); return ExitOK },
		"help":    c.help,
	}
	name := args[0]
	switch name {
	case "-h", "--help":
		name = "help"
	case "-v", "--version":
		name = "version"
	}
	f, ok := run[name]
	if !ok {
		fmt.Fprintf(stderr, "intellisense: unknown command %q\n\n%s", args[0], usageText())
		return ExitError
	}
	if len(args) > 1 && (args[1] == "-h" || args[1] == "--help") && name != "help" {
		return c.help([]string{name})
	}
	return f(args[1:])
}

type cmd struct {
	stdin    io.Reader
	out, err io.Writer
	in       *bufio.Reader
}

func (c *cmd) fail(err error) int {
	fmt.Fprintf(c.err, "intellisense: %v\n", err)
	return ExitError
}

func (c *cmd) flags(name string) *flag.FlagSet {
	fs := flag.NewFlagSet("intellisense "+name, flag.ContinueOnError)
	fs.SetOutput(c.err)
	fs.Usage = func() {
		if entry, ok := findCommand(strings.Fields(name)[0]); ok {
			fmt.Fprint(c.err, helpText(entry))
		}
	}
	return fs
}

// parseArgs parses flags wherever they appear among the arguments (`contract new "x" --dir .` works like
// `contract new --dir . "x"`); everything after "--" is positional.
func parseArgs(fs *flag.FlagSet, args []string) error {
	var pos []string
	for {
		if err := fs.Parse(args); err != nil {
			return err
		}
		args = fs.Args()
		if len(args) == 0 {
			break
		}
		if args[0] == "--" {
			pos = append(pos, args[1:]...)
			break
		}
		pos, args = append(pos, args[0]), args[1:]
	}
	return fs.Parse(append([]string{"--"}, pos...))
}

func (c *cmd) repo(dir string) (*gitx.Repo, error) {
	if dir == "" {
		dir = "."
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		return nil, err
	}
	return gitx.Open(abs)
}

func policyPath(repo *gitx.Repo) string { return filepath.Join(repo.Root, policy.FileName) }

// looseRepo is the repository at dir, or — for commands that only need paths and the policy (classify PATH…,
// policy) — the directory itself when it is not inside a git repository, so Live mode's hooks work in a plain
// folder too.
func (c *cmd) looseRepo(dir string) *gitx.Repo {
	if repo, err := c.repo(dir); err == nil {
		return repo
	}
	abs, err := filepath.Abs(dir)
	if err != nil {
		abs = dir
	}
	return &gitx.Repo{Root: abs}
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// interactive reports whether questions can be asked: stdin is a terminal and CI is not set.
func (c *cmd) interactive() bool {
	if os.Getenv("CI") != "" || os.Getenv("INTELLISENSE_NONINTERACTIVE") != "" {
		return false
	}
	f, ok := c.stdin.(*os.File)
	if !ok {
		return false
	}
	st, err := f.Stat()
	return err == nil && st.Mode()&os.ModeCharDevice != 0
}

// ask prints a question with a default and returns the answer (the default on an empty line or EOF).
func (c *cmd) ask(question, def string) string {
	if c.in == nil {
		c.in = bufio.NewReader(c.stdin)
	}
	if def != "" {
		fmt.Fprintf(c.out, "? %s [%s]: ", question, def)
	} else {
		fmt.Fprintf(c.out, "? %s: ", question)
	}
	line, err := c.in.ReadString('\n')
	line = strings.TrimSpace(line)
	if line == "" || (err != nil && line == "") {
		return def
	}
	return line
}

func (c *cmd) confirm(question string, def bool) bool {
	d := "Y/n"
	if !def {
		d = "y/N"
	}
	switch strings.ToLower(c.ask(question, d)) {
	case "y", "yes":
		return true
	case "n", "no":
		return false
	}
	return def
}

// ── init ─────────────────────────────────────────────────────────────────────

// trackerTrailers are the task trailer keys a tracker's references usually use.
var trackerTrailers = map[string][]string{
	"github": {"Refs", "Fixes", "Task"},
	"jira":   {"Jira", "Task", "Refs"},
	"linear": {"Linear", "Task", "Refs"},
	"beads":  {"Beads", "Task", "Refs"},
}

func (c *cmd) init(args []string) int {
	fs := c.flags("init")
	dir := fs.String("dir", ".", "repository to initialise")
	stacks := fs.String("stack", "", "comma-separated stacks (default: detected from the repository)")
	agents := fs.String("agents", "", "comma-separated agents to write instructions for (default: all four)")
	tracker := fs.String("tracker", "", "task tracker: none, beads, github, jira or linear")
	skillList := fs.String("skills", "", "comma-separated Claude Code skills to install (see `intellisense skills list`)")
	minTier := fs.Int("minimum-tier", 0, "tier floor for every change")
	ci := fs.Bool("ci", false, "also write .github/workflows/intellisense.yml")
	noHook := fs.Bool("no-hook", false, "do not install the pre-push hook")
	chain := fs.Bool("chain", false, "keep an existing pre-push hook and run it first")
	force := fs.Bool("force", false, "overwrite an existing .intellisense.yml")
	yes := fs.Bool("yes", false, "accept the defaults without asking")
	fs.BoolVar(yes, "y", false, "same as --yes")
	if err := parseArgs(fs, args); err != nil {
		return ExitError
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	repo, err := c.repo(*dir)
	if err != nil {
		return c.fail(fmt.Errorf("%v\n  intellisense works inside a git repository: run `git init` first, or cd into one", err))
	}
	if _, err := os.Stat(policyPath(repo)); err == nil && !*force {
		fmt.Fprintf(c.err, "intellisense: %s already exists here.\n", policy.FileName)
		c.next("intellisense doctor", "check the existing setup",
			"intellisense sync", "regenerate agent instructions after editing the policy",
			"intellisense init --force", "start over (rewrites the policy)")
		return ExitError
	}

	p := policy.Default()
	p.Stacks = splitList(*stacks)
	if len(p.Stacks) == 0 {
		p.Stacks = policy.DetectStacks(repo.Root)
	}
	p.Agents = splitList(*agents)
	if !set["agents"] {
		p.Agents = append([]string(nil), policy.KnownAgents...)
	}
	p.Integrations.Tracker = *tracker
	if p.Integrations.Tracker == "" {
		p.Integrations.Tracker = guessTracker(repo)
	}
	p.Skills = splitList(*skillList)
	p.MinimumTier = *minTier
	wantCI, wantHook := *ci, !*noHook

	if c.interactive() && !*yes {
		fmt.Fprintf(c.out, "Setting up intellisense in %s. Press Enter to accept a suggestion.\n\n", repo.Root)
		if !set["stack"] {
			p.Stacks = splitList(c.ask(fmt.Sprintf("Stacks (built-in: %s)", strings.Join(policy.StackNames(), ", ")), strings.Join(p.Stacks, ",")))
		}
		if !set["agents"] {
			p.Agents = splitList(c.ask("AI agents your team uses (claude, codex, copilot, cursor)", strings.Join(p.Agents, ",")))
		}
		if !set["tracker"] {
			p.Integrations.Tracker = c.ask("Task tracker for task references ("+strings.Join(policy.KnownTrackers, ", ")+")", p.Integrations.Tracker)
		}
		if !set["skills"] && p.HasAgent("claude") && c.confirm("Add Claude Code skills (/plan, /tdd, /verify, /security-scan)?", false) {
			p.Skills = []string{"plan", "tdd", "verify", "security-scan"}
		}
		if !set["ci"] {
			wantCI = c.confirm("Add a GitHub check that runs the gate on every pull request?", true)
		}
		if !set["no-hook"] {
			wantHook = c.confirm("Install the pre-push hook so `git push` runs the gate?", true)
		}
		fmt.Fprintln(c.out)
	}
	for i, s := range p.Stacks {
		if st, ok := policy.LookupStack(s); ok {
			p.Stacks[i] = st.Name
		}
	}
	if keys, ok := trackerTrailers[p.Integrations.Tracker]; ok {
		p.Evidence.TaskTrailers = keys
	}
	if err := p.Validate(); err != nil {
		return c.fail(err)
	}
	if err := skills.Validate(p.Skills); err != nil {
		return c.fail(err)
	}
	if err := os.WriteFile(policyPath(repo), []byte(policy.Render(p)), 0o644); err != nil {
		return c.fail(err)
	}
	fmt.Fprintf(c.out, "✓ wrote %s (stacks: %s; agents: %s; tracker: %s)\n", policy.FileName, orNone(p.Stacks), orNone(p.Agents), p.Tracker())

	mode := rules.Missing
	if *force {
		mode = rules.Update
	}
	res, err := rules.Vendor(repo.Root, p, mode)
	if err != nil {
		return c.fail(err)
	}
	fmt.Fprintf(c.out, "✓ copied %d rule files into %s/\n", len(res.Written), rules.Dir)
	if code := c.runSync(repo, p, false, true); code != ExitOK {
		return code
	}
	if wantCI {
		if err := writeWorkflow(repo.Root); err != nil {
			return c.fail(err)
		}
		fmt.Fprintln(c.out, "✓ wrote .github/workflows/intellisense.yml")
	}
	if wantHook {
		path, err := hook.Install(repo, executable(), *chain)
		if errors.Is(err, hook.ErrAlreadyGated) {
			fmt.Fprintf(c.out, "✓ the existing pre-push hook already runs the gate (%s)\n", path)
		} else if errors.Is(err, hook.ErrForeignHook) {
			fmt.Fprintf(c.out, "! a pre-push hook that is not intellisense's already exists; kept it\n")
			c.next("intellisense hook install --chain", "run that hook first, then the gate")
		} else if err != nil {
			return c.fail(err)
		} else {
			fmt.Fprintf(c.out, "✓ installed the pre-push hook (%s)\n", path)
		}
	}
	key := p.Evidence.TaskTrailers[0]
	fmt.Fprintf(c.out, "\nAdopting intellisense is a Tier 2 change (it adds %s), so its commit carries the evidence:\n\n", policy.FileName)
	fmt.Fprintf(c.out, "  git add -A\n  git commit -m \"chore: adopt intellisense governance\" \\\n    -m \"%s: <task id>\" \\\n    -m \"%s: scope=adopt intellisense, risk=low, confidence=0.9\"\n",
		key, p.Evidence.Contract.Marker)
	c.next("intellisense doctor", "confirm everything is in place",
		"intellisense classify", "see the tier of any change before you push",
		"intellisense help", "every command, with examples")
	return ExitOK
}

// guessTracker picks github when the origin remote is on GitHub, else none.
func guessTracker(repo *gitx.Repo) string {
	if url, err := repo.Git("remote", "get-url", "origin"); err == nil && strings.Contains(url, "github.com") {
		return "github"
	}
	return "none"
}

func orNone(list []string) string {
	if len(list) == 0 {
		return "none"
	}
	return strings.Join(list, ", ")
}

func executable() string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	if strings.Contains(exe, "go-build") {
		return "" // a `go run` binary is deleted when it exits
	}
	return exe
}

func writeWorkflow(root string) error {
	path := filepath.Join(root, ".github", "workflows", "intellisense.yml")
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(Workflow()), 0o644)
}

// Workflow is the GitHub Actions workflow `init --ci` writes.
func Workflow() string {
	return `# Runs the intellisense gate on every pull request: the change must carry the evidence its risk tier
# needs, and the generated agent instructions must match .intellisense.yml.
name: Intellisense

on:
  pull_request:

permissions:
  contents: read

jobs:
  gate:
    name: Intellisense Gate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - uses: soupler-oss/intellisense@v` + intellisense.Version() + `
`
}

// ── sync ─────────────────────────────────────────────────────────────────────

func (c *cmd) sync(args []string) int {
	fs := c.flags("sync")
	dir := fs.String("dir", ".", "repository")
	check := fs.Bool("check", false, "report drift and exit 1 instead of writing")
	if err := parseArgs(fs, args); err != nil {
		return ExitError
	}
	repo, err := c.repo(*dir)
	if err != nil {
		return c.fail(err)
	}
	p, err := c.loadInitialised(repo)
	if err != nil {
		return c.fail(err)
	}
	return c.runSync(repo, p, *check, false)
}

func (c *cmd) loadInitialised(repo *gitx.Repo) (*policy.Policy, error) {
	if _, err := os.Stat(policyPath(repo)); err != nil {
		return nil, fmt.Errorf("no %s in %s; run `intellisense init` first", policy.FileName, repo.Root)
	}
	return policy.Load(policyPath(repo))
}

func (c *cmd) syncChanges(repo *gitx.Repo, p *policy.Policy, check bool) ([]adapters.Change, error) {
	rs, err := rules.Discover(repo.Root, p)
	if err != nil {
		return nil, err
	}
	outputs := adapters.Generate(p, rs)
	skillOut, err := skills.Outputs(p)
	if err != nil {
		return nil, err
	}
	return adapters.Sync(repo.Root, append(outputs, skillOut...), check)
}

func (c *cmd) runSync(repo *gitx.Repo, p *policy.Policy, check, quiet bool) int {
	changes, err := c.syncChanges(repo, p, check)
	if err != nil {
		return c.fail(err)
	}
	drift := adapters.Drift(changes)
	if check {
		if len(drift) == 0 {
			fmt.Fprintln(c.out, "agent instructions are in sync")
			return ExitOK
		}
		fmt.Fprintln(c.out, "agent instructions are out of date:")
		for _, d := range drift {
			fmt.Fprintf(c.out, "  %-9s %s\n", wouldBe(d.Action), d.Path)
		}
		c.next("intellisense sync", "regenerate them, then commit the result")
		return ExitBlocked
	}
	for _, d := range drift {
		fmt.Fprintf(c.out, "  %-9s %s\n", d.Action, d.Path)
	}
	fmt.Fprintf(c.out, "✓ synced %d agent instruction files (%d changed)\n", len(changes), len(drift))
	if !quiet && len(drift) > 0 {
		c.next("git diff", "review what changed",
			"git add -A && git commit", "commit the regenerated files with the policy or rule change")
	}
	return ExitOK
}

func wouldBe(action string) string {
	switch action {
	case adapters.Created:
		return "missing"
	case adapters.Removed:
		return "stale"
	}
	return "changed"
}

// ── classify ─────────────────────────────────────────────────────────────────

func (c *cmd) classify(args []string) int {
	fs := c.flags("classify")
	dir := fs.String("dir", ".", "repository")
	base := fs.String("base", "", "compare from this ref (default: the working tree against HEAD)")
	head := fs.String("head", "HEAD", "compare up to this ref")
	format := fs.String("format", "text", "text or json")
	tierOnly := fs.Bool("tier-only", false, "print only the tier number (for scripts)")
	diffFile := fs.String("diff-file", "", "with one PATH: judge the fast lane from this unified diff instead of git")
	if err := parseArgs(fs, args); err != nil {
		return ExitError
	}
	var repo *gitx.Repo
	if *diffFile != "" || fs.NArg() > 0 {
		repo = c.looseRepo(*dir)
	} else {
		r, err := c.repo(*dir)
		if err != nil {
			return c.fail(err)
		}
		repo = r
	}
	p, err := policy.Load(policyPath(repo))
	if err != nil {
		return c.fail(err)
	}

	var res tier.Result
	switch {
	case *diffFile != "":
		if fs.NArg() != 1 {
			return c.fail(errors.New("--diff-file takes exactly one PATH"))
		}
		data, err := os.ReadFile(*diffFile)
		if err != nil {
			return c.fail(err)
		}
		res = tier.Classify(p, relPaths(repo, fs.Args()), func(string) (string, bool) { return string(data), true })
	case fs.NArg() > 0:
		res = tier.Classify(p, relPaths(repo, fs.Args()), nil)
	case *base != "":
		rg, err := repo.RangeBetween(*base, *head)
		if err != nil {
			return c.fail(err)
		}
		files, err := repo.ChangedFiles(rg)
		if err != nil {
			return c.fail(err)
		}
		res = tier.Classify(p, files, func(path string) (string, bool) {
			d, err := repo.FileDiff(rg, path)
			return d, err == nil
		})
	default:
		files, diff, err := workingChanges(repo)
		if err != nil {
			return c.fail(err)
		}
		res = tier.Classify(p, files, diff)
	}

	if *tierOnly {
		fmt.Fprintln(c.out, res.Tier)
		return ExitOK
	}
	if *format == "json" {
		return c.writeJSON(struct {
			tier.Result
			TierName string   `json:"tier_name"`
			Requires []string `json:"requires"`
		}{res, p.TierName(res.Tier), append([]string{}, p.Required(res.Tier)...)})
	}
	fmt.Fprintf(c.out, "Tier %d — %s\n", res.Tier, p.TierName(res.Tier))
	if res.PolicyTier > res.PathTier {
		fmt.Fprintf(c.out, "  (minimum_tier %d raised it from Tier %d)\n", res.PolicyTier, res.PathTier)
	}
	for _, f := range res.Files {
		fmt.Fprintf(c.out, "  Tier %d  %-48s %-9s %s\n", f.Tier, f.Path, f.By, f.Reason)
	}
	if len(res.Files) == 0 {
		fmt.Fprintln(c.out, "  no changes")
	}
	req := p.Required(res.Tier)
	if len(req) > 0 {
		fmt.Fprintf(c.out, "requires: %s\n", strings.Join(req, " + "))
	}
	if len(res.Files) > 0 && len(req) > 0 {
		var steps []string
		if contains(req, policy.EvidenceTask) {
			steps = append(steps, fmt.Sprintf("git commit -m \"...\" -m \"%s: <task id>\"", p.Evidence.TaskTrailers[0]), "every commit at this tier names its task")
		}
		if contains(req, policy.EvidenceContract) {
			steps = append(steps, "intellisense contract new \"<title>\"", "write the change contract (or add a \""+p.Evidence.Contract.Marker+":\" line to a commit)")
		}
		if contains(req, policy.EvidenceTest) {
			steps = append(steps, "(add or change a test)", "this tier needs a changed test")
		}
		c.next(steps...)
	}
	return ExitOK
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

func relPaths(repo *gitx.Repo, args []string) []string {
	out := make([]string, len(args))
	for i, a := range args {
		if abs, err := filepath.Abs(a); err == nil {
			if rel, err := filepath.Rel(repo.Root, abs); err == nil && !strings.HasPrefix(rel, "..") {
				a = rel
			}
		}
		out[i] = filepath.ToSlash(a)
	}
	return out
}

// workingChanges lists files that differ from HEAD (staged, unstaged and untracked) with their diffs.
func workingChanges(repo *gitx.Repo) ([]string, tier.DiffFunc, error) {
	seen := map[string]bool{}
	var files []string
	addAll := func(out string) {
		for _, f := range strings.Split(out, "\x00") {
			if f != "" && !seen[f] {
				seen[f] = true
				files = append(files, f)
			}
		}
	}
	if repo.Exists("HEAD") {
		out, err := repo.Git("diff", "--name-only", "--no-renames", "-z", "HEAD")
		if err != nil {
			return nil, nil, err
		}
		addAll(out)
	} else {
		out, err := repo.Git("ls-files", "-z")
		if err != nil {
			return nil, nil, err
		}
		addAll(out)
	}
	out, err := repo.Git("ls-files", "-z", "--others", "--exclude-standard")
	if err != nil {
		return nil, nil, err
	}
	addAll(out)
	sort.Strings(files)
	diff := func(path string) (string, bool) {
		if !repo.Exists("HEAD") {
			return "", false
		}
		d, err := repo.Git("diff", "--no-color", "HEAD", "--", path)
		return d, err == nil && d != "" // an untracked file has no diff and keeps its tier
	}
	return files, diff, nil
}

// checkPhrase exits 0 when stdin contains a phrase that disables or bypasses something, 1 otherwise. Live
// mode's Bash hooks call it so the phrase list lives in one place (internal/tier).
func (c *cmd) checkPhrase([]string) int {
	data, err := io.ReadAll(c.stdin)
	if err != nil {
		return c.fail(err)
	}
	if tier.HasDangerousPhrase(string(data)) {
		return ExitOK
	}
	return ExitBlocked
}

// checkCommentOnly exits 0 when the unified diff on stdin only changes comments in its file's language (the
// path comes from the diff's "+++ b/" header, or PATH), 1 otherwise. Live mode's fast lane calls it.
func (c *cmd) checkCommentOnly(args []string) int {
	data, err := io.ReadAll(c.stdin)
	if err != nil {
		return c.fail(err)
	}
	diff := string(data)
	path := ""
	if len(args) > 0 {
		path = args[0]
	}
	for _, line := range strings.Split(diff, "\n") {
		if p, ok := strings.CutPrefix(line, "+++ "); ok && path == "" {
			path = strings.TrimPrefix(strings.TrimSpace(p), "b/")
		}
	}
	if path != "" && tier.CommentOnly(path, diff) {
		return ExitOK
	}
	return ExitBlocked
}

// ── gate / check ─────────────────────────────────────────────────────────────

type gateFlags struct {
	dir, base, head, format, policyFrom *string
}

func (c *cmd) gateFlagSet(name string) (*flag.FlagSet, gateFlags) {
	fs := c.flags(name)
	return fs, gateFlags{
		dir:        fs.String("dir", ".", "repository"),
		base:       fs.String("base", "", "base ref (default: the remote default branch)"),
		head:       fs.String("head", "HEAD", "head ref"),
		format:     fs.String("format", "text", "text, json or github"),
		policyFrom: fs.String("policy", "base", "judge by the policy at the range's base, or the working tree's"),
	}
}

func (c *cmd) gate(args []string) int {
	fs, g := c.gateFlagSet("gate")
	prePush := fs.Bool("pre-push", false, "run as the git pre-push hook: REMOTE URL as arguments, refs on stdin")
	if err := parseArgs(fs, args); err != nil {
		return ExitError
	}
	repo, err := c.repo(*g.dir)
	if err != nil {
		return c.fail(err)
	}
	if *prePush {
		return c.prePush(repo, fs.Args(), *g.policyFrom == "base")
	}
	rg, err := c.resolveRange(repo, *g.base, *g.head)
	if err != nil {
		return c.fail(err)
	}
	rep, err := c.evaluate(repo, rg, *g.policyFrom == "base")
	if err != nil {
		return c.fail(err)
	}
	code := c.report(rep, *g.format)
	if *g.format == gate.FormatText {
		c.gateNext(rep)
	}
	return code
}

// gateNext suggests what to do after a gate verdict.
func (c *cmd) gateNext(rep *gate.Report) {
	if !rep.Blocked {
		c.next("git push", "the push will pass the same check")
		return
	}
	var steps []string
	for _, f := range rep.Findings {
		switch f.Code {
		case "missing-task", "task-not-found":
			steps = append(steps, "git commit --amend", "add the task trailer (for an older commit: git rebase -i)")
		case "missing-contract", "invalid-contract":
			steps = append(steps, "intellisense contract new \"<title>\"", "write or fix the change contract")
		case "missing-test":
			steps = append(steps, "(add or change a test)", "this tier needs a changed test")
		}
	}
	steps = append(steps, "intellisense gate", "check again")
	c.next(dedupePairs(steps)...)
}

func dedupePairs(steps []string) []string {
	seen := map[string]bool{}
	var out []string
	for i := 0; i+1 < len(steps); i += 2 {
		if !seen[steps[i]] {
			seen[steps[i]] = true
			out = append(out, steps[i], steps[i+1])
		}
	}
	return out
}

func (c *cmd) check(args []string) int {
	fs, g := c.gateFlagSet("check")
	noSync := fs.Bool("no-sync", false, "skip the generated-instructions check")
	if err := parseArgs(fs, args); err != nil {
		return ExitError
	}
	repo, err := c.repo(*g.dir)
	if err != nil {
		return c.fail(err)
	}
	rg, err := c.resolveRange(repo, *g.base, *g.head)
	if err != nil {
		return c.fail(err)
	}
	rep, err := c.evaluate(repo, rg, *g.policyFrom == "base")
	if err != nil {
		return c.fail(err)
	}
	if _, err := os.Stat(policyPath(repo)); err == nil && !*noSync {
		p, err := policy.Load(policyPath(repo))
		if err != nil {
			return c.fail(err)
		}
		changes, err := c.syncChanges(repo, p, true)
		if err != nil {
			return c.fail(err)
		}
		for _, d := range adapters.Drift(changes) {
			rep.Findings = append(rep.Findings, gate.Finding{
				Level: gate.LevelError, Code: "instructions-out-of-date", File: d.Path,
				Message: fmt.Sprintf("%s is %s: generated agent instructions do not match %s", d.Path, wouldBe(d.Action), policy.FileName),
				Fix:     "run `intellisense sync` and commit the result",
			})
			rep.Blocked = true
		}
	}
	return c.report(rep, *g.format)
}

func (c *cmd) resolveRange(repo *gitx.Repo, base, head string) (gitx.Range, error) {
	if base == "" {
		for _, r := range []string{"upstream", "origin"} {
			if base = repo.DefaultBranchRef(r); base != "" {
				break
			}
		}
		if base == "" {
			return gitx.Range{}, errors.New("no --base given and no remote default branch found (pass --base main, or push the branch once)")
		}
	}
	return repo.RangeBetween(base, head)
}

func (c *cmd) evaluate(repo *gitx.Repo, rg gitx.Range, fromBase bool) (*gate.Report, error) {
	p, err := gate.LoadPolicy(repo, rg, fromBase)
	if err != nil {
		return nil, err
	}
	return gate.Evaluate(repo, p, rg)
}

func (c *cmd) report(rep *gate.Report, format string) int {
	if err := gate.Write(c.out, rep, format); err != nil {
		return c.fail(err)
	}
	if rep.Blocked {
		return ExitBlocked
	}
	return ExitOK
}

func (c *cmd) prePush(repo *gitx.Repo, args []string, fromBase bool) int {
	remote := ""
	if len(args) > 0 {
		remote = args[0]
	}
	local, err := policy.Load(policyPath(repo))
	if err != nil {
		return c.fail(err)
	}
	for _, blocked := range local.BlockedRemotes {
		if remote == blocked {
			fmt.Fprintf(c.out, "BLOCKED: %s does not allow pushing to the %q remote. Push to your fork and open a pull request.\n", policy.FileName, remote)
			return ExitBlocked
		}
	}
	refs, err := gate.ReadPushedRefs(c.stdin)
	if err != nil {
		return c.fail(err)
	}
	code := ExitOK
	for _, ref := range refs {
		rg, ok, err := gate.PushRange(repo, remote, ref)
		if err != nil {
			return c.fail(err)
		}
		if !ok {
			continue
		}
		rep, err := c.evaluate(repo, rg, fromBase)
		if err != nil {
			return c.fail(err)
		}
		fmt.Fprintf(c.out, "── %s\n", strings.TrimPrefix(ref.LocalRef, "refs/heads/"))
		if c.report(rep, gate.FormatText) != ExitOK {
			code = ExitBlocked
			c.gateNext(rep)
		}
	}
	return code
}

// ── hook ─────────────────────────────────────────────────────────────────────

func (c *cmd) hook(args []string) int {
	if len(args) == 0 {
		return c.help([]string{"hook"})
	}
	fs := c.flags("hook " + args[0])
	dir := fs.String("dir", ".", "repository")
	chain := fs.Bool("chain", false, "keep an existing pre-push hook and run it first")
	if err := parseArgs(fs, args[1:]); err != nil {
		return ExitError
	}
	repo, err := c.repo(*dir)
	if err != nil {
		return c.fail(err)
	}
	switch args[0] {
	case "install":
		path, err := hook.Install(repo, executable(), *chain)
		if errors.Is(err, hook.ErrAlreadyGated) {
			fmt.Fprintf(c.out, "✓ %s already runs the gate; nothing to install\n", path)
			return ExitOK
		}
		if errors.Is(err, hook.ErrForeignHook) {
			fmt.Fprintf(c.err, "intellisense: %v\n", err)
			c.next("intellisense hook install --chain", "keep that hook and run it before the gate")
			return ExitError
		}
		if err != nil {
			return c.fail(err)
		}
		fmt.Fprintf(c.out, "✓ installed pre-push hook at %s\n", path)
		c.next("git push", "every push now runs the gate")
	case "uninstall":
		path, err := hook.Uninstall(repo)
		if err != nil {
			return c.fail(err)
		}
		fmt.Fprintf(c.out, "✓ removed pre-push hook at %s (CI still runs the gate)\n", path)
	case "status":
		ok, path, err := hook.Installed(repo)
		if err != nil {
			return c.fail(err)
		}
		if !ok {
			fmt.Fprintf(c.out, "not installed (%s)\n", path)
			c.next("intellisense hook install", "check every push")
			return ExitBlocked
		}
		fmt.Fprintf(c.out, "installed (%s)\n", path)
	default:
		return c.fail(fmt.Errorf("unknown hook command %q (install, uninstall or status)", args[0]))
	}
	return ExitOK
}

// ── rules ────────────────────────────────────────────────────────────────────

func (c *cmd) rules(args []string) int {
	if len(args) == 0 {
		return c.help([]string{"rules"})
	}
	fs := c.flags("rules " + args[0])
	dir := fs.String("dir", ".", "repository")
	force := fs.Bool("force", false, "update: also overwrite rule files you edited")
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
	switch args[0] {
	case "list":
		rs, err := rules.Discover(repo.Root, p)
		if err != nil {
			return c.fail(err)
		}
		sums, err := rules.LoadChecksums(repo.Root)
		if err != nil {
			return c.fail(err)
		}
		for _, r := range rs {
			scope := "all files"
			if len(r.Globs) > 0 {
				scope = strings.Join(r.Globs, ", ")
			}
			note := ""
			if sums.State(repo.Root, r.Path) == rules.Edited {
				note = "  (edited here)"
			}
			fmt.Fprintf(c.out, "%-18s %-62s %s%s\n", r.Kind, r.Path, scope, note)
		}
		for _, id := range p.Rules.Disable {
			fmt.Fprintf(c.out, "%-18s %-62s %s\n", "disabled", rules.Dir+"/"+id+".md", "(rules.disable)")
		}
	case "update":
		if _, err := c.loadInitialised(repo); err != nil {
			return c.fail(err)
		}
		mode := rules.Update
		if *force {
			mode = rules.Force
		}
		res, err := rules.Vendor(repo.Root, p, mode)
		if err != nil {
			return c.fail(err)
		}
		for _, f := range res.Written {
			fmt.Fprintf(c.out, "  updated   %s\n", f)
		}
		for _, f := range res.Removed {
			fmt.Fprintf(c.out, "  removed   %s (disabled)\n", f)
		}
		for _, f := range res.Kept {
			fmt.Fprintf(c.out, "  kept      %s (edited here; --force replaces it)\n", f)
		}
		fmt.Fprintf(c.out, "✓ rules: %d updated, %d kept, %d removed (organization/ untouched)\n", len(res.Written), len(res.Kept), len(res.Removed))
		return c.runSync(repo, p, false, false)
	default:
		return c.fail(fmt.Errorf("unknown rules command %q (list or update)", args[0]))
	}
	return ExitOK
}
