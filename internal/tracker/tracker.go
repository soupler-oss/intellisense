// Package tracker checks that a task reference points at a real task in the repository's tracker.
//
// Each tracker is optional and plugged in by `integrations.tracker` in the policy. Verification only runs
// when the policy sets `evidence.verify_tasks: true`; it is the one place Core mode may reach the network, and
// only through the tool or token the team configured:
//
//	beads   `bd show <id>`
//	github  `gh issue view <n>` (or `gh api` for owner/repo#n)
//	jira    GET $JIRA_BASE_URL/rest/api/3/issue/<key>, with $JIRA_EMAIL and $JIRA_API_TOKEN
//	linear  the Linear GraphQL API, with $LINEAR_API_KEY
package tracker

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// Result is what the tracker said about one reference.
type Result int

const (
	Found      Result = iota // the task exists
	NotFound                 // the tracker answered: no such task
	Unverified               // the tracker could not be asked (tool missing, no token, network error)
)

// Verifier checks one task reference. dir is the repository root.
type Verifier func(ctx context.Context, tracker, ref, dir string) (Result, string)

// Verify is the verifier the gate uses; tests replace it.
var Verify Verifier = verify

// IDs splits a trailer value such as "#12, #13" or "PROJ-1 PROJ-2" into references.
func IDs(value string) []string {
	var out []string
	for _, f := range strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == ' ' || r == ';' }) {
		if f = strings.TrimSpace(f); f != "" {
			out = append(out, f)
		}
	}
	return out
}

var (
	githubRef = regexp.MustCompile(`^(?:([\w.-]+/[\w.-]+))?#?(\d+)$`)
	jiraKey   = regexp.MustCompile(`^[A-Z][A-Z0-9]+-\d+$`)
)

func verify(ctx context.Context, tracker, ref, dir string) (Result, string) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	switch tracker {
	case "beads":
		return run(ctx, dir, "bd", "show", ref)
	case "github":
		m := githubRef.FindStringSubmatch(ref)
		if m == nil {
			return NotFound, fmt.Sprintf("%q is not a GitHub issue reference (use #123 or owner/repo#123)", ref)
		}
		if m[1] != "" {
			return run(ctx, dir, "gh", "api", "repos/"+m[1]+"/issues/"+m[2], "--silent")
		}
		return run(ctx, dir, "gh", "issue", "view", m[2], "--json", "number")
	case "jira":
		if !jiraKey.MatchString(ref) {
			return NotFound, fmt.Sprintf("%q is not a Jira issue key (PROJ-123)", ref)
		}
		base, user, token := os.Getenv("JIRA_BASE_URL"), os.Getenv("JIRA_EMAIL"), os.Getenv("JIRA_API_TOKEN")
		if base == "" || user == "" || token == "" {
			return Unverified, "set JIRA_BASE_URL, JIRA_EMAIL and JIRA_API_TOKEN to verify Jira keys"
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(base, "/")+"/rest/api/3/issue/"+ref+"?fields=summary", nil)
		if err != nil {
			return Unverified, err.Error()
		}
		req.SetBasicAuth(user, token)
		return httpStatus(req)
	case "linear":
		key := os.Getenv("LINEAR_API_KEY")
		if key == "" {
			return Unverified, "set LINEAR_API_KEY to verify Linear issues"
		}
		body, _ := json.Marshal(map[string]any{"query": "query($id:String!){issue(id:$id){id}}", "variables": map[string]string{"id": ref}})
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://api.linear.app/graphql", bytes.NewReader(body))
		if err != nil {
			return Unverified, err.Error()
		}
		req.Header.Set("Authorization", key)
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return Unverified, err.Error()
		}
		defer resp.Body.Close()
		var out struct {
			Data struct {
				Issue *struct{ ID string } `json:"issue"`
			} `json:"data"`
			Errors []struct{ Message string } `json:"errors"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
			return Unverified, err.Error()
		}
		if out.Data.Issue != nil {
			return Found, ""
		}
		if len(out.Errors) > 0 && strings.Contains(strings.ToLower(out.Errors[0].Message), "not found") {
			return NotFound, out.Errors[0].Message
		}
		if len(out.Errors) > 0 {
			return Unverified, out.Errors[0].Message
		}
		return NotFound, "Linear has no issue " + ref
	}
	return Unverified, "no tracker configured"
}

func run(ctx context.Context, dir, name string, args ...string) (Result, string) {
	if _, err := exec.LookPath(name); err != nil {
		return Unverified, fmt.Sprintf("%s is not installed", name)
	}
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err == nil {
		return Found, ""
	}
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		msg := strings.ToLower(string(out))
		if strings.Contains(msg, "auth") || strings.Contains(msg, "login") || strings.Contains(msg, "network") {
			return Unverified, firstLine(string(out))
		}
		return NotFound, firstLine(string(out))
	}
	return Unverified, err.Error()
}

func httpStatus(req *http.Request) (Result, string) {
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return Unverified, err.Error()
	}
	resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusOK:
		return Found, ""
	case resp.StatusCode == http.StatusNotFound:
		return NotFound, "not found"
	}
	return Unverified, resp.Status
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	return s
}
