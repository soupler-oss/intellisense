// Package tier decides how risky a change is.
//
// Each file gets a tier from the policy's path rules, checked from the highest tier down: the first tier
// with a matching rule wins (a match in the level-0 tier makes the file "safe"), else the policy's
// default_tier. A file that only reached Tier 1+ through the
// default may drop to Tier 0 when its diff touches nothing but comments (the fast lane). The change's tier
// is the highest file tier, raised to the policy's minimum_tier.
//
// This is the only tier engine: Live mode's Bash hooks call it through `intellisense classify --tier-only`
// and `intellisense check-phrase` instead of keeping their own copy of the rules.
package tier

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/soupler-oss/intellisense/internal/policy"
)

// How a file got its tier. A rule match in tier N is "tierN", except level 0, which is "safe".
const (
	ByTier2   = "tier2"
	ByTier1   = "tier1"
	BySafe    = "safe"
	ByDefault = "default"
	ByFast    = "fast-lane"
)

// File is one path's classification.
type File struct {
	Path    string `json:"path"`
	Tier    int    `json:"tier"`
	By      string `json:"by"`
	Reason  string `json:"reason,omitempty"`
	Pattern string `json:"pattern,omitempty"`
}

// Result is a whole change's classification.
type Result struct {
	// Tier is the effective tier: max(PathTier, PolicyTier).
	Tier       int    `json:"tier"`
	PathTier   int    `json:"path_tier"`
	PolicyTier int    `json:"policy_tier"`
	Files      []File `json:"files"`
}

// Triggers are the files that set the change's tier (none for a Tier 0 change).
func (r Result) Triggers() []File {
	var out []File
	if r.PathTier == 0 {
		return nil
	}
	for _, f := range r.Files {
		if f.Tier == r.PathTier {
			out = append(out, f)
		}
	}
	return out
}

// DiffFunc returns a path's diff for the fast lane. ok=false means no diff is available, which keeps the
// file at its default tier.
type DiffFunc func(path string) (diff string, ok bool)

// Path classifies one path without looking at its diff.
func Path(p *policy.Policy, path string) File {
	path = filepath.ToSlash(path)
	for _, t := range p.Tiers { // highest first
		for _, r := range t.Rules {
			if r.Match(path) {
				return File{Path: path, Tier: t.Level, By: by(t.Level), Reason: r.Reason, Pattern: r.Pattern}
			}
		}
	}
	return File{Path: path, Tier: p.DefaultTier, By: ByDefault, Reason: "no rule matched"}
}

func by(level int) string {
	if level == 0 {
		return BySafe
	}
	return fmt.Sprintf("tier%d", level)
}

// Classify classifies a change. diff may be nil, which disables the fast lane.
func Classify(p *policy.Policy, paths []string, diff DiffFunc) Result {
	res := Result{PolicyTier: p.MinimumTier}
	for _, path := range paths {
		f := Path(p, path)
		if f.By == ByDefault && f.Tier > 0 && p.FastLane && diff != nil {
			if d, ok := diff(path); ok && CommentOnly(path, d) && !HasDangerousPhrase(d) {
				f.Tier, f.By, f.Reason = 0, ByFast, "diff only changes comments"
			}
		}
		if f.Tier > res.PathTier {
			res.PathTier = f.Tier
		}
		res.Files = append(res.Files, f)
	}
	res.Tier = max(res.PathTier, res.PolicyTier)
	return res
}

// DangerousPhrases keep a comment-only diff out of the fast lane: commenting code out, a comment that says a
// check is being switched off, or a directive that silences a linter, type checker, scanner or coverage tool is a
// behaviour change dressed as a comment. Matching is case-insensitive and on substrings, so "disable" also covers
// eslint-disable, pylint: disable, rubocop:disable, swiftlint:disable and #pragma warning disable.
var DangerousPhrases = []string{
	"comment out", "commented out", "comment-out", "disable", "disabled", "remove validation",
	"remove the validation", "skip validation", "skip the check", "skip check", "bypass", "turn off",
	"no-op", "noop", "stub out", "stubbed out",
	// Linters: golangci-lint and clang-tidy, flake8, Sonar, JetBrains, PHP_CodeSniffer, staticcheck, Deno, Biome.
	"nolint", "noqa", "nosonar", "noinspection", "phpcs:ignore", "lint:ignore", "lint-ignore", "biome-ignore",
	// Type checkers: TypeScript, mypy, PHPStan, Psalm.
	"ts-ignore", "ts-nocheck", "ts-expect-error", "type: ignore", "phpstan-ignore", "psalm-suppress",
	// Security scanners: gosec and bandit, Semgrep, gitleaks, intellisense's own secret check.
	"nosec", "nosemgrep", "gitleaks:allow", "allow-secret",
	// Coverage: Istanbul, c8, coverage.py.
	"istanbul ignore", "c8 ignore", "pragma: no cover",
}

var dangerous = regexp.MustCompile(`(?i)` + strings.Join(quoteAll(DangerousPhrases), "|"))

func quoteAll(list []string) []string {
	out := make([]string, len(list))
	for i, s := range list {
		out[i] = regexp.QuoteMeta(s)
	}
	return out
}

// HasDangerousPhrase reports whether text contains one of DangerousPhrases (case-insensitive).
func HasDangerousPhrase(text string) bool { return dangerous.MatchString(text) }

// commentStyle is how a file's comments look: "doc" (any line is prose), "markup", "hash", "slash", or ""
// for a file type intellisense does not know, which is never comment-only.
func commentStyle(path string) string {
	base := filepath.Base(path)
	switch base {
	case "Dockerfile", "Makefile":
		return "hash"
	}
	switch strings.ToLower(filepath.Ext(path)) {
	case ".md", ".markdown", ".rst", ".txt", ".adoc":
		return "doc"
	case ".html", ".htm", ".xhtml", ".xml", ".svg":
		return "markup"
	case ".sh", ".bash", ".zsh", ".py", ".rb", ".yml", ".yaml", ".toml", ".cfg", ".conf", ".ini", ".pl", ".r", ".tf":
		return "hash"
	case ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".go", ".c", ".h", ".cpp", ".hpp", ".cc", ".java", ".cs",
		".php", ".rs", ".swift", ".kt", ".kts", ".scala", ".dart":
		return "slash"
	}
	return ""
}

// CommentOnly reports whether every non-blank line a diff adds or removes is a comment in the file's
// language. An empty diff, an unknown language, or a block comment that spans lines is not comment-only:
// when in doubt the file keeps its tier.
func CommentOnly(path, diff string) bool {
	style := commentStyle(path)
	if style == "" {
		return false
	}
	changed := false
	for _, l := range strings.Split(diff, "\n") {
		if strings.HasPrefix(l, "+++ ") || strings.HasPrefix(l, "--- ") {
			continue
		}
		if !strings.HasPrefix(l, "+") && !strings.HasPrefix(l, "-") {
			continue
		}
		t := strings.TrimSpace(l[1:])
		if t == "" {
			continue
		}
		changed = true
		switch style {
		case "doc":
		case "markup":
			if !(strings.HasPrefix(t, "<!--") && strings.HasSuffix(t, "-->")) {
				return false
			}
		case "hash":
			if !strings.HasPrefix(t, "#") {
				return false
			}
		case "slash":
			if !strings.HasPrefix(t, "//") && !(strings.HasPrefix(t, "/*") && strings.HasSuffix(t, "*/")) {
				return false
			}
		}
	}
	return changed
}
