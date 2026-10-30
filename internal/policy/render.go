package policy

import (
	"fmt"
	"strconv"
	"strings"
)

// Render writes the policy as commented YAML, the file `intellisense init` creates. Parse(Render(p)) == p.
func Render(p *Policy) string {
	var b strings.Builder
	w := func(format string, a ...any) { fmt.Fprintf(&b, format, a...) }

	w("# intellisense governance policy. Reference: https://github.com/soupler-oss/intellisense/blob/main/docs/policy.md\n")
	w("# This file is itself Tier 2: changing it needs a task reference and a change contract, and CI evaluates a\n")
	w("# pull request against the policy on its base branch, so a PR cannot loosen its own gate.\n")
	w("version: %d\n\n", CurrentVersion)

	w("# Stacks whose rules are vendored into .intellisense/rules/ (built-in: %s; or define custom_stacks).\n", strings.Join(StackNames(), ", "))
	w("stacks: %s\n", flow(p.Stacks))
	w("# Coding agents to write instructions for (%s). Run `intellisense sync` after changing this.\n", strings.Join(KnownAgents, ", "))
	w("agents: %s\n", flow(p.Agents))
	w("# Portable Claude Code skills to install into .claude/skills/ (see `intellisense skills list`).\n")
	w("skills: %s\n\n", flow(p.Skills))

	w("# Every change is at least this tier. Raise it for repositories where everything is sensitive.\n")
	w("minimum_tier: %d\n", p.MinimumTier)
	w("# Tier for a file that matches no rule below.\n")
	w("default_tier: %d\n", p.DefaultTier)
	w("# A default-tier file whose diff only changes comments drops to Tier 0. Never applies to files a rule matched.\n")
	w("fast_lane: %t\n", p.FastLane)
	w("# What a likely secret in an added line does: off, warn or block.\n")
	w("secrets: %s\n", p.Secrets)
	w("# Remotes the pre-push hook refuses (e.g. [upstream] when everyone pushes to a fork).\n")
	w("blocked_remotes: %s\n\n", flow(p.BlockedRemotes))

	w("# Risk tiers, highest first. Each file gets the level of the first tier (from the top) with a matching rule,\n")
	w("# else default_tier; the change gets its highest file level. Add a tier (levels 0-%d) or change what one\n", MaxTierLevel)
	w("# requires: any of %s. Rules are RE2 regular expressions on the repo-relative path.\n", strings.Join(KnownEvidence, ", "))
	w("tiers:\n")
	for _, t := range p.Tiers {
		w("  - level: %d\n", t.Level)
		w("    name: %s\n", quote(t.Name))
		w("    requires: %s\n", flow(t.Requires))
		ruleList(&b, "    ", "rules", t.Rules)
	}

	w("\nevidence:\n")
	w("  # Each commit at a tier that requires `task` carries its own trailer, e.g. \"%s: PROJ-12\".\n", first(p.Evidence.TaskTrailers, "Task"))
	w("  task_trailers: %s\n", flow(p.Evidence.TaskTrailers))
	w("  # Ask integrations.tracker whether each task reference exists (needs the tracker's CLI or token).\n")
	w("  verify_tasks: %t\n", p.Evidence.VerifyTasks)
	w("  # A change contract is a commit-message line \"<marker>: scope=..., risk=low\", or a changed .md file under\n")
	w("  # paths with the fields as front matter (`intellisense contract new` writes one from the template).\n")
	w("  contract:\n")
	w("    marker: %s\n", quote(p.Evidence.Contract.Marker))
	w("    paths: %s\n", flow(p.Evidence.Contract.Paths))
	w("    template: %s\n", quote(p.Evidence.Contract.Template))
	if len(p.Evidence.Contract.Fields) == 0 {
		w("    fields: []\n")
	} else {
		w("    fields:\n")
		for _, f := range p.Evidence.Contract.Fields {
			w("      - name: %s\n", quote(f.Name))
			if f.Required {
				w("        required: true\n")
			}
			if f.Type != "" {
				w("        type: %s\n", f.Type)
			}
			if len(f.Values) > 0 {
				w("        values: %s\n", flow(f.Values))
			}
			if f.Min != nil {
				w("        min: %s\n", num(*f.Min))
			}
			if f.Max != nil {
				w("        max: %s\n", num(*f.Max))
			}
		}
	}
	w("  # Paths that count as tests, for tiers that require `test`.\n")
	ruleList(&b, "  ", "test_patterns", p.Evidence.TestPatterns)

	w("\n# Your own languages: a rule file you keep in .intellisense/rules/language-specific/ and the files it covers.\n")
	if len(p.CustomStacks) == 0 {
		w("custom_stacks: []\n")
	} else {
		w("custom_stacks:\n")
		for _, s := range p.CustomStacks {
			w("  - name: %s\n", quote(s.Name))
			w("    rule: %s\n", quote(s.Rule))
			w("    globs: %s\n", flow(s.Globs))
			if len(s.Markers) > 0 {
				w("    markers: %s\n", flow(s.Markers))
			}
		}
	}

	w("\n# Optional tools. tracker: %s. code_intel (Live mode): %s.\n", strings.Join(KnownTrackers, ", "), strings.Join(KnownCodeIntel, ", "))
	w("integrations:\n")
	w("  tracker: %s\n", orNone(p.Integrations.Tracker))
	w("  code_intel: %s\n", orNone(p.Integrations.CodeIntel))

	w("\n# Switch off vendored rules by path under .intellisense/rules/ without .md, e.g. [operational/proof-standards].\n")
	w("# To change a rule instead, edit its file: `intellisense rules update` keeps files you have edited.\n")
	w("rules:\n")
	w("  disable: %s\n", flow(p.Rules.Disable))
	return b.String()
}

func ruleList(b *strings.Builder, indent, key string, rs []Rule) {
	if len(rs) == 0 {
		fmt.Fprintf(b, "%s%s: []\n", indent, key)
		return
	}
	fmt.Fprintf(b, "%s%s:\n", indent, key)
	for _, r := range rs {
		fmt.Fprintf(b, "%s  - pattern: %s\n", indent, quote(r.Pattern))
		if r.Reason != "" {
			fmt.Fprintf(b, "%s    reason: %s\n", indent, quote(r.Reason))
		}
	}
}

func flow(list []string) string {
	q := make([]string, len(list))
	for i, s := range list {
		q[i] = quote(s)
	}
	return "[" + strings.Join(q, ", ") + "]"
}

func first(list []string, fallback string) string {
	if len(list) == 0 {
		return fallback
	}
	return list[0]
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

func num(f float64) string { return strconv.FormatFloat(f, 'f', -1, 64) }

// quote writes a YAML single-quoted scalar: nothing inside it is an escape, and a quote is doubled.
func quote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
