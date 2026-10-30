// Package intellisense exposes the files the CLI ships with: the portable rule set that
// `intellisense init` vendors into a repository, the skills, the Live-mode platform that
// `intellisense live install` unpacks, and the release version.
package intellisense

import (
	"embed"
	"strings"
)

// Rules holds rules/baseline, rules/operational and rules/language-specific as they are in this repository.
//
//go:embed rules/baseline rules/operational rules/language-specific
var Rules embed.FS

// Skills holds the Claude Code skills (skills/<name>/...).
//
//go:embed skills
var Skills embed.FS

// Platform is Live mode: the installer and everything it links into ~/.claude.
//
//go:embed setup.sh setup-repos.sh verify-setup.sh restore.sh VERSION .claude/settings.json.template
//go:embed all:scripts all:hooks all:hook-packs all:agents all:templates all:infrastructure all:skills all:rules
var Platform embed.FS

//go:embed VERSION
var version string

// Version is the release version from the VERSION file.
func Version() string { return strings.TrimSpace(version) }
