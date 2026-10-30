---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Go Development Rules

## Naming Conventions

**Export Rule (CRITICAL — defines public API):**
- **Exported identifiers** (public API): `PascalCase` — `UserBalance`, `ReadFile()`, `type User struct`
- **Unexported identifiers** (package-private): `camelCase` — `userBalance`, `readFile()`, `type user struct`

**Specific Rules:**
- **Functions**: `PascalCase` if exported, `camelCase` if unexported
- **Variables**: `PascalCase` if exported, `camelCase` if unexported
- **Constants**: `PascalCase` (idiomatic, NOT `UPPER_SNAKE_CASE`) — `MaxRetries`, `DefaultTimeout`
- **Interfaces**: 1-2 letters OR end in `-er` — `io.Reader`, `http.Handler`, `Writer` (NOT `ReaderInterface`)
- **Receiver names**: 1-2 letters — `func (r *Router)`, `func (db *Database)` (NOT full names)
- **Package names**: lowercase, no underscores — `package http`, `package encoding`
- **Method receivers**: Use single-letter names: `r`, `c`, `db`, `s` (standard Go style)

**Boolean naming** (unexported, so camelCase):
```go
isActive := true
hasPermission := false
canDelete := true
shouldRetry := true
```

---

## Worktree Setup

Go dependencies are managed by `go.mod` and `go.sum` (both committed to repo). After `git worktree add`:

**Verification (no setup required):**
```bash
cd /path/to/worktree && go build ./...
```

Should compile without "missing go.sum" errors. If it fails, check that `go.mod` and `go.sum` are present (they should be).

---

## Framework-Specific Notes
- DO NOT mix different ORM patterns within the same repo (e.g., GORM and Pop/Buffalo ORM).
- Shared library repos: NEVER add business logic. Changes affect ALL downstream consumers.

## Error Handling Patterns

Use `errors.Is()` and `errors.As()` for error type checking:
```go
if err != nil {
  if errors.Is(err, sql.ErrNoRows) {
    // Handle not found
  }
  var dbErr *pq.Error
  if errors.As(err, &dbErr) {
    // Handle DB-specific error
  }
}
```

Error wrapping with context:
```go
if err != nil {
  return fmt.Errorf("context: %w", err)
}
```

## Concurrency & Context

- `context.Context` is the first parameter for ALL service methods.
- Use `ctx.Done()` to detect cancellation before expensive operations.
- Prefer `channel` over `mutex` for goroutine coordination. If using `mutex`, ALWAYS pair with explicit `defer Unlock()`.

## Table-Driven Tests (Canonical Go Test Style)

```go
func TestCalculateFee(t *testing.T) {
  tests := []struct {
    name    string
    input   int
    want    int
    wantErr bool
  }{
    {"basic case", 100, 2, false},
    {"zero input", 0, 0, false},
    {"negative input", -100, 0, true},
  }
  for _, tt := range tests {
    t.Run(tt.name, func(t *testing.T) {
      got, err := CalculateFee(tt.input)
      if (err != nil) != tt.wantErr {
        t.Errorf("want err=%v, got=%v", tt.wantErr, err != nil)
      }
      if got != tt.want {
        t.Errorf("want %d, got %d", tt.want, got)
      }
    })
  }
}
```

## Code Patterns
- Use `errors.Wrap()` or `fmt.Errorf("context: %w", err)` for error wrapping.
- Use `context.Context` as first parameter for all service methods.
- Use `defer` for cleanup (DB connections, file handles, locks).
- Avoid struct embedding unless the embedded type is a true IS-A relationship. Prefer explicit field composition.

## Isolated Real-Persistence Tests for HTTP/DB Code

For changes matching `@rules/operational/ai-regression-patterns.md §P2` (SELECT/projection omission) or §P1 (sandbox/prod divergence): exercise the real handler + real query path. Per `@rules/operational/testing.md §Persistence-Path Rule for Shape/Query Changes`, do NOT mock the database layer for response-shape tests — that hides projection bugs.

**Pattern — handler + in-memory SQLite + value assertion:**
```go
import (
    "database/sql"
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "testing"

    _ "github.com/mattn/go-sqlite3"
)

func TestUserProfileHandler_ReturnsNotificationSettingsValue(t *testing.T) {
    // Arrange — real DB, real schema, real fixture
    db, err := sql.Open("sqlite3", ":memory:")
    if err != nil {
        t.Fatalf("open db: %v", err)
    }
    defer db.Close()
    if _, err := db.Exec(`CREATE TABLE users (
        id INTEGER PRIMARY KEY,
        email TEXT,
        notification_settings TEXT
    )`); err != nil {
        t.Fatalf("schema: %v", err)
    }
    if _, err := db.Exec(`INSERT INTO users(id, email, notification_settings)
        VALUES (1, 'u@x.com', '{"email":true,"sms":false}')`); err != nil {
        t.Fatalf("seed: %v", err)
    }

    // Act — real handler against real DB
    handler := NewUserHandler(db)
    req := httptest.NewRequest(http.MethodGet, "/api/users/1", nil)
    rec := httptest.NewRecorder()
    handler.ServeHTTP(rec, req)

    // Assert — VALUE, not just key. If the handler's SELECT omits
    // notification_settings, the JSON field is "" or missing, and
    // this assertion fails — exposing P2 at test time.
    if rec.Code != http.StatusOK {
        t.Fatalf("status: got %d want 200", rec.Code)
    }
    var got struct {
        NotificationSettings struct {
            Email bool `json:"email"`
            SMS   bool `json:"sms"`
        } `json:"notification_settings"`
    }
    if err := json.NewDecoder(rec.Body).Decode(&got); err != nil {
        t.Fatalf("decode: %v", err)
    }
    if got.NotificationSettings.Email != true {
        t.Errorf("notification_settings.email: got %v want true", got.NotificationSettings.Email)
    }
}
```

For engine-fidelity (Postgres-specific behavior, e.g. `SELECT FOR UPDATE`, JSONB), use `ory/dockertest` instead of in-memory SQLite. The principle is identical: real query path, value assertion.

**Anti-pattern — do NOT use for shape/query changes:**
```go
// ❌ Mocking the repository layer hides P2 entirely.
mockRepo := &MockUserRepo{}
mockRepo.On("GetByID", 1).Return(&User{
    ID: 1,
    NotificationSettings: map[string]bool{"email": true}, // mock RETURNS the field
}, nil)
// Test passes even if the real repo's SELECT omits the column.

// ❌ Asserting only the status code and key existence.
if rec.Code == 200 && bytes.Contains(rec.Body.Bytes(), []byte("notification_settings")) {
    // Passes against {"notification_settings": null} — bug not caught.
}
```

**Rule of thumb:** if the test could pass when the field's value is the zero value, the test does not catch P2. Always assert a non-zero value from the fixture.

