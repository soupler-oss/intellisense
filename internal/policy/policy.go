// Package policy loads and validates .intellisense.yml, the per-repository governance policy.
//
// A missing file is not an error: Default() is the policy every repository gets until it writes its own.
// A present file is decoded on top of Default(), so it only needs the keys it changes; lists replace the
// default list as a whole.
//
// The risk tiers are a list (`tiers:`), so a repository can add a tier or change what each tier needs without
// a code change.
package policy

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// FileName is the policy file at the repository root.
const FileName = ".intellisense.yml"

// CurrentVersion is the policy format `intellisense init` writes.
const CurrentVersion = 1

// MaxTierLevel bounds how many tiers a policy can define (levels 0..MaxTierLevel).
const MaxTierLevel = 9

// Evidence kinds a tier can require. Each kind is a check in internal/gate.
const (
	EvidenceTask     = "task"     // every commit at the tier carries a task trailer
	EvidenceContract = "contract" // the change carries a valid change contract
	EvidenceTest     = "test"     // the change touches at least one test file
)

// KnownEvidence lists the evidence kinds, in the order they are reported.
var KnownEvidence = []string{EvidenceTask, EvidenceContract, EvidenceTest}

// Secret-scan modes.
const (
	SecretsOff   = "off"
	SecretsWarn  = "warn"
	SecretsBlock = "block"
)

// Task trackers and code-intelligence tools a repository can plug in.
var (
	KnownTrackers  = []string{"none", "beads", "github", "jira", "linear"}
	KnownCodeIntel = []string{"none", "code-review-graph"}
)

// Contract field types.
const (
	FieldString  = "string"
	FieldNumber  = "number"
	FieldInteger = "integer"
)

// Rule is one path pattern (an RE2 regular expression matched against the repo-relative, slash-separated path).
type Rule struct {
	Pattern string `yaml:"pattern"`
	Reason  string `yaml:"reason,omitempty"`
	re      *regexp.Regexp
}

// Match reports whether path matches the rule. Validate must have compiled it.
func (r Rule) Match(path string) bool { return r.re != nil && r.re.MatchString(path) }

// Tier is one risk level: the paths that reach it and the evidence a change at that level needs.
type Tier struct {
	Level    int      `yaml:"level"`
	Name     string   `yaml:"name"`
	Requires []string `yaml:"requires"`
	Rules    []Rule   `yaml:"rules"`
}

// Field is one key of a change contract.
type Field struct {
	Name     string   `yaml:"name"`
	Required bool     `yaml:"required,omitempty"`
	Type     string   `yaml:"type,omitempty"`   // string (default), number or integer
	Values   []string `yaml:"values,omitempty"` // allowed values for a string field
	Min      *float64 `yaml:"min,omitempty"`
	Max      *float64 `yaml:"max,omitempty"`
}

// Contract says what a change contract looks like and where it may live.
type Contract struct {
	// Marker starts a contract line in a commit message ("Change Contract: scope=..., risk=low").
	Marker string `yaml:"marker"`
	// Paths are directories whose changed .md files may hold the contract instead of a commit message.
	Paths []string `yaml:"paths"`
	// Template is a repo-relative .md file `intellisense contract new` copies; empty uses the built-in one.
	Template string `yaml:"template,omitempty"`
	// Fields are the contract's keys and what each must hold.
	Fields []Field `yaml:"fields"`
}

// Evidence says how intellisense recognises each kind of evidence.
type Evidence struct {
	// TaskTrailers are the commit trailer keys accepted as a task reference, e.g. "Task: PROJ-12".
	TaskTrailers []string `yaml:"task_trailers"`
	// VerifyTasks asks the configured tracker whether each task reference exists.
	VerifyTasks bool `yaml:"verify_tasks,omitempty"`
	// Contract is the change-contract format.
	Contract Contract `yaml:"contract"`
	// TestPatterns are the paths that count as tests for `test` evidence.
	TestPatterns []Rule `yaml:"test_patterns"`
}

// Integrations are the external tools a repository plugs in. Each is optional.
type Integrations struct {
	// Tracker is the task tracker task references point at: none, beads, github, jira or linear.
	Tracker string `yaml:"tracker"`
	// CodeIntel is the code-intelligence tool Live mode uses: none or code-review-graph.
	CodeIntel string `yaml:"code_intel"`
}

// RuleSettings switch vendored rules off.
type RuleSettings struct {
	// Disable lists rules by their path under .intellisense/rules/ without ".md", e.g. "operational/testing".
	Disable []string `yaml:"disable"`
}

// Policy is the decoded .intellisense.yml.
type Policy struct {
	Version int      `yaml:"version"`
	Stacks  []string `yaml:"stacks"`
	Agents  []string `yaml:"agents"`
	// Skills are the portable Claude Code skills `intellisense sync` installs into .claude/skills/.
	Skills []string `yaml:"skills"`
	// MinimumTier is the repository's floor: every change is at least this tier.
	MinimumTier int `yaml:"minimum_tier"`
	// DefaultTier applies to a file that matches no tier rule.
	DefaultTier int `yaml:"default_tier"`
	// FastLane lets a default-tier file drop to Tier 0 when its diff only touches comments.
	FastLane bool `yaml:"fast_lane"`
	// Secrets is what a likely secret in an added line does: off, warn or block.
	Secrets string `yaml:"secrets"`
	// BlockedRemotes are remote names the pre-push hook refuses to push to (e.g. "upstream" in a fork workflow).
	BlockedRemotes []string `yaml:"blocked_remotes"`
	// Tiers are the risk levels, any order; Validate sorts them highest first.
	Tiers        []Tier       `yaml:"tiers"`
	Evidence     Evidence     `yaml:"evidence"`
	CustomStacks []Stack      `yaml:"custom_stacks"`
	Integrations Integrations `yaml:"integrations"`
	Rules        RuleSettings `yaml:"rules"`

	// Source is where the policy came from: a file path, "<rev>:.intellisense.yml", or "" for the default.
	Source string `yaml:"-"`
}

// KnownAgents are the agents intellisense can write instructions for.
var KnownAgents = []string{"claude", "codex", "copilot", "cursor"}

// Tier returns the tier at level, if the policy defines one.
func (p *Policy) Tier(level int) (Tier, bool) {
	for _, t := range p.Tiers {
		if t.Level == level {
			return t, true
		}
	}
	return Tier{}, false
}

// MaxTier is the highest level the policy defines (0 when it defines none).
func (p *Policy) MaxTier() int {
	max := 0
	for _, t := range p.Tiers {
		if t.Level > max {
			max = t.Level
		}
	}
	return max
}

// TierName is the policy's name for a level, or a generic one.
func (p *Policy) TierName(level int) string {
	if t, ok := p.Tier(level); ok && t.Name != "" {
		return t.Name
	}
	if level == 0 {
		return "routine"
	}
	return fmt.Sprintf("tier %d", level)
}

// Required returns the evidence kinds a change at level needs. A level the policy does not define needs what
// the nearest defined level below it needs, so a floor can never land on a level that needs nothing.
func (p *Policy) Required(level int) []string {
	best, found := Tier{}, false
	for _, t := range p.Tiers {
		if t.Level <= level && (!found || t.Level > best.Level) {
			best, found = t, true
		}
	}
	if !found {
		return nil
	}
	return best.Requires
}

// Requires reports whether a change at level needs that evidence kind.
func (p *Policy) Requires(level int, kind string) bool { return contains(p.Required(level), kind) }

// AnyRequires reports whether some tier needs that evidence kind.
func (p *Policy) AnyRequires(kind string) bool {
	for _, t := range p.Tiers {
		if contains(t.Requires, kind) {
			return true
		}
	}
	return false
}

// LowestRequiring is the lowest level whose tier needs kind, or -1.
func (p *Policy) LowestRequiring(kind string) int {
	low := -1
	for _, t := range p.Tiers {
		if contains(t.Requires, kind) && (low < 0 || t.Level < low) {
			low = t.Level
		}
	}
	return low
}

// HasAgent reports whether the policy enables an agent adapter.
func (p *Policy) HasAgent(name string) bool { return contains(p.Agents, name) }

// RuleDisabled reports whether a vendored rule (path under .intellisense/rules/, without ".md") is switched off.
func (p *Policy) RuleDisabled(id string) bool {
	return contains(p.Rules.Disable, strings.TrimSuffix(id, ".md"))
}

// Tracker is the configured task tracker ("none" when unset).
func (p *Policy) Tracker() string {
	if p.Integrations.Tracker == "" {
		return "none"
	}
	return p.Integrations.Tracker
}

// Load reads the policy at path. A missing file yields the validated default.
func Load(path string) (*Policy, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		p := Default()
		return p, p.Validate()
	}
	if err != nil {
		return nil, err
	}
	p, err := Parse(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	p.Source = path
	return p, nil
}

// Parse decodes policy YAML on top of the default and validates it. Unknown keys are errors, so a typo
// cannot silently fall back to a default.
func Parse(data []byte) (*Policy, error) {
	p := Default()
	dec := yaml.NewDecoder(bytes.NewReader(data))
	dec.KnownFields(true)
	if err := dec.Decode(p); err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	if err := p.Validate(); err != nil {
		return nil, err
	}
	return p, nil
}

// Validate checks every value, compiles the patterns and sorts the tiers highest first.
func (p *Policy) Validate() error {
	var errs []string
	add := func(format string, a ...any) { errs = append(errs, fmt.Sprintf(format, a...)) }

	if p.Version != CurrentVersion {
		add("version must be %d (got %d)", CurrentVersion, p.Version)
	}
	if len(p.Tiers) == 0 {
		add("tiers must define at least one tier")
	}
	levels := map[int]bool{}
	for i := range p.Tiers {
		t := &p.Tiers[i]
		if t.Level < 0 || t.Level > MaxTierLevel {
			add("tiers[%d]: level must be 0-%d (got %d)", i, MaxTierLevel, t.Level)
		}
		if levels[t.Level] {
			add("tiers: level %d is defined twice", t.Level)
		}
		levels[t.Level] = true
		for _, k := range t.Requires {
			if !contains(KnownEvidence, k) {
				add("tiers[%d] (level %d): unknown evidence %q (use %s)", i, t.Level, k, strings.Join(KnownEvidence, ", "))
			}
		}
		compile(t.Rules, fmt.Sprintf("tiers[%d].rules", i), add)
	}
	sort.SliceStable(p.Tiers, func(i, j int) bool { return p.Tiers[i].Level > p.Tiers[j].Level })
	max := p.MaxTier()
	for _, t := range []struct {
		name string
		v    int
	}{{"minimum_tier", p.MinimumTier}, {"default_tier", p.DefaultTier}} {
		if t.v < 0 || t.v > max {
			add("%s must be between 0 and %d, the highest tier defined (got %d)", t.name, max, t.v)
		}
	}
	switch p.Secrets {
	case SecretsOff, SecretsWarn, SecretsBlock:
	default:
		add("secrets must be off, warn or block (got %q)", p.Secrets)
	}
	for _, a := range p.Agents {
		if !contains(KnownAgents, a) {
			add("unknown agent %q (known: %s)", a, strings.Join(KnownAgents, ", "))
		}
	}
	p.validateStacks(add)
	for _, s := range p.Skills {
		if strings.TrimSpace(s) == "" || strings.ContainsAny(s, `/\`) {
			add("skills: %q is not a skill name", s)
		}
	}
	if p.AnyRequires(EvidenceTask) && len(p.Evidence.TaskTrailers) == 0 {
		add("evidence.task_trailers must name at least one trailer when a tier requires task evidence")
	}
	for _, k := range p.Evidence.TaskTrailers {
		if !trailerKey.MatchString(k) {
			add("evidence.task_trailers: %q is not a valid trailer key", k)
		}
	}
	if p.AnyRequires(EvidenceContract) && strings.TrimSpace(p.Evidence.Contract.Marker) == "" {
		add("evidence.contract.marker must be set when a tier requires a contract")
	}
	p.validateContract(add)
	if p.AnyRequires(EvidenceTest) && len(p.Evidence.TestPatterns) == 0 {
		add("evidence.test_patterns must name at least one pattern when a tier requires test evidence")
	}
	compile(p.Evidence.TestPatterns, "evidence.test_patterns", add)
	if p.Integrations.Tracker != "" && !contains(KnownTrackers, p.Integrations.Tracker) {
		add("integrations.tracker must be one of %s (got %q)", strings.Join(KnownTrackers, ", "), p.Integrations.Tracker)
	}
	if p.Integrations.CodeIntel != "" && !contains(KnownCodeIntel, p.Integrations.CodeIntel) {
		add("integrations.code_intel must be one of %s (got %q)", strings.Join(KnownCodeIntel, ", "), p.Integrations.CodeIntel)
	}
	if p.Evidence.VerifyTasks && p.Tracker() == "none" {
		add("evidence.verify_tasks needs integrations.tracker (beads, github, jira or linear)")
	}
	for _, id := range p.Rules.Disable {
		if strings.TrimSpace(id) == "" || strings.HasPrefix(id, "/") || strings.Contains(id, "..") {
			add("rules.disable: %q is not a rule path such as operational/testing", id)
		}
	}
	if len(errs) > 0 {
		return errors.New("invalid policy:\n  - " + strings.Join(errs, "\n  - "))
	}
	return nil
}

func (p *Policy) validateContract(add func(string, ...any)) {
	seen := map[string]bool{}
	for i, f := range p.Evidence.Contract.Fields {
		where := fmt.Sprintf("evidence.contract.fields[%d]", i)
		if !fieldName.MatchString(f.Name) {
			add("%s: %q is not a valid field name", where, f.Name)
		}
		if seen[f.Name] {
			add("%s: field %q is defined twice", where, f.Name)
		}
		seen[f.Name] = true
		switch f.Type {
		case "", FieldString:
			if f.Min != nil || f.Max != nil {
				add("%s (%s): min and max apply to number and integer fields", where, f.Name)
			}
		case FieldNumber, FieldInteger:
			if len(f.Values) > 0 {
				add("%s (%s): values apply to string fields", where, f.Name)
			}
			if f.Min != nil && f.Max != nil && *f.Min > *f.Max {
				add("%s (%s): min is above max", where, f.Name)
			}
		default:
			add("%s (%s): type must be string, number or integer (got %q)", where, f.Name, f.Type)
		}
	}
	if t := p.Evidence.Contract.Template; t != "" && (!strings.HasSuffix(t, ".md") || strings.HasPrefix(t, "/") || strings.Contains(t, "..")) {
		add("evidence.contract.template must be a repo-relative .md file (got %q)", t)
	}
}

func compile(rules []Rule, where string, add func(string, ...any)) {
	for i := range rules {
		re, err := regexp.Compile(rules[i].Pattern)
		if err != nil {
			add("%s[%d] pattern %q: %v", where, i, rules[i].Pattern, err)
			continue
		}
		rules[i].re = re
	}
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

var (
	trailerKey = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9-]*$`)
	fieldName  = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
)
