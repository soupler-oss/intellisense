---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Lombok — Version-Aware Stance

Stack-owned subfile of `java-patterns.md` (entrypoint). Pragmatic position on Lombok, sensitive to the repo's Java version.

## What Lombok is

Lombok is an annotation-driven boilerplate generator. At compile time, its annotation processor injects methods into the bytecode based on annotations on the source. Common annotations:

- `@Getter` / `@Setter` — generates `getX()` / `setX(...)` for fields
- `@RequiredArgsConstructor` — generates a constructor over all `final` fields (great for Spring constructor injection — see [`spring-boot.md`](spring-boot.md))
- `@AllArgsConstructor` / `@NoArgsConstructor` — explicit constructors
- `@Builder` — fluent builder pattern
- `@Slf4j` — injects a `private static final Logger log = LoggerFactory.getLogger(ClassName.class);` field
- `@Data` — bundle: `@Getter + @Setter + @ToString + @EqualsAndHashCode + @RequiredArgsConstructor`
- `@Value` — immutable bundle: `@Getter + @AllArgsConstructor + @ToString + @EqualsAndHashCode + class final`

The processed source isn't visible at compile time — you see the annotated class, the compiler sees the generated code. IDEs need the Lombok plugin to surface the generated methods to navigation/autocomplete.

## Version-aware stance

The right Lombok choice depends on the repo's Java version.

### Java 8 / 11 repos — Lombok is genuinely useful

Records don't exist (records went stable in Java 16). Without Lombok, every immutable DTO needs ~30 lines of boilerplate (final fields + all-args constructor + getters + `equals`/`hashCode`/`toString`). With Lombok, one annotation:

```java
// Java 8/11 — Lombok-supported immutable DTO
@Value
public class OrderDto {
    Long id;
    BigDecimal amount;
    String currency;
}

// Without Lombok on Java 8 — hand-written equivalent
public final class OrderDto {
    private final Long id;
    private final BigDecimal amount;
    private final String currency;

    public OrderDto(Long id, BigDecimal amount, String currency) {
        this.id = id;
        this.amount = amount;
        this.currency = currency;
    }
    public Long getId() { return id; }
    public BigDecimal getAmount() { return amount; }
    public String getCurrency() { return currency; }
    @Override public boolean equals(Object o) { /* full impl */ }
    @Override public int hashCode() { /* full impl */ }
    @Override public String toString() { /* full impl */ }
}
```

For Java 8/11 repos with many DTOs, **Lombok is recommended for DTOs**. `@Value` for immutable DTOs and `@Builder` for fluent construction are the high-value annotations.

### Java 16+ repos — records replace `@Value`

Records cover the immutable-DTO use case natively:

```java
// Java 16+ — record replaces @Value entirely
public record OrderDto(Long id, BigDecimal amount, String currency) {}
```

Lombok still has value on Java 16+ for cases records can't address:

- **JPA `@Entity` classes** — can't be records because Hibernate requires a no-args constructor and mutable fields (see [`persistence-jpa.md`](persistence-jpa.md) §"Entity design"). `@Getter` + `@Setter` (or `@Data`) + `@NoArgsConstructor` is the canonical Lombok-on-entity pattern.
- **`@Slf4j`** — saves the 1-line logger field declaration. Trivial but ubiquitous.
- **`@RequiredArgsConstructor`** for Spring constructor injection — Spring picks it up automatically; saves writing the constructor by hand.

### Java 21+ repos — same as Java 16+

Records, sealed classes, pattern matching cover most of the cases Lombok was originally designed for. Lombok's residual value is on entities + `@Slf4j` + constructor injection.

## Compatibility caveats

Lombok depends on internal compiler APIs (`com.sun.tools.javac.*`). **New Java versions break it.** Always pin the Lombok version to one tested against your Java version:

| Java version | Min recommended Lombok | Notes |
|---|---|---|
| 8 | 1.18.20+ | Older versions work but lack some fixes |
| 11 | 1.18.22+ | |
| 17 | 1.18.24+ | |
| 21 | 1.18.30+ | Required — earlier versions break on JDK 21 |
| 22 (non-LTS) | 1.18.32+ | Validate on each JDK update |

When upgrading the JDK, **upgrade Lombok in lockstep** — many "mysterious compilation failure" stories trace to a Lombok version that doesn't know about the new JDK's internal API changes.

## Rule: one style per module

**Don't mix Lombok and hand-written boilerplate within the same module.** Pick one per repo (or one per submodule, with a documented boundary). Mixing produces:
- Confusing reviews ("why does this class use `@Data` when the one next to it has explicit getters?")
- Inconsistent serialization behavior (Lombok-generated `equals`/`hashCode` may differ from a hand-rolled one)
- Hidden Lombok-dependency churn when a hand-written class is migrated to records

Document the chosen stance in the per-repo CLAUDE.md's Stack Details block (`Lombok: [yes | no]`). When the repo says "yes", new DTOs/entities use Lombok consistently. When "no", new code is hand-written or uses records.

## Migrating off Lombok (for repos upgrading to Java 16+)

Records replace `@Value` cleanly:

```java
// Before (Java 8/11 with Lombok)
@Value
public class OrderDto {
    Long id;
    BigDecimal amount;
}

// After (Java 16+)
public record OrderDto(Long id, BigDecimal amount) {}
```

`@Data` on entities is harder to migrate — JPA needs the mutable shape. Stay on Lombok for entities, or migrate to hand-written getters + setters in the same PR as the entity refactor.

`@Slf4j` and `@RequiredArgsConstructor` can stay indefinitely — they save real keystrokes without obscuring intent.

## Cross-references

- [`../java-patterns.md`](../java-patterns.md) — entrypoint with version matrices (Records min-version)
- [`spring-boot.md`](spring-boot.md) — `@RequiredArgsConstructor` for constructor injection
- [`persistence-jpa.md`](persistence-jpa.md) — JPA entities can't be records; Lombok on entities is the practical pattern
