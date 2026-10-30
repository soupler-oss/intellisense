# /tdd — Troubleshooting and Red Flags

> **Lazy-loaded reference.** SKILL.md (the core /tdd workflow) tells the model when to read this file. Triggers: when stuck, when same test fails 3+ times, when tempted to edit a test, or when retry/regression bound exhausts. Loading this file costs ~450 tokens.

---

## When Stuck

| Problem | Action |
|---------|--------|
| Don't know how to test it | Write the wished-for API call. Write the assertion first. Reverse-engineer setup. |
| Test feels too complicated | Design is too complicated. Simplify the function under test, then revisit. |
| Need to mock everything | Code is too coupled. Add dependency injection or move to a port. |
| Test setup is huge | Extract test helpers. Still huge → simplify the design. |
| Test is hard to write | The function will be hard to use. Listen to the test. |
| Same test failing 3+ times | Stop. Re-read the failure. You're pattern-matching, not reasoning. Use Retry Bound (Step 3 of SKILL.md). |
| Want to change the test | Stop. Either the test is wrong (back to Step 1) or the impl is. Never both. |
| Hit retry/regression bound | That's the rule firing correctly. Emit `TDD-RETRY-EXHAUSTED` diagnostic, halt slice. Don't push through. |

---

## Red Flags — STOP & DELETE CODE, START OVER

If ANY of these happen, you've violated TDD. Delete code. Start over.

- [ ] Code written before test
- [ ] Test that passes immediately
- [ ] Can't explain why test failed
- [ ] "I'll test after" (tests-after pass immediately, prove nothing)
- [ ] "Already manually tested" (ad-hoc, not systematic)
- [ ] "Too simple to test" (simple code breaks, takes 30s)
- [ ] "Deleting is wasteful" (sunk cost fallacy)
- [ ] "Keep as reference" (you'll adapt it, that's testing-after)
- [ ] "Need to explore first" (explore, DELETE exploration, start TDD)
- [ ] Testing mock behavior instead of real code
- [ ] Test-only methods in production code
- [ ] Mocking without understanding dependencies
- [ ] Editing the test to match implementation
- [ ] Pushing through a retry/regression bound exhaustion

---

## Cross-References

- Core workflow: `skills/tdd/SKILL.md`
- About to mock? Read first: `skills/tdd/references/anti-patterns.md`
- Rationalizing skipping TDD? Read: `skills/tdd/references/anti-patterns.md` → "Why Order Matters"
