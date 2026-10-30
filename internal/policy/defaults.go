package policy

func ptr(f float64) *float64 { return &f }

// Default is the policy a repository gets before it writes .intellisense.yml.
//
// Tier 2 for auth, money, migrations, secrets and the governance policy itself; Tier 1 for CI,
// infrastructure, dependencies and agent instructions; Tier 0 for docs and tests. A file no rule matches is
// default_tier (1), and a comment-only diff of such a file drops to Tier 0.
func Default() *Policy {
	p := &Policy{
		Version:        CurrentVersion,
		Stacks:         []string{},
		Agents:         []string{},
		Skills:         []string{},
		MinimumTier:    0,
		DefaultTier:    1,
		FastLane:       true,
		Secrets:        SecretsWarn,
		BlockedRemotes: []string{},
		Tiers: []Tier{
			{Level: 2, Name: "high risk", Requires: []string{EvidenceTask, EvidenceContract}, Rules: []Rule{
				{Pattern: `(^|/)([Aa]uth|[Oo]auth|[Aa]uthentication|[Aa]uthorization|jwt|JWT|sso|SSO)([._/-]|$)`, Reason: "auth/identity"},
				{Pattern: `(^|/)([Pp]ayments?|[Bb]illing|[Aa]ccounts?|[Jj]ournal|[Ii]nvoices?|[Ff]inancial)([._/-]|$)`, Reason: "financial"},
				{Pattern: `(^|/)[Mm]igrations?/.+\.(sql|py|rb|php|go|js|ts|java|kt|xml|ya?ml)$`, Reason: "database migration"},
				{Pattern: `(^|/)([Ss]ecrets?|[Cc]redentials?|[Cc]rypto|[Ee]ncryption)([._/-]|$)`, Reason: "secrets/crypto"},
				{Pattern: `^\.intellisense\.yml$`, Reason: "governance policy"},
				{Pattern: `^\.intellisense/rules/baseline/`, Reason: "baseline rule"},
			}},
			{Level: 1, Name: "standard", Requires: []string{EvidenceTask, EvidenceContract}, Rules: []Rule{
				{Pattern: `^\.github/workflows/`, Reason: "CI/CD"},
				{Pattern: `(^|/)(\.gitlab-ci\.yml|Jenkinsfile|azure-pipelines\.yml)$`, Reason: "CI/CD"},
				{Pattern: `(^|/)Dockerfile[^/]*$`, Reason: "container"},
				{Pattern: `(^|/)(docker-)?compose[^/]*\.ya?ml$`, Reason: "container"},
				{Pattern: `(^|/)(infra|infrastructure|terraform|deploy|deployment|k8s|kubernetes|helm|charts)/`, Reason: "infrastructure"},
				{Pattern: `\.tf$`, Reason: "infrastructure"},
				{Pattern: `(^|/)(go\.(mod|sum)|package(-lock)?\.json|pnpm-lock\.yaml|yarn\.lock|requirements[^/]*\.txt|pyproject\.toml|poetry\.lock|uv\.lock|composer\.(json|lock)|pom\.xml|build\.gradle(\.kts)?|settings\.gradle(\.kts)?|Gemfile(\.lock)?|Cargo\.(toml|lock)|pubspec\.(yaml|lock)|[^/]+\.csproj|Package\.(swift|resolved))$`, Reason: "dependencies"},
				{Pattern: `^\.intellisense/`, Reason: "governance rules"},
				{Pattern: `^(AGENTS|CLAUDE)\.md$`, Reason: "agent instructions"},
				{Pattern: `^\.github/(copilot-instructions\.md|instructions/)`, Reason: "agent instructions"},
				{Pattern: `^\.cursor/rules/`, Reason: "agent instructions"},
				{Pattern: `^\.claude/`, Reason: "agent instructions"},
				{Pattern: `^\.github/CODEOWNERS$`, Reason: "ownership"},
			}},
			{Level: 0, Name: "routine", Requires: []string{}, Rules: []Rule{
				{Pattern: `\.(md|MD|markdown|rst|txt|adoc)$`, Reason: "documentation"},
				{Pattern: `(^|/)docs?/`, Reason: "documentation"},
				{Pattern: `(^|/)(README|CHANGELOG|LICENSE|NOTICE|CONTRIBUTING)[^/]*$`, Reason: "documentation"},
				{Pattern: `(^|/)(tests?|__tests__|specs?|testdata|fixtures)/`, Reason: "tests"},
				{Pattern: `_test\.(go|py)$`, Reason: "tests"},
				{Pattern: `(^|/)test_[^/]+\.py$`, Reason: "tests"},
				{Pattern: `\.(test|spec)\.[cm]?[jt]sx?$`, Reason: "tests"},
				{Pattern: `(Test|Tests|Spec)\.(java|kt|php|cs|swift)$`, Reason: "tests"},
				{Pattern: `_spec\.rb$`, Reason: "tests"},
				{Pattern: `(^|/)test[^/]*\.sh$`, Reason: "tests"},
			}},
		},
		Evidence: Evidence{
			TaskTrailers: []string{"Task", "Refs", "Beads"},
			Contract: Contract{
				Marker: "Change Contract",
				Paths:  []string{".intellisense/contracts/"},
				Fields: []Field{
					{Name: "scope", Required: true},
					{Name: "risk", Required: true, Values: []string{"low", "medium", "high"}},
					{Name: "confidence", Type: FieldNumber, Min: ptr(0), Max: ptr(1)},
					{Name: "files_affected", Type: FieldInteger, Min: ptr(0)},
					{Name: "estimated_lines", Type: FieldInteger, Min: ptr(0)},
				},
			},
			TestPatterns: []Rule{
				{Pattern: `(^|/)(tests?|__tests__|specs?|testdata)/`, Reason: "test directory"},
				{Pattern: `(_test\.(go|py)|\.(test|spec)\.[cm]?[jt]sx?|(Test|Tests|Spec)\.(java|kt|php|cs|swift)|_spec\.rb)$`, Reason: "test file"},
				{Pattern: `(^|/)test_[^/]+\.py$`, Reason: "test file"},
			},
		},
		CustomStacks: []Stack{},
		Integrations: Integrations{Tracker: "none", CodeIntel: "none"},
		Rules:        RuleSettings{Disable: []string{}},
	}
	if err := p.Validate(); err != nil {
		panic("default policy: " + err.Error())
	}
	return p
}
