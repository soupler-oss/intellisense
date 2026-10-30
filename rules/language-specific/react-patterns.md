---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# React Development Rules

Covers React frontends (Create-React-App, Vite, Next.js) with TypeScript-first guidance. Plain JavaScript notes appear inline where the pattern differs. **Repo-convention-first:** if the target repo uses an established style (NgRx-style Redux, Zustand, Context-only, React Query, etc.), match it — do not force migrations.

## Frameworks Covered

- **React** (CRA / standalone) — minimal toolchain
- **React + Vite** — fast dev server, ESM-first
- **Next.js** — file-based routing, SSR/RSC option

State management is repo-dependent: Redux Toolkit, Zustand, Jotai, React Query, or hooks-only. The patterns below apply across all of them.

---

## Naming Conventions (TS-first)

- **Files**: `PascalCase.tsx` for components; `camelCase.ts` for utilities; `kebab-case.css` or co-located `.module.css`
- **Components / Types**: `PascalCase` — `OrderList`, `OrderDto`
- **Hooks**: `useCamelCase` — `useOrder`, `useOptimisticUpdate`
- **Functions / variables**: `camelCase`
- **Constants**: `UPPER_SNAKE_CASE`
- **Booleans**: `isLoading`, `hasError`, `shouldRefetch`

---

## Project Layout (typical)

| CRA / Vite | Next.js (App Router) |
|---|---|
| `src/components/`, `src/hooks/`, `src/store/`, `src/api/`, `src/pages/` | `app/<route>/`, `app/api/`, `components/`, `hooks/`, `lib/` |
| Single `App.tsx` root | `app/layout.tsx` + per-route `page.tsx` |

---

## Component Boundaries

- **Presentational** — props-only, no fetching, no state mutation. Easy to test.
- **Container / Smart** — wires data fetching + state to a presentational child.
- **Server Components** (Next.js) — async, fetch on server. Default in App Router.

```tsx
// GOOD: presentational
export function OrderRow({ order }: { order: Order }) {
  return <li>{order.id}: {order.totalCents / 100}</li>;
}
```

---

## Side Effects in `useEffect`

- Effects must be idempotent (React Strict Mode runs them twice in dev)
- Always include the cleanup function for subscriptions, timers, AbortControllers
- Never mutate refs/state inside the render body

```tsx
useEffect(() => {
  const ctrl = new AbortController();
  fetch(url, { signal: ctrl.signal }).then(handleData).catch(handleError);
  return () => ctrl.abort();
}, [url]);
```

---

## Async State (loading / error / data)

Three explicit states; never represent loading via `data === null` ambiguity.

```tsx
type AsyncState<T> = { status: 'idle' } | { status: 'loading' }
  | { status: 'success'; data: T } | { status: 'error'; error: Error };
```

React Query / TanStack Query is the conventional helper; without it, custom hooks should expose the same three branches.

---

## PII in Logs / Telemetry

- Never send full user objects to analytics (Sentry, Datadog RUM)
- Strip emails, phone numbers, tokens from breadcrumbs and error reports
- Mask values in dev-tools dumps when displaying error UI to users

---

## Isolated Real-Persistence Tests

The Architecture Rule (`@rules/operational/ai-regression-patterns.md`) routes React frontends to this section for P3 and P4. P1 may apply if the app has mock/fixture-mode toggles; P2 is N/A (no DB projection layer in the frontend).

### P3 — Error State Leakage

**Where it bites in React:** form submission fails after a partial-success state was already loaded; error path doesn't reset the partial state. The component renders an error banner AND the stale success data simultaneously, confusing the user and creating retry hazards.

**Test pattern:** assert state shape after the error transition. Use React Testing Library + a mocked-or-real-path fetch that rejects.

```tsx
// jest + RTL — explicit assertion that prior state was cleared
test('error response clears optimistic preview', async () => {
  render(<OrderForm />);
  fireEvent.click(screen.getByText('Preview'));
  await screen.findByTestId('preview-pane'); // success state loaded
  fireEvent.click(screen.getByText('Submit'));
  // Force the submit API to reject
  await waitFor(() => expect(screen.getByRole('alert')).toBeInTheDocument());
  expect(screen.queryByTestId('preview-pane')).not.toBeInTheDocument(); // cleanup asserted
});
```

```tsx
// BAD: only asserts error appears — preview pane silently leaks
expect(screen.getByRole('alert')).toBeInTheDocument();
```

### P4 — Optimistic Update Without Rollback

**Where it bites in React:** "like" / "favorite" / "add-to-cart" mutations apply locally before the API confirms. On API failure, no compensating action restores prior state. UI and server state diverge silently.

**Test pattern:** simulate API failure post-mutation; assert state rolled back.

```tsx
test('optimistic like reverts when API fails', async () => {
  // Fake fetcher that rejects after mutation
  const failingApi = { likeOrder: jest.fn().mockRejectedValueOnce(new Error('network')) };
  render(<OrderCard order={{ id: '1', likes: 0 }} api={failingApi} />);
  fireEvent.click(screen.getByLabelText('Like'));
  // Mid-flight: optimistic state is 1
  expect(screen.getByText('1 like')).toBeInTheDocument();
  // After failure: rollback to 0
  await waitFor(() => expect(screen.getByText('0 likes')).toBeInTheDocument());
});
```

See `tests/scenario_react_p4_rollback/demo.js` for a runnable, dependency-free demonstration of the same pattern.

---

## Common Anti-Patterns

- **Implicit `any` from missing types** — turn on `strict: true` in tsconfig
- **`useState` for derived data** — derive in render; don't sync via effects
- **Conditional hooks** — Rules of Hooks: never call hooks inside branches
- **Mocking `fetch` instead of testing the rendered output** — mocks lie about what the user sees
- **Direct DOM mutation** (`document.querySelector`) — bypasses React reconciliation

---

## Cross-references

- Routing for AI-regression patterns: `@rules/operational/ai-regression-patterns.md`
- Generic testing rules: `@rules/operational/testing.md`
- Onboarding workflow: `docs/language-support-onboarding.md` (platform-team reference)
