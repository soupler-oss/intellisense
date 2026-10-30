package policy

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Stack ties a stack name to its rule file and the files that rule applies to.
//
// Built-in stacks ship their rule inside the binary. A custom stack (`custom_stacks:` in the policy) names a
// rule file the repository keeps under .intellisense/rules/language-specific/ itself, so adding a language
// needs no change to intellisense.
type Stack struct {
	Name string `yaml:"name"`
	// Rule is the file under rules/language-specific/.
	Rule string `yaml:"rule"`
	// Dir is an optional directory of sub-rules next to Rule (Java keeps its detail in java/).
	Dir string `yaml:"dir,omitempty"`
	// Globs are the files the rule applies to, for agents that scope instructions by path.
	Globs []string `yaml:"globs"`
	// Markers are files at the repository root whose presence means the stack is in use. A marker may be a
	// glob ("*.csproj").
	Markers []string `yaml:"markers,omitempty"`
	// Custom is set for a stack the policy defines.
	Custom bool `yaml:"-"`
}

var stacks = []Stack{
	{Name: "go", Rule: "go-patterns.md", Globs: []string{"**/*.go"}, Markers: []string{"go.mod"}},
	{Name: "php", Rule: "laravel-patterns.md", Globs: []string{"**/*.php"}, Markers: []string{"composer.json"}},
	{Name: "angular", Rule: "angular-patterns.md", Globs: []string{"**/*.ts", "**/*.html", "**/*.scss"}, Markers: []string{"angular.json"}},
	{Name: "react", Rule: "react-patterns.md", Globs: []string{"**/*.tsx", "**/*.jsx", "**/*.ts", "**/*.js"}},
	{Name: "node", Rule: "node-patterns.md", Globs: []string{"**/*.js", "**/*.mjs", "**/*.cjs", "**/*.ts"}},
	{Name: "python", Rule: "python-patterns.md", Globs: []string{"**/*.py"}, Markers: []string{"pyproject.toml", "requirements.txt", "setup.py"}},
	{Name: "java", Rule: "java-patterns.md", Dir: "java", Globs: []string{"**/*.java", "**/*.kt", "**/pom.xml", "**/*.gradle", "**/*.gradle.kts"}, Markers: []string{"pom.xml", "build.gradle", "build.gradle.kts"}},
	{Name: "flutter", Rule: "flutter-patterns.md", Globs: []string{"**/*.dart"}, Markers: []string{"pubspec.yaml"}},
	{Name: "rust", Rule: "rust-patterns.md", Globs: []string{"**/*.rs"}, Markers: []string{"Cargo.toml"}},
	{Name: "csharp", Rule: "csharp-patterns.md", Globs: []string{"**/*.cs", "**/*.csproj"}, Markers: []string{"*.sln", "*.csproj", "global.json"}},
	{Name: "ruby", Rule: "ruby-patterns.md", Globs: []string{"**/*.rb", "**/*.erb"}, Markers: []string{"Gemfile"}},
	{Name: "swift", Rule: "swift-patterns.md", Globs: []string{"**/*.swift"}, Markers: []string{"Package.swift", "*.xcodeproj"}},
	{Name: "cpp", Rule: "cpp-patterns.md", Globs: []string{"**/*.c", "**/*.h", "**/*.cc", "**/*.cpp", "**/*.hpp"}, Markers: []string{"CMakeLists.txt", "meson.build"}},
}

var stackAliases = map[string]string{
	"laravel": "php", "golang": "go", "kotlin": "java", "dart": "flutter", "typescript": "node", "javascript": "node",
	"c#": "csharp", "dotnet": "csharp", ".net": "csharp", "rails": "ruby", "ios": "swift", "c++": "cpp", "c": "cpp",
}

// LookupStack resolves a built-in stack name or alias.
func LookupStack(name string) (Stack, bool) {
	name = strings.ToLower(strings.TrimSpace(name))
	if a, ok := stackAliases[name]; ok {
		name = a
	}
	for _, s := range stacks {
		if s.Name == name {
			return s, true
		}
	}
	return Stack{}, false
}

// StackNames lists the built-in stacks.
func StackNames() []string {
	names := make([]string, len(stacks))
	for i, s := range stacks {
		names[i] = s.Name
	}
	return names
}

// Stack resolves a stack the policy can use: one of its custom stacks, else a built-in one.
func (p *Policy) Stack(name string) (Stack, bool) {
	for _, s := range p.CustomStacks {
		if strings.EqualFold(s.Name, strings.TrimSpace(name)) {
			s.Custom = true
			return s, true
		}
	}
	return LookupStack(name)
}

// AllStacks lists the built-in stacks followed by the policy's custom ones.
func (p *Policy) AllStacks() []Stack {
	out := append([]Stack(nil), stacks...)
	for _, s := range p.CustomStacks {
		s.Custom = true
		out = append(out, s)
	}
	return out
}

func (p *Policy) validateStacks(add func(string, ...any)) {
	seen := map[string]bool{}
	for i, s := range p.CustomStacks {
		where := "custom_stacks[" + strconv.Itoa(i) + "]"
		switch {
		case !fieldName.MatchString(s.Name):
			add("%s: name %q must be lower-case letters, digits and _", where, s.Name)
		case seen[s.Name]:
			add("%s: stack %q is defined twice", where, s.Name)
		}
		if _, builtin := LookupStack(s.Name); builtin {
			add("%s: %q is a built-in stack; use stacks: [%s] or pick another name", where, s.Name, s.Name)
		}
		seen[s.Name] = true
		if !strings.HasSuffix(s.Rule, ".md") || strings.Contains(s.Rule, "/") {
			add("%s (%s): rule must be a .md file name under .intellisense/rules/language-specific/", where, s.Name)
		}
		if len(s.Globs) == 0 {
			add("%s (%s): globs must name the files the rule applies to, e.g. ['**/*.rs']", where, s.Name)
		}
		if s.Dir != "" {
			add("%s (%s): dir is only for built-in stacks", where, s.Name)
		}
	}
	for _, s := range p.Stacks {
		if _, ok := p.Stack(s); !ok {
			add("unknown stack %q (built-in: %s; or define it under custom_stacks)", s, strings.Join(StackNames(), ", "))
		}
	}
}

// DetectStacks guesses a repository's built-in stacks from the files at its root.
func DetectStacks(root string) []string { return detect(root, stacks) }

// DetectStacks guesses a repository's stacks, its custom stacks included.
func (p *Policy) DetectStacks(root string) []string { return detect(root, p.AllStacks()) }

func detect(root string, all []Stack) []string {
	found := map[string]bool{}
	exists := func(marker string) bool {
		if strings.ContainsAny(marker, "*?[") {
			m, _ := filepath.Glob(filepath.Join(root, marker))
			return len(m) > 0
		}
		_, err := os.Stat(filepath.Join(root, marker))
		return err == nil
	}
	for _, s := range all {
		for _, m := range s.Markers {
			if exists(m) {
				found[s.Name] = true
			}
		}
	}
	if pkg, err := os.ReadFile(filepath.Join(root, "package.json")); err == nil && !found["angular"] {
		if strings.Contains(string(pkg), `"react"`) {
			found["react"] = true
		} else {
			found["node"] = true
		}
	}
	out := make([]string, 0, len(found))
	for n := range found {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}
