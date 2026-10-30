---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Node Development Rules

Covers Node.js backends (Express + NestJS) with TypeScript-first guidance. Plain JavaScript notes appear inline where the pattern differs. **Repo-convention-first:** if the target repo uses an established style, match it — do not force migrations.

## Frameworks Covered

- **Express** — minimalist routing/middleware
- **NestJS** — decorator-based modules, DI container, opinionated structure

Both ship in this single rule file (per intellisense architecture rule). Subsections call out framework-specific deltas.

---

## Naming Conventions (TS-first)

- **Files**: `kebab-case.ts` for source; `kebab-case.test.ts` or `*.spec.ts` for tests
- **Classes / Interfaces / Types**: `PascalCase` — `UserBalance`, `OrderProcessor`, `OrderDto`
- **Functions / methods / variables**: `camelCase` — `calculateFee`, `processOrder`, `userBalance`
- **Constants**: `UPPER_SNAKE_CASE` — `MAX_RETRIES`, `DEFAULT_TIMEOUT`
- **Booleans**: `isActive`, `hasPermission`, `shouldRetry`
- **NestJS modules**: `<feature>.module.ts`, `<feature>.controller.ts`, `<feature>.service.ts` (Nest convention)

**JS-only repos:** same rules minus type annotations.

---

## Project Layout (typical)

| Express | NestJS |
|---|---|
| `src/routes/`, `src/controllers/`, `src/services/`, `src/repositories/`, `src/middleware/` | `src/<feature>/` (each feature = module + controller + service + dto) |
| Single `app.ts` wiring | `main.ts` + `AppModule` + DI container |
| Manual error middleware | `ExceptionFilter`s |

---

## Async Error Handling

**Express:** wrap async handlers; never let a Promise reject silently.

```ts
// GOOD: async wrapper
const asyncHandler = (fn: RequestHandler): RequestHandler =>
  (req, res, next) => Promise.resolve(fn(req, res, next)).catch(next);

router.get('/orders/:id', asyncHandler(async (req, res) => {
  const order = await orderService.get(req.params.id);
  res.json(order);
}));
```

```ts
// BAD: rejection lost — Express returns 200 with empty body
router.get('/orders/:id', async (req, res) => {
  const order = await orderService.get(req.params.id); // throws
  res.json(order);
});
```

**NestJS:** rejections caught by global `ExceptionFilter`. Don't reinvent — extend `HttpException` for custom errors.

---

## Validation at System Boundaries

- **Express:** `zod`, `joi`, or `class-validator` on the request body before any DB call
- **NestJS:** `ValidationPipe` + `class-validator` decorators on DTOs

```ts
// NestJS DTO with validation
import { IsEmail, IsInt, Min } from 'class-validator';
export class CreateOrderDto {
  @IsEmail() email!: string;
  @IsInt() @Min(1) quantity!: number;
}
```

---

## DB Transactions and Idempotency

For any write that touches multiple rows or services:

```ts
// Prisma example — atomic transaction
await prisma.$transaction(async (tx) => {
  await tx.account.update({ where: { id }, data: { balance: { decrement: amount } } });
  await tx.transaction.create({ data: { accountId: id, amount, idempotencyKey } });
});
```

**Idempotency:** every financial write requires a unique `idempotencyKey` constraint at the DB level. Same request twice → one effect.

---

## PII in Logs

- Never log full request bodies on auth/financial endpoints
- Never log `req.user` directly — extract `userId` only
- Mask emails as `user@***.com` in error messages when unavoidable

---

## Isolated Real-Persistence Tests

The Architecture Rule (`@rules/operational/ai-regression-patterns.md`) routes Node backends to this section for P1, P2, P3.

### P1 — Sandbox/Production Path Divergence

**Where it bites in Node:** environment-gated branches like `if (process.env.NODE_ENV === 'test')` returning hand-built fixture vs. real ORM result.

**Test pattern:** assert against BOTH branches with the same fixture row. Use a containerized DB (Testcontainers) or in-memory engine (sqlite-memory + Prisma) — NOT mocks.

```ts
// jest + Testcontainers — both branches return same shape
test('order shape matches in sandbox and prod paths', async () => {
  const sandboxOrder = sandboxBranch.getOrder('order-1');
  const prodOrder = await prodBranch.getOrder('order-1'); // real DB
  expect(Object.keys(sandboxOrder).sort()).toEqual(Object.keys(prodOrder).sort());
  expect(sandboxOrder.totalCents).toBe(prodOrder.totalCents);
});
```

### P2 — SELECT / Projection Omission

**Where it bites in Node:** TypeORM `select: { ... }`, Prisma `select: { ... }`, raw `db.query('SELECT a, b FROM...')`. Adding a field to the API response without updating the SELECT projection silently returns `undefined` for that field.

**Test pattern:** real persistence path + value-asserting test (NOT key-only).

```ts
// jest + supertest + real DB — value-asserting
test('GET /orders/:id returns notification_settings.email', async () => {
  await db.order.create({ data: { id: '1', notificationSettings: { email: 'a@b.com' } } });
  const res = await request(app).get('/orders/1');
  expect(res.body.notificationSettings.email).toBe('a@b.com'); // VALUE, not just key
});
```

```ts
// BAD: key-only assertion — passes against null returns
expect(res.body).toHaveProperty('notificationSettings');
```

See `tests/scenario_node_p2_select_omission/demo.js` for a runnable before/after demonstration.

### P3 — Error State Leakage

**Where it bites in Node:** in-memory caches (LRU, redis) populated on success path; error path doesn't invalidate. The same request retried after fix returns stale success-path data.

**Test pattern:** assert cache state after error response.

```ts
test('cache cleared when service throws', async () => {
  cache.set('order:1', { ...partialState });
  await expect(orderService.process('1')).rejects.toThrow();
  expect(cache.get('order:1')).toBeUndefined(); // explicit assertion on cleanup
});
```

---

## Common Anti-Patterns

- **Promise inside `forEach`** — runs concurrently with no error propagation. Use `for...of` + `await`, or `Promise.all` with `.map`.
- **`any` in TS** — defeats the purpose of TS. Prefer `unknown` and narrow.
- **Mock-heavy tests** — see P1/P2 above. Real-path tests catch what mocks miss.
- **`console.log` for production logging** — use `pino`/`winston`/Nest `Logger`.

---

## Cross-references

- Routing for AI-regression patterns: `@rules/operational/ai-regression-patterns.md`
- Generic testing rules: `@rules/operational/testing.md`
- Onboarding workflow: `docs/language-support-onboarding.md` (platform-team reference)
