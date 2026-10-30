package gate

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/soupler-oss/intellisense/internal/policy"
)

// Output formats.
const (
	FormatText   = "text"
	FormatJSON   = "json"
	FormatGitHub = "github"
)

// Write renders the report in a format.
func Write(w io.Writer, rep *Report, format string) error {
	switch format {
	case FormatJSON:
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(rep)
	case FormatGitHub:
		writeAnnotations(w, rep)
		writeText(w, rep)
		return writeStepFiles(rep)
	case FormatText, "":
		writeText(w, rep)
		return nil
	}
	return fmt.Errorf("unknown format %q (use text, json or github)", format)
}

func writeText(w io.Writer, rep *Report) {
	p := rep.policy
	fmt.Fprintf(w, "intellisense gate: Tier %d — %s\n", rep.Tier, rep.TierName)
	src := rep.PolicySource
	if src == "" {
		src = "built-in default"
	}
	fmt.Fprintf(w, "  policy   %s\n", src)
	fmt.Fprintf(w, "  range    %s..%s  (%d commits, %d files)\n", short(rep.From), short(rep.Head), len(rep.Commits), len(rep.Classification.Files))
	if rep.Classification.PolicyTier > rep.Classification.PathTier {
		fmt.Fprintf(w, "  floor    minimum_tier %d raised this change from Tier %d\n", rep.Classification.PolicyTier, rep.Classification.PathTier)
	}
	if len(rep.Required) > 0 {
		fmt.Fprintf(w, "  requires %s\n", strings.Join(describe(rep.Required, p), " + "))
	}
	if trig := rep.Classification.Triggers(); len(trig) > 0 {
		fmt.Fprintf(w, "  Tier %d because:\n", rep.Classification.PathTier)
		for _, f := range trig {
			fmt.Fprintf(w, "    %-48s %s\n", f.Path, f.Reason)
		}
	}
	if rep.Contract != "" {
		fmt.Fprintf(w, "  contract found in %s\n", rep.Contract)
	}
	if rep.Tests != "" {
		fmt.Fprintf(w, "  test changed: %s\n", rep.Tests)
	}
	for _, f := range Sorted(rep.Findings) {
		mark := "✗"
		if f.Level == LevelWarning {
			mark = "!"
		}
		fmt.Fprintf(w, "  %s %s\n", mark, f.Message)
		if f.Fix != "" {
			fmt.Fprintf(w, "      fix: %s\n", f.Fix)
		}
	}
	if rep.Blocked {
		fmt.Fprintf(w, "BLOCKED: %d problem(s). A false positive? Adjust the rules in %s rather than skipping the gate.\n", errorCount(rep), policy.FileName)
	} else {
		fmt.Fprintln(w, "PASSED")
	}
}

func describe(kinds []string, p *policy.Policy) []string {
	out := make([]string, len(kinds))
	for i, k := range kinds {
		switch k {
		case policy.EvidenceTask:
			out[i] = fmt.Sprintf("a task trailer on each Tier %d+ commit (%s)", p.LowestRequiring(k), strings.Join(p.Evidence.TaskTrailers, "/"))
		case policy.EvidenceContract:
			out[i] = "a change contract"
		case policy.EvidenceTest:
			out[i] = "a changed test"
		default:
			out[i] = k
		}
	}
	return out
}

func errorCount(rep *Report) int {
	n := 0
	for _, f := range rep.Findings {
		if f.Level == LevelError {
			n++
		}
	}
	return n
}

// escapeData and escapeProperty follow the GitHub Actions workflow-command encoding.
func escapeData(s string) string {
	return strings.NewReplacer("%", "%25", "\r", "%0D", "\n", "%0A").Replace(s)
}

func escapeProperty(s string) string {
	return strings.NewReplacer("%", "%25", "\r", "%0D", "\n", "%0A", ":", "%3A", ",", "%2C").Replace(s)
}

func writeAnnotations(w io.Writer, rep *Report) {
	for _, f := range Sorted(rep.Findings) {
		props := []string{"title=" + escapeProperty("intellisense: "+f.Code)}
		if f.File != "" {
			props = append(props, "file="+escapeProperty(f.File))
			if f.Line > 0 {
				props = append(props, fmt.Sprintf("line=%d", f.Line))
			}
		}
		msg := f.Message
		if f.Fix != "" {
			msg += "\nFix: " + f.Fix
		}
		fmt.Fprintf(w, "::%s %s::%s\n", f.Level, strings.Join(props, ","), escapeData(msg))
	}
}

// writeStepFiles appends the job summary and the step outputs (tier, blocked) when running in Actions.
func writeStepFiles(rep *Report) error {
	if path := os.Getenv("GITHUB_OUTPUT"); path != "" {
		if err := appendFile(path, fmt.Sprintf("tier=%d\nblocked=%t\n", rep.Tier, rep.Blocked)); err != nil {
			return err
		}
	}
	path := os.Getenv("GITHUB_STEP_SUMMARY")
	if path == "" {
		return nil
	}
	var b strings.Builder
	verdict := "✅ Passed"
	if rep.Blocked {
		verdict = "❌ Blocked"
	}
	fmt.Fprintf(&b, "## intellisense: Tier %d — %s\n\n%s · policy: `%s` · %d commits · %d files\n\n",
		rep.Tier, rep.TierName, verdict, orDefault(rep.PolicySource), len(rep.Commits), len(rep.Classification.Files))
	if trig := rep.Classification.Triggers(); len(trig) > 0 {
		fmt.Fprintf(&b, "| Tier %d file | Reason |\n|---|---|\n", rep.Classification.PathTier)
		for _, f := range trig {
			fmt.Fprintf(&b, "| `%s` | %s |\n", f.Path, f.Reason)
		}
		b.WriteString("\n")
	}
	if len(rep.Findings) > 0 {
		b.WriteString("| | Problem | Fix |\n|---|---|---|\n")
		for _, f := range Sorted(rep.Findings) {
			icon := "❌"
			if f.Level == LevelWarning {
				icon = "⚠️"
			}
			fmt.Fprintf(&b, "| %s | %s | %s |\n", icon, cell(f.Message), cell(f.Fix))
		}
	}
	return appendFile(path, b.String()+"\n")
}

func cell(s string) string { return strings.NewReplacer("|", `\|`, "\n", " ").Replace(s) }

func orDefault(s string) string {
	if s == "" {
		return "built-in default"
	}
	return s
}

func appendFile(path, s string) error {
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.WriteString(s); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}
