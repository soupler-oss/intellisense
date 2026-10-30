---
applies_to: [all]
phase: [0, 1, 2, 3, 4, 5, 6]
priority: LOW
enforcement: advisory
load_when: always
---

# Your Organization's Rules

This directory is the one place org-specific, proprietary content belongs —
financial domain rules (currency handling, your billing system's specifics),
compliance requirements, internal tooling conventions, anything that
shouldn't live in the portable framework because it's true of your
organization and not of intellisense generally.

Nothing is pre-populated here. `scripts/validate-intellisense-content.sh`'s
genericness guard (`validate_no_org_specific_literals`) treats this directory
as the sanctioned exception — content here is expected to be specific,
everywhere else in `rules/` is expected to stay generic.

Two examples of what belongs here once you have a real equivalent:

- **Currency handling** — the framework's guidance is generic ("smallest
  currency unit, integer only, never float"); your organization's actual
  currency, subunit name, and rounding rules go here.
- **External billing / finance systems** — name your actual system(s) and
  their integration constraints here, in place of the framework's generic
  "external billing system" placeholder.

Files added here follow the same frontmatter and token-budget conventions as
the rest of `rules/` (see `scripts/validate-intellisense-content.sh`).
