---
applies_to: [full_feature, bug_fix]
phase: [2, 3, 4, 5, 6]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Coding Style Rules

## Immutability (Language-Dependent)

**Principle:** Immutability is a language-specific concern. Enforce where the language idiom supports it. Do not force it against language conventions.

**Examples and stack-specific patterns:**
- See go-patterns.md — Go pointer semantics and mutability
- See laravel-patterns.md — PHP Eloquent model mutability
- See angular-patterns.md — TypeScript/JavaScript immutability in state management

---

## Core Principles & Conflict Resolution

### KISS (Keep It Simple)
- Prefer the simplest solution that actually works
- Avoid premature optimization

### DRY (Don't Repeat Yourself)
- Extract repeated logic into shared functions or utilities
- Introduce abstractions when repetition is real, not speculative

### YAGNI (You Aren't Gonna Need It)
- Do not build features or abstractions before they are needed
- Start simple, then refactor when the pressure is real

**Resolving Principle Conflicts** (when they collide):

| Scenario | Winner | Reason |
|----------|--------|--------|
| First occurrence of duplication | YAGNI > DRY | Write twice before extracting. Premature extraction = accidental complexity. |
| Extraction adds more complexity | KISS > DRY | If a helper abstraction makes code harder to follow, keep it simple (duplicate). |
| 3+ identical occurrences | DRY > YAGNI | Extract to avoid maintenance burden across codebase. |
| Architectural boundary exists | DRY > both | Some duplication across services is acceptable if extraction creates coupling. |

---

## File Organization

**Baseline:** Prefer smaller, focused files and functions. Language-specific limits apply (see below).

**Generic constraints:**
- No deep nesting beyond 4 levels — use early returns or extract helper functions
- Single responsibility per file — if you're describing a file with "and," consider splitting

**Language-Specific Limits:** (See language-specific rules for details)
- **Go**: Handlers/routers may exceed 50-line function size. See go-patterns.md.
- **PHP/Laravel**: Models are intentionally small (often 50-100 lines). Controllers/services vary. See laravel-patterns.md.
- **Angular**: Components follow Angular CLI conventions. Avoid >400-line components. See angular-patterns.md.

**When in doubt:** Prefer splitting. Smaller, focused files are easier to test, review, and maintain.

---

## Single Responsibility

- One responsibility per function. If you need "and" to describe what it does, split it
- One responsibility per file. If a file does multiple domains, extract to separate file

---

## Error Handling

**Layered Approach:**
1. **Service Layer** (deepest): Return error with context. Wrap errors as you propagate them upward.
2. **Business Logic Layer** (middle): Propagate errors upward. Wrap if you add context. Don't log here.
3. **Handler/Controller Layer** (boundary): Catch errors, log with full context if needed, return user-safe error message.

**Rules:**
- Never log AND return the same error within a single layer
- Log once at the boundary (HTTP handler, RPC endpoint) with full context
- Return generic error messages to clients (never expose internal details or stack traces)
- Wrap errors as they propagate to add context at each layer

**Stack-specific error handling patterns:**
- See go-patterns.md — error wrapping with `fmt.Errorf("context: %w", err)` and error type checking
- See laravel-patterns.md — exception handling and HTTP response patterns
- See angular-patterns.md — promise/async error handling and user feedback

---

## Naming Conventions

**CRITICAL**: Naming conventions are language-specific and override this baseline.

**See language-specific rules for authoritative guidance:**
- **Go**: go-patterns.md § Naming Conventions (export rules, interface patterns, constants)
- **PHP/Laravel**: laravel-patterns.md § Naming Conventions (database, migrations, accessors, scopes)
- **Angular**: angular-patterns.md § Naming Conventions (files, classes, observables, NgRx)

**Baseline principle (applies to all languages):**
- Use domain language: `userBalance` not `ub`
- Descriptive names: avoid abbreviations except where the language mandates them (Go single-letter receivers)

---

## Code Quality

- Use meaningful variable names. No single-letter names except loop counters.
- Remove unused variables, imports, and functions immediately. Don't comment them out — git has history.

---

## Comments

Write a comment for: a workaround for a known bug, a hidden constraint, a subtle invariant.
Do not write a comment for: anything a well-named function/variable already explains.
Signal: Would a developer unfamiliar with this code be confused without this comment? If no — don't write it.

---

## Code Smells

### 1. Magic Numbers
Use named constants for meaningful thresholds, delays, and limits.
```go
WRONG:  if count > 100 { ... }
RIGHT:  const MaxBatchSize = 100; if count > MaxBatchSize { ... }
```

### 2. God Objects / God Functions
A class doing too much or a function handling multiple domains. Signal: "and" in function name or class description.
```go
WRONG:  ProcessPaymentAndUpdateJournalAndSendNotification()
RIGHT:  ProcessPayment() → calls journal.Update() → calls notifier.Send()
```

### 3. Feature Envy
A function uses another class's fields/methods more than its own. Likely belongs in the other class.
```typescript
WRONG:  
class Order {
  getTotalPrice() {
    return this.items.reduce((sum, item) => sum + item.product.price * item.quantity, 0);
  }
}

RIGHT:
class OrderItem {
  getLineTotal() { return this.product.price * this.quantity; }
}
class Order {
  getTotalPrice() { return this.items.sum(item => item.getLineTotal()); }
}
```

### 4. Callback Hell / Pyramid of Doom
Deeply nested async callbacks in JS or promise chains. Use async/await or operators like `flatMap`.
```typescript
WRONG:
getUser(id, (user) => {
  getOrders(user.id, (orders) => {
    getInvoices(orders[0].id, (invoices) => {
      // ...
    });
  });
});

RIGHT:
async function getFullData(id) {
  const user = await getUser(id);
  const orders = await getOrders(user.id);
  const invoices = await getInvoices(orders[0].id);
}
```

### 5. Shotgun Surgery
Changing one logical concept requires edits in 5+ files. Signal: scattered, duplicated logic.
```
WRONG:  Adding a new payment status requires changes in:
  - models/payment.ts, controllers/payment.ts, services/payment.ts, 
  - tests/payment.test.ts, constants/status.ts, validators/status.ts (6 files)

BETTER: Centralize status definitions in one file or enum, then reference it everywhere.
```

### 6. Long Parameter Lists
Functions with 5+ parameters are hard to call and test. Signal: function signature spans multiple lines.
```go
WRONG:  func CreateOrder(ctx, userID, items, discount, tax, shipping, notes interface{}) error
RIGHT:  func CreateOrder(ctx context.Context, req *OrderRequest) error
        type OrderRequest struct { UserID, Items, Discount, Tax, Shipping, Notes ... }
```

---

## Code Quality Checklist (Aspirational Guidelines)

**Note:** These are strong guidelines, not absolute rules. Language idioms and canonical patterns may require exceptions (documented below).

Before marking work complete, verify:
- [ ] Code is readable with descriptive names (follow language-specific naming rules)
- [ ] Functions are kept small and focused (see language-specific limits for exceptions)
- [ ] Files are kept focused on one responsibility
- [ ] No nesting deeper than 4 levels (except language-specific patterns like table-driven tests)
- [ ] Errors are validated at boundaries, wrapped as they propagate, logged once at boundary
- [ ] No hardcoded values — use named constants or configuration
- [ ] Immutability enforced where language idioms support it (TypeScript/JavaScript)
- [ ] Dead code removed (no unused variables, imports, or functions)

**Documented Exceptions:**
- Go table-driven tests may exceed 50 lines (canonical pattern in go-patterns.md)
- Go switch-based routers may exceed 50 lines (idiomatic Go)
- Laravel migrations may exceed 50-line functions (schema complexity)
- Angular components may exceed 400 lines if complex (rare, but justified)
