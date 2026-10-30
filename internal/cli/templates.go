package cli

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// TemplateRecord is .intellisense/templates.json in a Live-mode repository: for each file setup-repos.sh copied
// from the platform's templates, where it came from and the checksum of what was written. With it, an update
// can tell a file nobody touched (refresh it) from one the team edited (keep it).
const TemplateRecord = ".intellisense/templates.json"

type templateEntry struct {
	Source string `json:"source"` // path inside the platform, e.g. templates/ci/refresh-docs.yml
	SHA256 string `json:"sha256"` // of the content as installed
}

// knownTemplates are the files setup-repos.sh copies, for repositories onboarded before the record existed.
var knownTemplates = map[string]string{
	".github/workflows/refresh-docs.yml":                         "templates/ci/refresh-docs.yml",
	".github/workflows/intellisense-trailer-check.yml":           "templates/ci/intellisense-trailer-check.yml",
	".intellisense/scripts/validate-intellisense-trailers-pr.sh": "scripts/validate-intellisense-trailers-pr.sh",
}

func sha(data []byte) string { h := sha256.Sum256(data); return hex.EncodeToString(h[:]) }

// platformDir is the Live-mode platform the templates come from.
func platformDir() (string, error) {
	if d := os.Getenv("INTELLISENSE_SETUP_PATH"); d != "" {
		return d, nil
	}
	home, err := liveHome()
	if err != nil {
		return "", err
	}
	current := filepath.Join(home, "platform", "current")
	if _, err := os.Stat(filepath.Join(current, "templates")); err == nil {
		return current, nil
	}
	userHome, _ := os.UserHomeDir()
	if data, err := os.ReadFile(filepath.Join(userHome, ".claude", "config.json")); err == nil {
		var cfg struct {
			Path string `json:"intellisense_setup_path"`
		}
		if json.Unmarshal(data, &cfg) == nil && cfg.Path != "" {
			return cfg.Path, nil
		}
	}
	return "", errors.New("Live mode is not installed (no platform templates found); run `intellisense live install` or set INTELLISENSE_SETUP_PATH")
}

// templates: `intellisense live templates check|update [--force] [--dir REPO]`.
func (c *cmd) liveTemplates(args []string) int {
	fs := c.flags("live templates")
	dir := fs.String("dir", ".", "repository")
	force := fs.Bool("force", false, "update: also replace files the team edited (a .bak copy is kept)")
	if err := parseArgs(fs, args); err != nil {
		return ExitError
	}
	if fs.NArg() != 1 || (fs.Arg(0) != "check" && fs.Arg(0) != "update") {
		return c.fail(errors.New("usage: intellisense live templates check | update [--force] [--dir REPO]"))
	}
	update := fs.Arg(0) == "update"
	repo, err := c.repo(*dir)
	if err != nil {
		return c.fail(err)
	}
	platform, err := platformDir()
	if err != nil {
		return c.fail(err)
	}
	record := map[string]templateEntry{}
	recordPath := filepath.Join(repo.Root, filepath.FromSlash(TemplateRecord))
	if data, err := os.ReadFile(recordPath); err == nil {
		if err := json.Unmarshal(data, &record); err != nil {
			return c.fail(fmt.Errorf("%s: %v", TemplateRecord, err))
		}
	}
	// Files the record does not know yet, but setup-repos.sh installs: judge them by content.
	for dst, src := range knownTemplates {
		if _, ok := record[dst]; !ok {
			if _, err := os.Stat(filepath.Join(repo.Root, filepath.FromSlash(dst))); err == nil {
				record[dst] = templateEntry{Source: src}
			}
		}
	}
	if len(record) == 0 {
		fmt.Fprintln(c.out, "No Live-mode templates in this repository (it was not onboarded with setup-repos.sh).")
		return ExitOK
	}
	dsts := make([]string, 0, len(record))
	for d := range record {
		dsts = append(dsts, d)
	}
	sort.Strings(dsts)

	stale, kept := 0, 0
	for _, dst := range dsts {
		e := record[dst]
		want, err := os.ReadFile(filepath.Join(platform, filepath.FromSlash(e.Source)))
		if err != nil {
			fmt.Fprintf(c.out, "  ?         %-55s the platform no longer has %s\n", dst, e.Source)
			continue
		}
		abs := filepath.Join(repo.Root, filepath.FromSlash(dst))
		have, err := os.ReadFile(abs)
		missing := err != nil
		switch {
		case !missing && sha(have) == sha(want):
			e.SHA256 = sha(want)
			record[dst] = e
			fmt.Fprintf(c.out, "  current   %s\n", dst)
			continue
		case missing:
			stale++
			if !update {
				fmt.Fprintf(c.out, "  missing   %s\n", dst)
				continue
			}
		case e.SHA256 != "" && sha(have) == e.SHA256:
			stale++
			if !update {
				fmt.Fprintf(c.out, "  outdated  %s (unedited: update replaces it)\n", dst)
				continue
			}
		default:
			reason := "edited here"
			if e.SHA256 == "" {
				reason = "differs, and no record of what was installed"
			}
			if !update || !*force {
				kept++
				fmt.Fprintf(c.out, "  kept      %s (%s; --force replaces it, keeping a .bak)\n", dst, reason)
				continue
			}
			bak := abs + ".bak-" + time.Now().Format("20060102150405")
			if err := os.WriteFile(bak, have, 0o644); err != nil {
				return c.fail(err)
			}
		}
		if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
			return c.fail(err)
		}
		mode := os.FileMode(0o644)
		if strings.HasSuffix(dst, ".sh") {
			mode = 0o755
		}
		if err := os.WriteFile(abs, want, mode); err != nil {
			return c.fail(err)
		}
		e.SHA256 = sha(want)
		record[dst] = e
		fmt.Fprintf(c.out, "  updated   %s\n", dst)
	}
	if update {
		data, _ := json.MarshalIndent(record, "", "  ")
		if err := os.MkdirAll(filepath.Dir(recordPath), 0o755); err != nil {
			return c.fail(err)
		}
		if err := os.WriteFile(recordPath, append(data, '\n'), 0o644); err != nil {
			return c.fail(err)
		}
		fmt.Fprintf(c.out, "✓ templates updated (%d kept as edited); record: %s\n", kept, TemplateRecord)
		c.next("git diff", "review the changes, then commit them")
		return ExitOK
	}
	if stale > 0 {
		c.next("intellisense live templates update", fmt.Sprintf("refresh the %d outdated or missing file(s); edited files are kept", stale))
		return ExitBlocked
	}
	fmt.Fprintln(c.out, "✓ Live-mode templates are current")
	return ExitOK
}
