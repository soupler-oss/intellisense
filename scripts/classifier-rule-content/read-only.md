# Read-only / analysis request

This prompt is classified read-only (design_review_only / pr_review / qa). **No
Change Contract, task reference, or approval artifacts are required — nothing is
being edited.** Do not inject edit-ceremony or block on it.

The risk tier is preserved for audit/escalation. If the discussion concerns
auth / payment / migration / security code, keep `security.md` boundaries in
mind while analysing. The moment the request turns into an actual edit, the
PreToolUse contract gate re-applies the tier's normal enforcement on its own —
this read-only note does not weaken that gate.
