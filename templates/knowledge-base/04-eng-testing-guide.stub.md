<!-- intellisense: stub — placeholder, safe to overwrite by generate-kb-stubs.sh -->
# Engineering Testing Guide

Test structure, fixtures, coverage targets, and integration test setup.

## Test Structure

<!-- TODO: How tests are organized in this service -->

**Directory layout**:
```
Go:
  handlers/*_test.go       — Unit tests for HTTP handlers
  services/*_test.go       — Unit tests for business logic
  repository/*_test.go     — Integration tests for DB layer
  tests/integration/       — End-to-end integration tests

PHP (Laravel):
  tests/Unit/              — Unit tests for services, models
  tests/Feature/           — Integration tests for routes, jobs
  tests/Fixtures/          — Test data, factories

Angular:
  src/app/**/*.spec.ts     — Unit tests alongside source
  e2e/                     — End-to-end tests
```

## Test Database Setup

<!-- TODO: How test environment is configured -->

**Go (GORM)**:
```bash
# Test database created fresh for each run
go test ./... -v
# Uses TEST_DB_URL env var or in-memory SQLite
```

**PHP (Laravel)**:
```bash
# Tests run with separate DB, migrations applied
php artisan test
# Uses .env.testing database connection
```

**Angular**:
```bash
# Tests use Karma test runner with Chrome headless
ng test --watch=false
```

**Cleanup**: Database rolled back or recreated after each test suite; no state leakage.

---

## AAA Pattern (All Tests)

<!-- TODO: Arrange-Act-Assert pattern -->

**Example**:
```go
func TestInvoiceWithInsufficientBalance(t *testing.T) {
  // Arrange: Set up test data
  user := createTestUser(t, "test@example.com")
  invoice := createTestInvoice(t, user.ID, 100000)

  // Act: Execute the operation
  result, err := service.ProcessInvoice(ctx, invoice.ID)

  // Assert: Verify results
  assert.NotNil(t, err)
  assert.Equal(t, "insufficient_balance", err.Code)
  assert.Nil(t, result)
}
```

---

## Coverage Targets

<!-- TODO: Minimum coverage requirements -->

| Module | Target | Hard Limit |
|--------|--------|-----------|
| handlers/ | 80% | 75% (business logic must be >90%) |
| services/ | 95% | 90% (financial logic must be >95%) |
| repository/ | 80% | 70% (integration test coverage OK) |
| models/ | — | — (no logic, not required) |

**Financial code** (balance mutations, invoice, reconciliation):
- **95% coverage minimum** (no exceptions)
- **Path-based testing**: every decision branch exercised
- **Edge cases**: boundary values (amount = 0, max int64, etc.)

**Command to check coverage**:
```bash
# Go
go test ./... -cover -coverprofile=coverage.out
go tool cover -html=coverage.out

# PHP (Laravel)
php artisan test --coverage
```

---

## Test Data Fixtures

<!-- TODO: How test data is created -->

**Go (using factories)**:
```go
type InvoiceFactory struct{}

func (f *InvoiceFactory) Create(userID int64) *Invoice {
  return &Invoice{
    UserID:      userID,
    AmountCents: 100000,
    Status:      "NEW",
  }
}

func (f *InvoiceFactory) WithStatus(status string) *Invoice {
  s := f.Create(1)
  s.Status = status
  return s
}
```

**PHP (Laravel factories)**:
```php
$invoice = Invoice::factory()->create([
  'user_id' => $user->id,
  'amount_minor_units' => 100000,
  'status' => 'NEW',
]);
```

**Seeding**: Database seeded with minimal required data for each test run.

---

## Mocking Strategy

<!-- TODO: What to mock, what to integrate -->

**MOCK** (isolated unit tests):
- External APIs (Stripe, the external billing system) → use HTTP mocking library
- Email service → mock
- Logging → suppress in tests

**DO NOT MOCK** (integration tests):
- Database → real test DB (provides actual transaction behavior)
- Caching layer (Redis) → real Redis test instance or in-memory mock
- Queue jobs → real queue runner or in-memory runner

**Reason**: Mocks hide integration bugs (e.g., transaction isolation, queue processing failures).

---

## Integration Test Setup

<!-- TODO: How to set up integration tests -->

**Docker Compose** (local dev):
```yaml
services:
  test_db:
    image: postgres:13
    ports:
      - "5433:5432"
    environment:
      POSTGRES_DB: test_db
      POSTGRES_USER: test
      POSTGRES_PASSWORD: test

  test_redis:
    image: redis:6
    ports:
      - "6380:6379"
```

Run: `docker-compose up test_db test_redis`, then `go test ./...`

**CI** (GitHub Actions): Services spun up in GitHub Actions workflow; see `.github/workflows/test.yml`

---

## Performance Test Targets

<!-- TODO: Latency/throughput requirements -->

| Operation | Target Latency | Test |
|-----------|----------------|------|
| Invoice processing | <1s (p95) | `BenchmarkProcessInvoice` |
| Get user balance | <100ms (p95) | `BenchmarkGetBalance` |
| Reconciliation job | <10s (p95) | Integration test with 1000 txns |

**Run benchmarks**:
```bash
go test ./... -bench=. -benchmem
```

---

## Test Naming Convention

<!-- TODO: How test functions are named -->

**Pattern**: `Test{FunctionName}_{Scenario}_{ExpectedOutcome}`

**Examples**:
- `TestProcessInvoice_WithInsufficientBalance_ReturnsError`
- `TestGetUserBalance_WithCacheHit_ReturnsQuickly`
- `TestReconciliationJob_WithMissingTransactions_AlertsOps`

**Why**: Function name is self-documenting; no need for comments.

---

## Continuous Integration

<!-- TODO: CI/CD test execution -->

**On every commit** (pre-commit hook):
- `go test ./...` — Must pass
- `go vet ./...` — Linter warnings

**On PR** (GitHub Actions):
- Full test suite with coverage report
- Benchmark comparison (alert if regression)
- Integration tests (database, Redis, job queue)

**Before merge**:
- Coverage must be ≥80% (≥95% for financial code)
- All tests must pass
- Lint warnings must be addressed
