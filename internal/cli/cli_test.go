package cli

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/soupler-oss/intellisense/internal/hook"
)

// binDir holds an intellisense binary built from this source, so the installed hook can run it.
var binDir string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "intellisense-bin")
	if err != nil {
		panic(err)
	}
	name := "intellisense"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	build := exec.Command("go", "build", "-o", filepath.Join(dir, name), "github.com/soupler-oss/intellisense/cmd/intellisense")
	if out, err := build.CombinedOutput(); err != nil {
		panic(string(out))
	}
	binDir = dir
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

type env struct {
	t      *testing.T
	app    string
	remote string
}

func newEnv(t *testing.T) *env {
	t.Helper()
	root := t.TempDir()
	t.Setenv("HOME", root)
	t.Setenv("GIT_CONFIG_GLOBAL", filepath.Join(root, ".gitconfig"))
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	e := &env{t: t, app: filepath.Join(root, "app"), remote: filepath.Join(root, "remote.git")}
	e.git(root, "init", "-q", "--bare", e.remote)
	e.git(root, "init", "-q", "-b", "main", e.app)
	e.git(e.app, "config", "user.name", "Test")
	e.git(e.app, "config", "user.email", "test@example.com")
	e.git(e.app, "remote", "add", "origin", e.remote)
	e.write("go.mod", "module example.com/app\n\ngo 1.22\n")
	e.write("README.md", "# app\n")
	e.git(e.app, "add", "-A")
	e.git(e.app, "commit", "-q", "-m", "init")
	e.git(e.app, "push", "-q", "origin", "main")
	return e
}

func (e *env) git(dir string, args ...string) string {
	e.t.Helper()
	out, err := e.gitErr(dir, args...)
	if err != nil {
		e.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return out
}

func (e *env) gitErr(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (e *env) write(rel, body string) {
	e.t.Helper()
	path := filepath.Join(e.app, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		e.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		e.t.Fatal(err)
	}
}

func (e *env) run(args ...string) (int, string) {
	e.t.Helper()
	var out, errb bytes.Buffer
	code := Run(append(args, "--dir", e.app), strings.NewReader(""), &out, &errb)
	return code, out.String() + errb.String()
}

func (e *env) commit(msg ...string) {
	e.t.Helper()
	args := []string{"commit", "-q"}
	for _, m := range msg {
		args = append(args, "-m", m)
	}
	e.git(e.app, "add", "-A")
	e.git(e.app, args...)
}

func TestInitThenPushThroughTheHook(t *testing.T) {
	e := newEnv(t)
	if code, out := e.run("init", "--ci"); code != ExitOK {
		t.Fatalf("init: %d\n%s", code, out)
	}
	for _, f := range []string{".intellisense.yml", "AGENTS.md", "CLAUDE.md", ".github/copilot-instructions.md",
		".cursor/rules/intellisense-core.mdc", ".github/workflows/intellisense.yml", ".intellisense/rules/language-specific/go-patterns.md"} {
		if _, err := os.Stat(filepath.Join(e.app, filepath.FromSlash(f))); err != nil {
			t.Errorf("init should write %s", f)
		}
	}
	if code, out := e.run("doctor"); code != ExitOK {
		t.Fatalf("doctor after init: %d\n%s", code, out)
	}

	e.commit("chore: adopt intellisense")
	out, err := e.gitErr(e.app, "push", "origin", "main")
	if err == nil || !strings.Contains(out, "has no task trailer") || !strings.Contains(out, "no change contract") {
		t.Fatalf("adopting without evidence must be refused by the hook:\n%s", out)
	}

	e.git(e.app, "commit", "-q", "--amend", "-m", "chore: adopt intellisense", "-m", "Task: DEMO-1", "-m", "Change Contract: scope=adopt, risk=low")
	if out, err := e.gitErr(e.app, "push", "origin", "main"); err != nil {
		t.Fatalf("push with evidence should pass:\n%s", out)
	}

	e.git(e.app, "checkout", "-q", "-b", "feat/greet")
	e.write("internal/greet/greet.go", "package greet\n\n// Hello greets.\nfunc Hello() string { return \"hi\" }\n")
	e.commit("feat: greet", "Task: DEMO-2", "Change Contract: scope=greet, risk=low")
	if out, err := e.gitErr(e.app, "push", "origin", "feat/greet"); err != nil {
		t.Fatalf("new branch with evidence should pass:\n%s", out)
	}
	e.write("internal/greet/greet.go", "package greet\n\n// Hello greets the caller.\nfunc Hello() string { return \"hi\" }\n")
	e.commit("docs: reword comment")
	if out, err := e.gitErr(e.app, "push", "origin", "feat/greet"); err != nil || !strings.Contains(out, "Tier 0") {
		t.Fatalf("a comment-only follow-up is Tier 0:\n%s", out)
	}

	code, out := e.run("check", "--base", "main", "--head", "feat/greet")
	if code != ExitOK || !strings.Contains(out, "Tier 1") {
		t.Fatalf("CI check of the branch: %d\n%s", code, out)
	}
}

func TestCheckFailsOnInstructionDrift(t *testing.T) {
	e := newEnv(t)
	if code, out := e.run("init", "--no-hook", "--agents", "codex"); code != ExitOK {
		t.Fatal(out)
	}
	e.commit("chore: adopt", "Task: DEMO-1", "Change Contract: scope=x, risk=low")
	base := strings.TrimSpace(e.git(e.app, "rev-parse", "HEAD"))
	e.write("AGENTS.md", strings.Replace(readFile(t, filepath.Join(e.app, "AGENTS.md")), "Change workflow", "Changed by hand", 1))
	e.commit("docs: tweak", "Task: DEMO-2", "Change Contract: scope=x, risk=low")
	code, out := e.run("check", "--base", base, "--head", "HEAD")
	if code != ExitBlocked || !strings.Contains(out, "AGENTS.md is changed: generated agent instructions do not match") {
		t.Fatalf("hand-edited generated block must fail the check: %d\n%s", code, out)
	}
}

func TestBlockedRemote(t *testing.T) {
	e := newEnv(t)
	if code, out := e.run("init", "--no-hook", "--agents", ""); code != ExitOK {
		t.Fatal(out)
	}
	path := filepath.Join(e.app, ".intellisense.yml")
	if err := os.WriteFile(path, []byte(strings.Replace(readFile(t, path), "blocked_remotes: []", "blocked_remotes: ['upstream']", 1)), 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	code := Run([]string{"gate", "--dir", e.app, "--pre-push", "upstream", "x"}, strings.NewReader(""), &out, &out)
	if code != ExitBlocked || !strings.Contains(out.String(), "pushing to the \"upstream\" remote") {
		t.Fatalf("push to a blocked remote must be refused: %d %s", code, out.String())
	}
}

func TestHookChainsAnExistingHook(t *testing.T) {
	e := newEnv(t)
	hooks := filepath.Join(e.app, ".git", "hooks")
	if err := os.WriteFile(filepath.Join(hooks, "pre-push"), []byte("#!/bin/sh\necho mine ran >&2\ncat >/dev/null\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	if code, out := e.run("hook", "install"); code != ExitError || !strings.Contains(out, "--chain") {
		t.Fatalf("a foreign hook must not be overwritten without --chain: %d %s", code, out)
	}
	if code, out := e.run("hook", "install", "--chain"); code != ExitOK {
		t.Fatal(out)
	}
	e.write("docs/a.md", "a\n")
	e.commit("docs: a")
	out, err := e.gitErr(e.app, "push", "origin", "main")
	if err != nil || !strings.Contains(out, "mine ran") || !strings.Contains(out, "PASSED") {
		t.Fatalf("both hooks should run: %v\n%s", err, out)
	}
	if code, out := e.run("hook", "uninstall"); code != ExitOK {
		t.Fatal(out)
	}
	if data := readFile(t, filepath.Join(hooks, "pre-push")); strings.Contains(data, hook.Marker) || !strings.Contains(data, "mine ran") {
		t.Fatalf("uninstall should restore the original hook, got:\n%s", data)
	}
}

func TestClassifyPaths(t *testing.T) {
	e := newEnv(t)
	code, out := e.run("classify", "--format", "json", "internal/auth/x.go", "README.md")
	if code != ExitOK || !strings.Contains(out, `"tier": 2`) || !strings.Contains(out, `"reason": "auth/identity"`) {
		t.Fatalf("classify: %d\n%s", code, out)
	}
}

func TestUnknownCommand(t *testing.T) {
	var out bytes.Buffer
	if code := Run([]string{"frobnicate"}, nil, &out, &out); code != ExitError {
		t.Fatalf("exit %d", code)
	}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}
