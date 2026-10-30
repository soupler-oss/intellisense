---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Financial Code Patterns

Stack-owned subfile of `java-patterns.md` (entrypoint). Money-handling rules for Java services. These are **absolutes** — no DEFAULT/LEGACY carveout, no "but it's just a small endpoint" exception. Financial safety is the baseline.

## Rule 1: `BigDecimal` for money, never `double` or `float`

`double` / `float` are IEEE 754 binary floating-point. They cannot represent decimal fractions exactly. `0.1 + 0.2` is `0.30000000000000004`, not `0.3`. For currency, this means lost minor currency units / cents accumulating over many transactions.

```java
// FAIL — never use float/double for money
double total = 0.0;
for (LineItem item : items) {
    total += item.getPrice() * item.getQuantity();   // accumulating rounding error
}

// PASS
BigDecimal total = BigDecimal.ZERO;
for (LineItem item : items) {
    total = total.add(item.getPrice().multiply(BigDecimal.valueOf(item.getQuantity())));
}
```

**This rule applies to every layer of the stack:**
- DTOs / API request/response shapes: `BigDecimal amount`, never `double`
- JPA entities: `@Column(precision = 15, scale = 4) BigDecimal amount`
- Database columns: `DECIMAL(15, 4)` (or `NUMERIC` — same thing in standard SQL), **never** `DOUBLE` / `FLOAT` / `REAL`
- Logs: serialize as `BigDecimal.toPlainString()` (avoid scientific notation)

## Rule 2: Always specify `RoundingMode` on division

`BigDecimal.divide(other)` without a `RoundingMode` throws `ArithmeticException` if the result is non-terminating (e.g. `1/3`). Always pass an explicit scale + rounding mode:

```java
// FAIL — throws ArithmeticException on non-terminating result
BigDecimal share = total.divide(splitCount);

// PASS — explicit scale + rounding mode
BigDecimal share = total.divide(splitCount, 2, RoundingMode.HALF_UP);
```

**Rounding mode choice matters:**
- `HALF_UP` — round-half-away-from-zero. The "schoolbook" rounding. Default for most retail/B2C use cases.
- `HALF_EVEN` — banker's rounding (round-half-to-even). Avoids cumulative bias on large datasets; used by IEEE 754 and many financial protocols. Use when the company's accounting standard mandates it.
- `DOWN` — truncate. Avoids ever rounding up; useful for fee calculations where the customer should never pay more than the exact share.
- `UP` — always round away from zero. Used for fees / penalties where the platform should never undercharge.

Document the chosen rounding mode in the repo's CLAUDE.md Financial Rules section.

## Rule 3: Comparisons via `compareTo`, never `equals`

`BigDecimal.equals()` compares both value AND scale. `new BigDecimal("100").equals(new BigDecimal("100.00"))` is **false** because scales differ. For equality-of-amount checks, use `compareTo`:

```java
// FAIL — different scales
new BigDecimal("100").equals(new BigDecimal("100.00"));        // false
new BigDecimal("100.00").equals(new BigDecimal("100.000"));    // false

// PASS — scale-insensitive value comparison
new BigDecimal("100").compareTo(new BigDecimal("100.00")) == 0;    // true
amount.compareTo(BigDecimal.ZERO) > 0;                              // "is positive"
```

**AssertJ shortcut for tests:** `assertThat(actual).isEqualByComparingTo(expected)` — does the right thing.

## Rule 4: Integer base units for storage where appropriate

For very-high-volume systems (millions of transactions per day) where every microsecond of `BigDecimal` arithmetic counts, an alternative is to store money as integer base units — the minor unit of whatever currency you're handling (e.g. cents for USD). This is the pattern Stripe uses (`amount` is an integer in their API).

```java
@Column(name = "amount_minor_units", nullable = false)
private long amountMinorUnits;   // 100 major units = 10000 minor units (subunit factor of 100)

public BigDecimal getAmountMajorUnits() {
    return BigDecimal.valueOf(amountMinorUnits).movePointLeft(2);    // 10000 → 100.00
}
```

**Trade-offs:**
- Faster arithmetic; predictable storage (`BIGINT` not `DECIMAL`)
- Lose precision below the base unit (minor currency units) — fine for retail, NOT for forex / institutional pricing
- API boundary needs explicit conversion — easy to forget; one off-by-100 bug per service

For this repo's services, check the per-repo CLAUDE.md Financial Rules section to see whether the service uses `BigDecimal` (decimal) or integer-base-units (minor currency units/cents) — both are valid, don't mix within a service.

## Rule 5: `SELECT FOR UPDATE` on balance mutations

For any database row that represents a balance / journal entry being mutated under concurrent load, use pessimistic locking. The standard pattern with Spring Data JPA:

```java
public interface AccountRepository extends JpaRepository<Account, Long> {
    @Lock(LockModeType.PESSIMISTIC_WRITE)
    @Query("SELECT w FROM Account w WHERE w.userId = :userId")
    Optional<Account> findByUserIdForUpdate(@Param("userId") Long userId);
}

@Service
public class AccountService {
    @Transactional
    public void debit(Long userId, BigDecimal amount) {
        Account account = accountRepository.findByUserIdForUpdate(userId)
            .orElseThrow(() -> new NotFoundException("account user_id=" + userId));
        if (account.getBalance().compareTo(amount) < 0) {
            throw new InsufficientFundsException(userId);
        }
        account.setBalance(account.getBalance().subtract(amount));
    }
}
```

The `PESSIMISTIC_WRITE` lock translates to `SELECT ... FOR UPDATE` on MySQL/PostgreSQL. Other writers to the same row block until the transaction commits. Without this, two concurrent `debit` calls can both pass the balance check before either commits — the second commit overwrites the first, allowing over-debit.

Optimistic locking (`@Version`) is an alternative when contention is rare and retry is acceptable, but for balance / payout / account operations, `PESSIMISTIC_WRITE` is the safer default.

## Rule 6: Idempotency keys on every money-moving operation

Network calls fail. Clients retry. Without idempotency, retries cause double-charges.

Every money-moving endpoint accepts an `Idempotency-Key` header (or equivalent). The service stores the key + the resulting state; a retry with the same key returns the original response, not a new mutation.

```java
@PostMapping("/transfers")
public TransferResponse transfer(
    @RequestHeader("Idempotency-Key") String idempotencyKey,
    @Valid @RequestBody TransferRequest req
) {
    return transferService.transferWithKey(idempotencyKey, req);
}

@Service
public class TransferService {
    @Transactional
    public TransferResponse transferWithKey(String key, TransferRequest req) {
        Optional<Transfer> existing = transferRepository.findByIdempotencyKey(key);
        if (existing.isPresent()) {
            return TransferResponse.from(existing.get());   // replay
        }
        // ... do the transfer; persist with the idempotency key
    }
}
```

The idempotency table should have a unique constraint on `idempotency_key` — DB-level uniqueness is the last line of defense against a TOCTOU race in the `findByIdempotencyKey` check.

## Cross-references

- [`../java-patterns.md`](../java-patterns.md) — entrypoint; `BigDecimal` rule is in §"Common Anti-Patterns" (absolutes)
- [`persistence-jpa.md`](persistence-jpa.md) — `@Transactional` placement (financial mutations need it)
- [`db-migrations.md`](db-migrations.md) — migrations that add money columns must use `DECIMAL(precision, scale)` or `BIGINT` (integer minor currency units), never `DOUBLE`
- [`../../baseline/security.md`](../../baseline/security.md) — money-typed values baseline rules
