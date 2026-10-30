---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Spring Data JPA / Persistence Patterns

Stack-owned subfile of `java-patterns.md` (entrypoint). Covers `@Transactional` boundaries, N+1 prevention, repository design, and Optional discipline. Migrations are in [`db-migrations.md`](db-migrations.md).

**Namespace gate:** Spring Boot 2.x uses `javax.persistence.*`; Spring Boot 3.x uses `jakarta.persistence.*`. Pick the import line matching your repo's Spring Boot version.

## `@Transactional` placement (service layer only)

`@Transactional` lives on the **service layer**, never on controllers, never on repositories.

```java
@Service
public class OrderService {
    private final OrderRepository orderRepository;

    public OrderService(OrderRepository orderRepository) {
        this.orderRepository = orderRepository;
    }

    @Transactional
    public OrderDto createOrder(CreateOrderRequest req) {
        Order order = new Order(...);
        orderRepository.save(order);
        // any RuntimeException thrown here triggers rollback
        return OrderDto.from(order);
    }

    @Transactional(readOnly = true)
    public OrderDto findOrder(Long id) {
        return orderRepository.findById(id)
            .map(OrderDto::from)
            .orElseThrow(() -> new NotFoundException("Order " + id));
    }
}
```

**Why service layer:**
- Controllers should be transaction-agnostic — they parse requests and route to services. Putting `@Transactional` on a controller couples HTTP semantics to transaction boundaries.
- Repositories shouldn't own transactions either — a single repository method may be called from multiple service methods with different transactional scope requirements. Letting the service decide gives composition flexibility.

**`@Transactional(readOnly = true)` for read-only paths.** Hints Hibernate to skip dirty-checking, which is a real perf win on hot read paths. Also makes intent explicit at the method signature.

**Default rollback rule:** `@Transactional` rolls back on `RuntimeException` and `Error`, NOT on checked exceptions. If you throw a checked exception that should trigger rollback, declare `@Transactional(rollbackFor = MyCheckedException.class)`.

## N+1 query prevention

The default JPA fetch strategy lazy-loads associations. Iterating a collection of parent entities and accessing each child triggers one query per parent (the "+N"). Two fixes:

**Option A — `@EntityGraph` on the repository method (declarative, preferred):**

```java
public interface OrderRepository extends JpaRepository<Order, Long> {
    @EntityGraph(attributePaths = {"items", "customer"})
    List<Order> findByStatus(OrderStatus status);
}
```

**Option B — explicit `JOIN FETCH` in JPQL (imperative, use when the path is dynamic):**

```java
@Query("SELECT DISTINCT o FROM Order o LEFT JOIN FETCH o.items WHERE o.status = :status")
List<Order> findWithItems(@Param("status") OrderStatus status);
```

Use `DISTINCT` with `JOIN FETCH` on a `@OneToMany` to deduplicate the cartesian product Hibernate returns.

**Detecting N+1 in tests:** wire `org.hibernate.stat.Statistics` and assert `getQueryExecutionCount()` is constant regardless of result size. Or use a Hibernate-N+1-detection library (e.g. `db-util`'s `SQLStatementCountValidator`) in slice tests.

## Optional discipline

`Optional.get()` without an `isPresent()` check is forbidden. Use `orElseThrow(...)` with a domain-specific exception:

```java
// PASS
Order order = orderRepository.findById(id)
    .orElseThrow(() -> new NotFoundException("Order " + id));

// FAIL
Order order = orderRepository.findById(id).get();   // throws NoSuchElementException — leaks internal class to the client
```

`Optional` is for **return types**, not fields or parameters. A field of type `Optional<T>` adds wrapper overhead and confuses serialization. A parameter of type `Optional<T>` forces callers to wrap; just accept `T` and treat `null` as the absence signal at that boundary (with `@Nullable` annotation).

## Repository patterns

Spring Data JPA repositories are interfaces — never `@Repository`-annotated implementation classes for standard CRUD. Method-name-derived queries are fine for simple cases; `@Query` JPQL for anything beyond a single-property lookup.

```java
public interface OrderRepository extends JpaRepository<Order, Long> {
    List<Order> findByCustomerIdAndStatus(Long customerId, OrderStatus status);

    @Query("SELECT o FROM Order o WHERE o.amount > :threshold AND o.createdAt > :since")
    List<Order> findLargeRecentOrders(@Param("threshold") BigDecimal threshold,
                                       @Param("since") Instant since);
}
```

**Never** bypass the repository with raw `EntityManager.createNativeQuery(String)` concatenated with user input — that's SQL injection. Always `setParameter()` for any value from outside the service:

```java
// PASS
Query q = em.createNativeQuery("SELECT * FROM orders WHERE customer_id = :cid", Order.class);
q.setParameter("cid", customerId);

// FAIL — SQL injection
Query q = em.createNativeQuery("SELECT * FROM orders WHERE customer_id = " + customerId, Order.class);
```

If you must build dynamic SQL (e.g. for an admin search endpoint), use the JPA Criteria API or a query builder library. Never string-concatenate.

## Entity design notes

- **`@Entity` classes need a no-args constructor** (JPA requirement). Records can't be entities — Hibernate needs to materialize via reflection and then populate via setters or field access. Use plain classes for entities. Records ARE great for projection DTOs.
- **Equals/hashCode:** if you override them on `@Entity`, base on the natural business key (`orderNumber`, `email`), NOT the generated `id`. Two transient entities with `id=null` should not collide; a persistent and transient copy of "the same" order should compare equal by business key.
- **`@Version` for optimistic locking** on entities mutated by concurrent flows. Hibernate increments on each update; concurrent stale-write throws `OptimisticLockingFailureException` which the service maps to a retry or a user-visible error.

## Cross-references

- [`../java-patterns.md`](../java-patterns.md) — entrypoint with version matrices, project layout, anti-patterns summary
- [`db-migrations.md`](db-migrations.md) — Flyway / Liquibase, shadow-mode column drop (migrations are separate from entity/repository code)
- [`spring-boot.md`](spring-boot.md) — `@Transactional` is owned by the service layer; controllers and repositories do not declare it
- [`testing.md`](testing.md) — `@DataJpaTest` slice tests; Testcontainers for real DB tests
