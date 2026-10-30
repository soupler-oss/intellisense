package cli

import (
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	intellisense "github.com/soupler-oss/intellisense"
	"github.com/soupler-oss/intellisense/internal/policy"
)

// Live mode lives in ~/.intellisense: platform/<version> is the unpacked installer and everything it links
// into ~/.claude, platform/current points at the version in use, and bin/intellisense is the engine the Bash
// hooks call.
func liveHome() (string, error) {
	if h := os.Getenv("INTELLISENSE_HOME"); h != "" {
		return h, nil
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".intellisense"), nil
}

func (c *cmd) live(args []string) int {
	if len(args) == 0 {
		return c.help([]string{"live"})
	}
	switch args[0] {
	case "install":
		return c.liveInstall(args[1:])
	case "status":
		return c.liveStatus()
	case "uninstall":
		return c.liveUninstall(args[1:])
	case "templates":
		return c.liveTemplates(args[1:])
	case "path":
		home, err := liveHome()
		if err != nil {
			return c.fail(err)
		}
		fmt.Fprintln(c.out, filepath.Join(home, "platform", "current"))
		return ExitOK
	}
	return c.fail(fmt.Errorf("unknown live command %q (install, status, uninstall or templates)", args[0]))
}

func (c *cmd) liveInstall(args []string) int {
	fs := c.flags("live install")
	tracker := fs.String("tracker", "", "task tracker: "+strings.Join(policy.KnownTrackers, ", "))
	codeIntel := fs.String("code-intel", "", "code intelligence: "+strings.Join(policy.KnownCodeIntel, ", "))
	noHeartbeat := fs.Bool("no-heartbeat", false, "do not install the usage heartbeat (telemetry is off unless a collector token is configured)")
	yes := fs.Bool("yes", false, "accept the defaults without asking")
	fs.BoolVar(yes, "y", false, "same as --yes")
	dryRun := fs.Bool("dry-run", false, "unpack and show what setup would do, changing nothing in ~/.claude")
	if err := parseArgs(fs, args); err != nil {
		return ExitError
	}
	if runtime.GOOS == "windows" {
		return c.fail(errors.New("Live mode runs Claude Code hooks written in bash: install it from WSL, or use Core mode (`intellisense init`) on Windows"))
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		return c.fail(errors.New("Live mode needs bash on PATH"))
	}
	set := map[string]bool{}
	fs.Visit(func(f *flag.Flag) { set[f.Name] = true })
	if *tracker == "" {
		*tracker = "none"
	}
	if *codeIntel == "" {
		*codeIntel = "none"
	}
	if c.interactive() && !*yes {
		fmt.Fprintln(c.out, "Installing intellisense Live mode for Claude Code on this machine. Press Enter to accept a suggestion.")
		fmt.Fprintln(c.out)
		if !set["tracker"] {
			*tracker = c.ask("Task tracker ("+strings.Join(policy.KnownTrackers, ", ")+"; beads installs the bd CLI)", *tracker)
		}
		if !set["code-intel"] {
			*codeIntel = c.ask("Code intelligence ("+strings.Join(policy.KnownCodeIntel, ", ")+"; installs a Python tool)", *codeIntel)
		}
		fmt.Fprintln(c.out)
	}
	if !contains(policy.KnownTrackers, *tracker) {
		return c.fail(fmt.Errorf("--tracker must be one of %s", strings.Join(policy.KnownTrackers, ", ")))
	}
	if !contains(policy.KnownCodeIntel, *codeIntel) {
		return c.fail(fmt.Errorf("--code-intel must be one of %s", strings.Join(policy.KnownCodeIntel, ", ")))
	}

	home, err := liveHome()
	if err != nil {
		return c.fail(err)
	}
	dir, err := unpackPlatform(home)
	if err != nil {
		return c.fail(fmt.Errorf("unpacking the Live platform: %w", err))
	}
	fmt.Fprintf(c.out, "✓ unpacked Live mode %s into %s\n", intellisense.Version(), dir)
	if exe := executable(); exe != "" {
		if err := linkEngine(home, exe); err != nil {
			return c.fail(err)
		}
		fmt.Fprintf(c.out, "✓ linked %s → %s\n", filepath.Join(home, "bin", "intellisense"), exe)
	}

	current := filepath.Join(home, "platform", "current")
	setup := []string{filepath.Join(current, "setup.sh"), "--tracker", *tracker, "--code-intel", *codeIntel}
	if *noHeartbeat {
		setup = append(setup, "--no-heartbeat")
	}
	if *dryRun {
		setup = append(setup, "--dry-run")
	}
	if !c.interactive() || *yes {
		setup = append(setup, "--non-interactive")
	}
	fmt.Fprintf(c.out, "→ running %s\n\n", strings.Join(setup, " "))
	run := exec.Command(bash, setup...)
	run.Stdin, run.Stdout, run.Stderr = c.stdin, c.out, c.err
	run.Env = append(os.Environ(), "INTELLISENSE_HOME="+home, "INTELLISENSE_BIN="+filepath.Join(home, "bin", "intellisense"))
	if err := run.Run(); err != nil {
		fmt.Fprintf(c.err, "\nintellisense: Live mode setup failed: %v\n", err)
		c.next("intellisense live install --dry-run", "see what setup does without changing anything",
			"intellisense live uninstall", "put ~/.claude back the way it was")
		return ExitError
	}
	c.next("intellisense live status", "confirm what is installed",
		"cd <a repository> && intellisense init", "add Core mode (the push and CI gate) to each repository",
		"claude", "start Claude Code: prompts are now classified and risky edits need a contract")
	return ExitOK
}

// unpackPlatform writes the embedded platform to home/platform/<version> (replacing an older copy of the
// same version) and points home/platform/current at it.
func unpackPlatform(home string) (string, error) {
	base := filepath.Join(home, "platform")
	dir := filepath.Join(base, intellisense.Version())
	if err := os.MkdirAll(base, 0o755); err != nil {
		return "", err
	}
	tmp, err := os.MkdirTemp(base, ".unpack-")
	if err != nil {
		return "", err
	}
	err = fs.WalkDir(intellisense.Platform, ".", func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		target := filepath.Join(tmp, filepath.FromSlash(p))
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		data, err := fs.ReadFile(intellisense.Platform, p)
		if err != nil {
			return err
		}
		mode := os.FileMode(0o644)
		if executableInPlatform(p, data) {
			mode = 0o755
		}
		return os.WriteFile(target, data, mode)
	})
	if err != nil {
		os.RemoveAll(tmp)
		return "", err
	}
	if err := os.RemoveAll(dir); err != nil {
		return "", err
	}
	if err := os.Rename(tmp, dir); err != nil {
		return "", err
	}
	current := filepath.Join(base, "current")
	_ = os.Remove(current)
	if err := os.Symlink(intellisense.Version(), current); err != nil {
		return "", err
	}
	return dir, nil
}

// executableInPlatform: scripts, hooks and anything with a shebang run as programs.
func executableInPlatform(p string, data []byte) bool {
	return strings.HasSuffix(p, ".sh") || strings.HasPrefix(p, "hooks/") || strings.HasPrefix(string(data), "#!")
}

func linkEngine(home, exe string) error {
	bin := filepath.Join(home, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		return err
	}
	link := filepath.Join(bin, "intellisense")
	if cur, err := os.Readlink(link); err == nil && cur == exe {
		return nil
	}
	_ = os.Remove(link)
	return os.Symlink(exe, link)
}

func (c *cmd) liveStatus() int {
	home, err := liveHome()
	if err != nil {
		return c.fail(err)
	}
	current := filepath.Join(home, "platform", "current")
	target, err := os.Readlink(current)
	if err != nil {
		fmt.Fprintln(c.out, "Live mode is not installed on this machine.")
		c.next("intellisense live install", "install it")
		return ExitBlocked
	}
	fmt.Fprintf(c.out, "Live mode   %s (%s)\n", target, filepath.Join(home, "platform", target))
	if engine, err := os.Readlink(filepath.Join(home, "bin", "intellisense")); err == nil {
		fmt.Fprintf(c.out, "Engine      %s\n", engine)
	}
	claude, _ := os.UserHomeDir()
	link, err := os.Readlink(filepath.Join(claude, ".claude", "skills"))
	switch {
	case err != nil:
		fmt.Fprintln(c.out, "~/.claude   ✗ not linked (run `intellisense live install`)")
	case strings.HasPrefix(link, filepath.Join(home, "platform")):
		fmt.Fprintf(c.out, "~/.claude   ✓ linked (%s)\n", link)
	default:
		fmt.Fprintf(c.out, "~/.claude   ! linked to %s (a git checkout, not this install)\n", link)
	}
	if data, err := os.ReadFile(filepath.Join(home, "integrations.env")); err == nil {
		for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
			if k, v, ok := strings.Cut(line, "="); ok {
				fmt.Fprintf(c.out, "%-11s %s\n", strings.ToLower(strings.TrimPrefix(k, "INTELLISENSE_")), v)
			}
		}
	}
	if target != intellisense.Version() {
		c.next("intellisense live install", fmt.Sprintf("upgrade Live mode from %s to %s", target, intellisense.Version()))
	}
	return ExitOK
}

func (c *cmd) liveUninstall(args []string) int {
	home, err := liveHome()
	if err != nil {
		return c.fail(err)
	}
	restore := filepath.Join(home, "platform", "current", "restore.sh")
	if _, err := os.Stat(restore); err != nil {
		return c.fail(errors.New("Live mode is not installed by this tool (no " + restore + "); if you installed from a git checkout, run its restore.sh"))
	}
	run := exec.Command("bash", append([]string{restore}, args...)...)
	run.Stdin, run.Stdout, run.Stderr = c.stdin, c.out, c.err
	if err := run.Run(); err != nil {
		return c.fail(fmt.Errorf("restore.sh failed: %w", err))
	}
	fmt.Fprintf(c.out, "\n✓ Live mode removed. %s still holds the unpacked platform; delete it if you like.\n", filepath.Join(home, "platform"))
	return ExitOK
}
