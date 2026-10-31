---
name: e2e-test
description: Use after integration tests pass, to design and run end-to-end tests of a flow across services, databases and external integrations.
---

# /e2e-test — End-to-End Testing (Phase 4)

**When:** After integration tests pass, before code review (Phase 4 Verification)
**Goal:** Verify multi-service flows work end-to-end, including database, APIs, and external integrations
**Scope:** All services (auth-service, web-app, orders-service, api-gateway, fulfilment-service, reporting-service, etc.)

## The 5-Step E2E Workflow

### Step 1: Design the Test Scenario

Identify ONE complete user flow that exercises your code changes:

**Question:** What is the simplest happy-path flow that uses the new code?

**Characteristics:**
- Spans multiple layers (API → service → database → external integration, if applicable)
- Exercises the critical path only — no error cases yet
- Takes <2 minutes to run
- Uses realistic test data (not synthetic stubs)
- Isolated from other tests (can run in any order)

**Example: User Registration Flow (auth-service)**
- User submits registration form
- API validates input and creates user in database
- Sends welcome email via external service
- Verifies user can log in with new credentials

**Example: Payment Processing Flow (orders-service)**
- User initiates payment
- Service creates transaction record
- External payment gateway returns result
- Database reflects payment status
- For financial checks, see @rules/baseline/security.md and @rules/language-specific/go-patterns.md

### Step 2: Set Up Test Isolation

Ensure the test can run independently without side effects:

**Database isolation:**
- Use test database or transaction rollback after test completes
- Seed predictable test data before each test
- Do NOT rely on data from previous test runs

**External service mocking:**
- Mock external APIs (payment gateways, email services, SMS providers)
- Verify mock is called with correct parameters
- Simulate both success and failure responses

**State isolation:**
- Clear caches between tests (Redis, session storage)
- Reset feature flags to defaults
- Remove test users/records after test completes

**Idempotency check:**
- Can you run this test twice in a row and get the same result both times?
- If no — add cleanup code or improve isolation

---

### Step 3: Execute the Flow and Verify Each Layer

Walk through your scenario step-by-step, verifying at each boundary:

**Step 3a: API Request**
- Send request with valid test data
- Verify HTTP status code (e.g., 201 for create, 200 for success)
- Assert response structure matches documented schema
- No sensitive data exposed in response

**Step 3b: Service Processing**
- Verify service receives correct input
- If side effects expected (email sent, webhook triggered): assert they were called
- If business logic applied (validation, transformation): assert correct behavior

**Step 3c: Database Changes**
- Query database directly after API call completes
- Verify new record exists with correct fields
- Verify relationships intact (foreign keys valid)
- Verify audit fields set correctly (created_at, updated_at, created_by for sensitive changes)

**Step 3d: External Integration**
- If external API mocked: verify mock was called with correct parameters
- If webhook expected: verify webhook payload structure
- If email sent: verify email template rendered correctly with actual data

**Step 3e: Final State Verification**
- User can access the created resource (authorization works)
- Related data reflects the change (counters updated, flags set)
- Timestamp ordering is correct (created_at before updated_at)

---

### Step 4: Test Error Cases and Boundaries

After happy path passes, add tests for failure scenarios:

**Validation errors:**
- Missing required fields
- Invalid input formats (email, phone, amounts)
- Duplicate key violations
- Out-of-bounds values

**Boundary cases:**
- Empty data (zero items, zero amount)
- Maximum allowed data (large arrays, long strings)
- Concurrent requests (two simultaneous operations)

**External service failures:**
- Timeout from external API
- Invalid response from external service
- Network unavailability

**Authorization errors:**
- Unauthenticated user attempts operation
- Authenticated user lacks required role
- Resource belongs to different user/organization

**Example: User Registration Error Cases**
- Register with existing email → 409 Conflict
- Register with invalid email format → 400 Bad Request
- Register with password too short → 400 Bad Request + message
- Two simultaneous registrations with same email → first succeeds, second fails

---

### Step 5: Verify Determinism and Repeatability

Tests must pass consistently every time:

**Flaky test indicators:**
- Test passes 95% of the time but occasionally fails
- Failure depends on execution order (runs after test X but not test Y)
- Failure depends on system time or timing
- Failure depends on external system state (API is slow today)

**Fixing flakiness:**
- If timing issue: increase timeout or add explicit wait for condition
- If isolation issue: improve test setup/teardown
- If external service issue: mock the service instead of calling real API
- If ordering dependency: add setup code to ensure preconditions

**Determinism checklist:**
- [ ] Test uses hardcoded test data, not random values
- [ ] Test does not depend on execution order
- [ ] Test does not depend on current time (use frozen time library if needed)
- [ ] All external services mocked
- [ ] No sleep() calls with fixed delays — use explicit waits instead
- [ ] Test passes every time: run 10 times in a row, should pass all 10

---

## Language-Specific Examples

### Example: Go Service (fulfilment-service)

```go
func TestOrderCreation(t *testing.T) {
  // Setup (test isolation)
  db := setupTestDB(t)
  defer db.Close()
  
  mockPaymentAPI := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    json.NewEncoder(w).Encode(map[string]interface{}{"status": "success"})
  }))
  defer mockPaymentAPI.Close()
  
  // Execute (happy path)
  request := OrderRequest{
    UserID:   "test-user-123",
    Items:    []Item{{ID: "item-1", Quantity: 2}},
    Total:    10000,
  }
  order, err := CreateOrder(context.Background(), request, mockPaymentAPI.URL)
  
  // Verify each layer
  require.NoError(t, err)
  require.Equal(t, "pending", order.Status)
  
  // Verify database
  dbOrder, err := db.GetOrder(order.ID)
  require.NoError(t, err)
  require.Equal(t, "test-user-123", dbOrder.UserID)
  require.NotEmpty(t, dbOrder.CreatedAt)
  
  // Verify error case
  invalidRequest := OrderRequest{UserID: "", Items: []Item{}}
  _, err = CreateOrder(context.Background(), invalidRequest, mockPaymentAPI.URL)
  require.Error(t, err)
  require.Contains(t, err.Error(), "user_id required")
}
```

### Example: Angular Application (web-app)

```typescript
describe('User Registration', () => {
  let fixture: ComponentFixture<RegisterComponent>;
  let mockUserAPI: jasmine.Spy;

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      declarations: [RegisterComponent],
      providers: [
        { provide: UserService, useValue: { register: jasmine.createSpy() } }
      ]
    }).compileComponents();

    fixture = TestBed.createComponent(RegisterComponent);
    mockUserAPI = TestBed.inject(UserService).register;
    mockUserAPI.and.returnValue(of({ id: '123', email: 'test@example.com' }));
  });

  it('creates user and navigates to login', (done) => {
    fixture.componentInstance.form.patchValue({
      email: 'newuser@example.com',
      password: 'SecurePass123!'  // intellisense:allow-secret (test fixture)
    });
    fixture.componentInstance.submit();

    fixture.whenStable().then(() => {
      expect(mockUserAPI).toHaveBeenCalledWith({
        email: 'newuser@example.com',
        password: 'SecurePass123!'  // intellisense:allow-secret (test fixture)
      });
      expect(fixture.componentInstance.router.navigate).toHaveBeenCalledWith(['/login']);
      done();
    });
  });

  it('shows error when email already exists', (done) => {
    mockUserAPI.and.returnValue(throwError(() => new Error('Email already exists')));

    fixture.componentInstance.form.patchValue({
      email: 'existing@example.com',
      password: 'SecurePass123!'  // intellisense:allow-secret (test fixture)
    });
    fixture.componentInstance.submit();

    fixture.whenStable().then(() => {
      expect(fixture.componentInstance.errorMessage).toContain('Email already exists');
      done();
    });
  });
});
```

---

## Financial Services

If your service handles payments, balances, or transactions: apply financial rules from @rules/baseline/security.md → Database Migrations and @rules/language-specific/go-patterns.md → Financial Patterns (atomicity, idempotency, audit trails, webhook signatures).

---

## E2E Test Checklist

Before marking E2E testing complete:

- [ ] Scenario spans multiple layers (API → service → database)
- [ ] Test database or transactions used for isolation
- [ ] External services mocked, not called directly
- [ ] Happy path test runs and passes
- [ ] At least one error case test runs and passes
- [ ] Test is deterministic (passes 10 times in a row)
- [ ] No hardcoded delays — use explicit waits instead
- [ ] Happy path execution time <2 minutes
- [ ] Database state verified after each API call
- [ ] No sensitive data exposed in API responses
- [ ] If financial service: referenced baseline rules applied (security.md, go-patterns.md)

---

## What NOT to Test in E2E

- ❌ Internal function logic (unit tests cover this)
- ❌ Theoretical error cases that can't happen in practice
- ❌ Performance under load (use load testing tools separately)
- ❌ Third-party service internals (mock them instead)
- ❌ Exhaustive input validation combinations (unit tests cover this)

---

## After E2E Testing

1. Verify all tests pass: language-specific test command
2. Verify happy path AND at least one error case passes
3. Run tests 2-3 times to confirm determinism
4. Proceed to Phase 4 code review (`/code-review`)
