# /tdd — Anti-Patterns and Rationalization Counters

> **Lazy-loaded reference.** SKILL.md (the core /tdd workflow) tells the model when to read this file. Triggers: when about to mock, or when tempted to skip TDD. Loading this file costs ~1,100 tokens.

---

## Why Order Matters (Countering Rationalizations)

Read this when you catch yourself thinking "I'll test after," "I already manually tested," "I'll skip TDD just this once," or any variation thereof. Each row maps a common rationalization to why it fails in practice.

| "I will..." | Why It Fails |
|---|---|
| **"...test after"** | Tests-after verify "what did I build?" Tests-first discover "what should I build?" Tests written after code always pass immediately (prove nothing). |
| **"...manually test"** | Ad-hoc. No record. Can't re-run. You'll re-test every change. Unverified code = technical debt. |
| **"...skip just this once"** | One exception becomes culture. TDD prevents bugs, manual testing finds them (slower, later). |
| **"...keep as reference, test first"** | You'll adapt existing code. That's testing-after. Delete means DELETE. |
| **"...it's too simple"** | Simple code breaks. Test takes 30 seconds. Worth it every time. |
| **"...already spent X hours"** | Sunk cost fallacy. Pick: 2 more hours (TDD, confident) or 30 mins (test-after, bugs later). |
| **"...TDD is dogmatic"** | TDD IS pragmatic. Finds bugs before commit (faster than debugging production). |

---

## When Mocking (Keep Minimal)

Read this BEFORE introducing any mock. The 3 anti-patterns below cover ~90% of mock-related test failures observed across services.

### Anti-Pattern 1: Testing Mock Behavior

❌ **BAD — You're testing the mock exists, not that code works**
```go
mockService := NewMockUserService()
assert.NotNil(t, mockService)  // Asserts mock exists, not behavior
```

✅ **GOOD — Test real behavior with mock dependency**
```go
mockService := NewMockUserService()
user, err := GetUserByID(mockService, "123")

assert.NoError(t, err)
assert.Equal(t, user.ID, "123")  // Tests GetUserByID(), not mock
```

**Gate:** Before asserting on mock — "Am I testing real code behavior or just mock existence?" If just mock existence → delete the assertion or unmock it.

---

### Anti-Pattern 2: Test-Only Methods in Production

❌ **BAD — destroy() only used in tests, pollutes production**
```go
type Session struct{}

func (s *Session) Destroy() error {  // Only called in tests!
    // cleanup
}
```

✅ **GOOD — Cleanup in test utilities, not production**
```go
// tests/testutil.go
func CleanupSession(s *Session) error {
    // cleanup logic
}
```

**Gate:** Before adding method to production code — "Is this only called by tests?" If yes → don't add it. Put in test utilities.

---

### Anti-Pattern 3: Mocking Without Understanding

❌ **BAD — Mock breaks test logic**
```go
mockDB := NewMockDB()
mockDB.SaveConfig = func() error { return nil }  // No-op

err := AddServer(config, mockDB)
err = AddServer(config, mockDB)  // Should fail with duplicate, won't!
```

✅ **GOOD — Mock at correct level, preserve behavior test needs**
```go
mockRegistry := NewMockRegistry()  // Mocks slow registry lookup
mockDB := NewRealDB()              // Real DB for config write

err := AddServer(config, mockDB, mockRegistry)
err = AddServer(config, mockDB, mockRegistry)  // Duplicate detected ✓
```

**Gate:** Before mocking:
1. What side effects does the real method have?
2. Does the test depend on any of those side effects?
3. If yes → mock at a lower level. If unsure → run with real impl first, observe, then mock minimally.

---

## Cross-References

- Core workflow: `skills/tdd/SKILL.md`
- Stuck or about to violate? `skills/tdd/references/troubleshooting.md`
- Stack-specific test patterns: `@rules/operational/ai-regression-patterns.md`
- Persistence-path rule (for shape/query bugs): `@rules/operational/testing.md §Persistence-Path Rule for Shape/Query Changes`
