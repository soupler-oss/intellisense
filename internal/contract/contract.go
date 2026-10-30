// Package contract reads and checks change contracts.
//
// A contract is a set of key=value fields describing a change: what it touches, how risky it is, how sure the
// author is. It lives either on one commit-message line:
//
//	Change Contract: scope=refund API, risk=high, confidence=0.8
//
// or in a Markdown file under one of the policy's contract paths, with the fields as YAML front matter:
//
//	---
//	scope: refund API
//	risk: high
//	confidence: 0.8
//	---
//	# Change contract: refund API
//	...
//
// The policy's evidence.contract.fields say which fields are required and what each may hold, so a team
// changes the contract format in .intellisense.yml, not in code.
package contract

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"gopkg.in/yaml.v3"

	"github.com/soupler-oss/intellisense/internal/policy"
)

// Fields are a contract's values, by field name.
type Fields map[string]string

// Line returns the text after "<marker>:" on the first commit-message line that starts with the marker.
func Line(msg, marker string) (string, bool) {
	for _, line := range strings.Split(msg, "\n") {
		line = strings.TrimSpace(line)
		if len(line) <= len(marker) || !strings.EqualFold(line[:len(marker)], marker) {
			continue
		}
		rest := strings.TrimSpace(line[len(marker):])
		if strings.HasPrefix(rest, ":") {
			return strings.TrimSpace(rest[1:]), true
		}
	}
	return "", false
}

// ParseLine reads "key=value, key=value". A part without "=" is ignored, so free text is allowed.
func ParseLine(body string) Fields {
	f := Fields{}
	for _, part := range strings.Split(body, ",") {
		k, v, ok := strings.Cut(strings.TrimSpace(part), "=")
		if !ok {
			continue
		}
		if k = strings.ToLower(strings.TrimSpace(k)); k != "" {
			f[k] = strings.TrimSpace(v)
		}
	}
	return f
}

// ParseMarkdown reads a contract file: its front matter, or failing that a marker line in the text. found is
// false when the file holds neither.
func ParseMarkdown(data []byte, marker string) (fields Fields, found bool, err error) {
	text := strings.ReplaceAll(string(data), "\r\n", "\n")
	if strings.HasPrefix(text, "---\n") {
		if end := strings.Index(text[4:], "\n---"); end >= 0 {
			raw := map[string]any{}
			if err := yaml.Unmarshal([]byte(text[4:4+end]), &raw); err != nil {
				return nil, true, fmt.Errorf("front matter is not valid YAML: %v", err)
			}
			f := Fields{}
			for k, v := range raw {
				f[strings.ToLower(k)] = scalar(v)
			}
			// Live mode's contract fields name the same things: requirement is the scope, risk_level the risk.
			for alias, name := range map[string]string{"requirement": "scope", "risk_level": "risk"} {
				if f[name] == "" && f[alias] != "" {
					f[name] = f[alias]
				}
			}
			return f, true, nil
		}
	}
	if body, ok := Line(text, marker); ok {
		return ParseLine(body), true, nil
	}
	return nil, false, nil
}

func scalar(v any) string {
	switch t := v.(type) {
	case nil:
		return ""
	case string:
		return strings.TrimSpace(t)
	case []any:
		parts := make([]string, len(t))
		for i, x := range t {
			parts[i] = scalar(x)
		}
		return strings.Join(parts, ", ")
	}
	return strings.TrimSpace(fmt.Sprint(v))
}

// Validate checks fields against the policy's contract spec. Fields the spec does not name are free-form.
func Validate(f Fields, spec policy.Contract) error {
	var errs []string
	for _, field := range spec.Fields {
		v, ok := f[field.Name]
		if !ok || v == "" || isPlaceholder(v) {
			if field.Required {
				errs = append(errs, fmt.Sprintf("%s is required", field.Name))
			}
			continue
		}
		if err := check(field, v); err != nil {
			errs = append(errs, err.Error())
		}
	}
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	return nil
}

func check(field policy.Field, v string) error {
	switch field.Type {
	case policy.FieldNumber, policy.FieldInteger:
		var n float64
		if field.Type == policy.FieldInteger {
			i, err := strconv.Atoi(v)
			if err != nil {
				return fmt.Errorf("%s must be a whole number (got %q)", field.Name, v)
			}
			n = float64(i)
		} else {
			f, err := strconv.ParseFloat(v, 64)
			if err != nil {
				return fmt.Errorf("%s must be a number (got %q)", field.Name, v)
			}
			n = f
		}
		if (field.Min != nil && n < *field.Min) || (field.Max != nil && n > *field.Max) {
			return fmt.Errorf("%s must be %s (got %q)", field.Name, rangeText(field), v)
		}
	default:
		if len(field.Values) > 0 {
			for _, allowed := range field.Values {
				if strings.EqualFold(v, allowed) {
					return nil
				}
			}
			return fmt.Errorf("%s must be %s (got %q)", field.Name, strings.Join(field.Values, ", "), v)
		}
	}
	return nil
}

func rangeText(f policy.Field) string {
	n := func(x float64) string { return strconv.FormatFloat(x, 'f', -1, 64) }
	switch {
	case f.Min != nil && f.Max != nil:
		return "from " + n(*f.Min) + " to " + n(*f.Max)
	case f.Min != nil:
		return "at least " + n(*f.Min)
	case f.Max != nil:
		return "at most " + n(*f.Max)
	}
	return "a " + f.Type
}

// placeholder matches the template's unfilled values, so an untouched template never passes.
var placeholder = regexp.MustCompile(`^<[^>]*>$|^TODO\b`)

func isPlaceholder(v string) bool { return placeholder.MatchString(strings.TrimSpace(v)) }

// Example is a valid commit-message line for spec, for error messages and docs.
func Example(spec policy.Contract) string {
	var parts []string
	for _, f := range spec.Fields {
		if !f.Required && len(parts) >= 2 {
			continue
		}
		parts = append(parts, f.Name+"="+sample(f))
	}
	if len(parts) == 0 {
		parts = []string{"scope=<what changes>"}
	}
	return spec.Marker + ": " + strings.Join(parts, ", ")
}

func sample(f policy.Field) string {
	switch {
	case len(f.Values) > 0:
		return strings.Join(f.Values, "|")
	case f.Type == policy.FieldNumber:
		if f.Max != nil && *f.Max <= 1 {
			return "0.8"
		}
		return "1"
	case f.Type == policy.FieldInteger:
		return "3"
	}
	return "<" + strings.ReplaceAll(f.Name, "_", " ") + ">"
}

// Template is the built-in contract file for spec: every field as front matter, then sections to fill in.
func Template(spec policy.Contract) string {
	var b strings.Builder
	b.WriteString("---\n")
	for _, f := range spec.Fields {
		hint := ""
		switch {
		case len(f.Values) > 0:
			hint = "one of: " + strings.Join(f.Values, ", ")
		case f.Type != "" && f.Type != policy.FieldString:
			hint = f.Type
			if f.Min != nil || f.Max != nil {
				hint += " " + rangeText(f)
			}
		}
		req := "optional"
		if f.Required {
			req = "required"
		}
		if hint != "" {
			req += "; " + hint
		}
		fmt.Fprintf(&b, "%s: '<%s>'   # %s\n", f.Name, strings.ReplaceAll(f.Name, "_", " "), req)
	}
	b.WriteString("---\n\n")
	fmt.Fprintf(&b, "# %s: {{title}}\n\n", spec.Marker)
	b.WriteString("## What changes\n\n<!-- The behaviour this change adds or alters, and the files it touches. -->\n\n")
	b.WriteString("## Why\n\n<!-- The task or problem this solves. -->\n\n")
	b.WriteString("## Risk and rollback\n\n<!-- What could break, who would notice, and how to undo it. -->\n\n")
	b.WriteString("## How it is verified\n\n<!-- The tests that prove it, and what they show. -->\n")
	return b.String()
}

var slugChars = regexp.MustCompile(`[^a-z0-9]+`)

// Slug turns a title into a file-name part.
func Slug(title string) string {
	s := strings.Trim(slugChars.ReplaceAllString(strings.ToLower(title), "-"), "-")
	if len(s) > 60 {
		s = strings.TrimRight(s[:60], "-")
	}
	if s == "" {
		s = "change"
	}
	return s
}

// New writes a contract file for title into the first contract path, from the policy's template (or the
// built-in one), and returns its repo-relative path.
func New(root string, p *policy.Policy, title string, now time.Time) (string, error) {
	spec := p.Evidence.Contract
	if len(spec.Paths) == 0 {
		return "", errors.New("the policy has no evidence.contract.paths to write a contract file into")
	}
	body := Template(spec)
	if spec.Template != "" {
		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(spec.Template)))
		if err != nil {
			return "", fmt.Errorf("contract template: %w", err)
		}
		body = string(data)
	}
	body = strings.ReplaceAll(body, "{{title}}", title)
	body = strings.ReplaceAll(body, "{{date}}", now.Format("2006-01-02"))
	rel := strings.TrimSuffix(spec.Paths[0], "/") + "/" + now.Format("2006-01-02") + "-" + Slug(title) + ".md"
	abs := filepath.Join(root, filepath.FromSlash(rel))
	if _, err := os.Stat(abs); err == nil {
		return "", fmt.Errorf("%s already exists", rel)
	}
	if err := os.MkdirAll(filepath.Dir(abs), 0o755); err != nil {
		return "", err
	}
	return rel, os.WriteFile(abs, []byte(body), 0o644)
}

// Describe lists the fields of spec in words, for `intellisense contract fields`.
func Describe(spec policy.Contract) []string {
	var out []string
	for _, f := range spec.Fields {
		line := f.Name
		if f.Required {
			line += " (required)"
		}
		switch {
		case len(f.Values) > 0:
			line += ": one of " + strings.Join(f.Values, ", ")
		case f.Type == policy.FieldNumber || f.Type == policy.FieldInteger:
			line += ": " + f.Type
			if f.Min != nil || f.Max != nil {
				line += " " + rangeText(f)
			}
		default:
			line += ": text"
		}
		out = append(out, line)
	}
	sort.SliceStable(out, func(i, j int) bool {
		return strings.Contains(out[i], "(required)") && !strings.Contains(out[j], "(required)")
	})
	return out
}

// splitFront returns a Markdown file's front matter (without the --- lines) and the rest, or ok=false.
func splitFront(text string) (front, rest string, ok bool) {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	if !strings.HasPrefix(text, "---\n") {
		return "", text, false
	}
	end := strings.Index(text[4:], "\n---")
	if end < 0 {
		return "", text, false
	}
	front = text[4 : 4+end]
	rest = strings.TrimPrefix(text[4+end+4:], "\n")
	return front, rest, true
}

// FrontMatter decodes a contract file's front matter with its types (lists, numbers, booleans) intact, for
// tools that need more than the string fields Validate checks — Live mode's validator reads it as JSON.
func FrontMatter(data []byte) (map[string]any, error) {
	front, _, ok := splitFront(string(data))
	if !ok {
		return nil, errors.New("no front matter (the file must start with ---)")
	}
	out := map[string]any{}
	if err := yaml.Unmarshal([]byte(front), &out); err != nil {
		return nil, fmt.Errorf("front matter is not valid YAML: %v", err)
	}
	return out, nil
}

// Set changes one front-matter key in a contract file, keeping the other keys, their order and the body.
// value is decoded as YAML, so `state=active`, `estimated_lines=40` and `files_affected=[a.go, b.go]` keep
// their types.
func Set(data []byte, key, value string) ([]byte, error) {
	front, rest, ok := splitFront(string(data))
	if !ok {
		return nil, errors.New("no front matter to update (the file must start with ---)")
	}
	var doc yaml.Node
	if err := yaml.Unmarshal([]byte(front), &doc); err != nil {
		return nil, fmt.Errorf("front matter is not valid YAML: %v", err)
	}
	if len(doc.Content) == 0 {
		doc = yaml.Node{Kind: yaml.DocumentNode, Content: []*yaml.Node{{Kind: yaml.MappingNode}}}
	}
	m := doc.Content[0]
	if m.Kind != yaml.MappingNode {
		return nil, errors.New("front matter is not a mapping")
	}
	var val yaml.Node
	if err := yaml.Unmarshal([]byte(value), &val); err != nil || len(val.Content) == 0 {
		val = yaml.Node{Kind: yaml.DocumentNode, Content: []*yaml.Node{{Kind: yaml.ScalarNode, Value: value}}}
	}
	v := val.Content[0]
	if v.Kind == yaml.MappingNode || v.Kind == yaml.SequenceNode {
		v.Style = yaml.FlowStyle
	}
	replaced := false
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			m.Content[i+1] = v
			replaced = true
			break
		}
	}
	if !replaced {
		m.Content = append(m.Content, &yaml.Node{Kind: yaml.ScalarNode, Value: key}, v)
	}
	var b strings.Builder
	enc := yaml.NewEncoder(&b)
	enc.SetIndent(2)
	if err := enc.Encode(m); err != nil {
		return nil, err
	}
	out := "---\n" + b.String() + "---\n"
	if rest != "" {
		out += rest
	}
	return []byte(out), nil
}
