---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# Angular Development Rules

## Worktree Setup

Angular dependencies are in `node_modules/` (.gitignored). After `git worktree add`:

**Install dependencies:**
```bash
cd /path/to/worktree && npm install
```

**Verification:**
```bash
ng version  # Should print Angular CLI version
```

---

## Naming Conventions

**File Naming (CRITICAL — affects imports and routing):**
- Components: `kebab-case.component.ts` — `user-profile.component.ts`, `login.component.ts`
- Services: `kebab-case.service.ts` — `user.service.ts`, `auth.service.ts`
- Guards: `kebab-case.guard.ts` — `auth.guard.ts`, `admin.guard.ts`
- Directives: `kebab-case.directive.ts` — `highlight.directive.ts`
- Pipes: `kebab-case.pipe.ts` — `currency-format.pipe.ts`
- Modules: `kebab-case.module.ts` — `user.module.ts`, `shared.module.ts`
- Interfaces: `kebab-case.ts` or `kebab-case.interface.ts` — `user.ts`, `payment.interface.ts`

**Class/Type Naming (CRITICAL — identifies purpose at a glance):**
- **Components**: `{Name}Component` — `UserProfileComponent`, `LoginComponent`
- **Services**: `{Name}Service` — `UserService`, `AuthService`, `PaymentService`
- **Guards**: `{Name}Guard` — `AuthGuard`, `AdminGuard`, `RoleGuard`
- **Directives**: `{Name}Directive` — `HighlightDirective`, `TooltipDirective`
- **Pipes**: `{Name}Pipe` — `CurrencyFormatPipe`, `SafeUrlPipe`
- **Modules**: `{Name}Module` — `UserModule`, `SharedModule`, `CoreModule`
- **Interfaces**: `I{Name}` OR `{Name}Interface` (team choice, be consistent) — `IUser` or `UserInterface`

**Observable Naming (CRITICAL — shows async intent):**
- Observable properties: suffix with `$` — `user$`, `isLoading$`, `error$`
- Event emitters: `{eventName}Subject` or `{eventName}$` — `clickSubject`, `valueChanged$`
- Example:
```typescript
export class UserComponent {
  user$: Observable<User>;        // ✓ Clear it's observable
  isLoading$: Observable<boolean>;
  user: User;                     // Synchronous property (no $)
}
```

**NgRx Action Naming (Action-based state management):**
- Actions file: `{entity}.actions.ts` — `user.actions.ts`
- Action names: `{Verb}{Entity}{Context}` — `LoadUser`, `LoadUserSuccess`, `LoadUserFailure`
- Common verbs: Load, Save, Delete, Update, Fetch, Create
```typescript
export const LoadUser = createAction(
  '[User Page] Load User',
  props<{ id: string }>()
);

export const LoadUserSuccess = createAction(
  '[User API] Load User Success',
  props<{ user: User }>()
);

export const LoadUserFailure = createAction(
  '[User API] Load User Failure',
  props<{ error: string }>()
);
```

**NgRx Selector Naming (Memoized state selectors):**
- Selector file: `{entity}.selectors.ts` — `user.selectors.ts`
- Selector naming: `select{Entity}` or `select{Entity}ById`
```typescript
export const selectUserById = (id: string) =>
  createSelector(selectUsersState, users => users[id]);

export const selectAllUsers = createSelector(
  selectUsersState,
  users => Object.values(users)
);

export const selectUserCount = createSelector(
  selectAllUsers,
  users => users.length
);
```

**NgRx Reducer & Effects Naming:**
- Reducer file: `{entity}.reducer.ts` — `user.reducer.ts`
- Effects file: `{entity}.effects.ts` — `user.effects.ts`
- Effect methods: `{verb}{Entity}$` — `loadUser$`, `saveUser$`, `deleteUser$`

**Variable Naming:**
- Regular variables: `camelCase` — `userName`, `userList`, `isAuthenticated`
- Constants: `UPPER_SNAKE_CASE` — `DEFAULT_PAGE_SIZE`, `MAX_RETRIES`
- HTML event handlers: `on{EventName}` — `onClick`, `onSubmit`, `onInputChange`

**Example — Full naming in context:**
```typescript
// File: user-profile.component.ts
import { Component, OnInit, OnDestroy } from '@angular/core';
import { Observable, Subject } from 'rxjs';
import { User } from './user.interface';  // or user.ts
import { UserService } from '../services/user.service';

@Component({
  selector: 'app-user-profile',
  templateUrl: './user-profile.component.html'
})
export class UserProfileComponent implements OnInit, OnDestroy {
  // Observable properties ($ suffix)
  user$: Observable<User>;
  isLoading$: Observable<boolean>;
  error$: Observable<string>;
  
  // Synchronous properties (no $)
  currentUser: User;
  MAX_RETRIES = 3;  // Constants: UPPER_SNAKE_CASE
  
  private destroy$ = new Subject<void>();
  
  constructor(private userService: UserService) {}
  
  ngOnInit() {
    this.user$ = this.userService.getUserById('123');
  }
  
  // Event handler: onEventName
  onSaveClick() {
    this.userService.updateUser(this.currentUser).subscribe();
  }
  
  ngOnDestroy() {
    this.destroy$.next();
    this.destroy$.complete();
  }
}
```

---

## Version-Specific (CRITICAL — DO NOT MIX)

**Angular 12:** NgModules, NgRx for state management.
**Angular 19:** Standalone components, signals, new control flow syntax.

Choose ONE version per app. Do not mix patterns in the same codebase.

## Angular 12 Patterns

**NgRx Store Structure** — predictable, testable state management:
```
src/app/store/
  ├── actions/
  │   └── user.actions.ts          // export const actions
  ├── reducers/
  │   └── user.reducer.ts          // switch on action.type
  ├── effects/
  │   └── user.effects.ts          // @Injectable, dispatch side effects
  └── selectors/
      └── user.selectors.ts        // createSelector (memoized)
```

Dispatch actions from components, subscribe to selectors:
```typescript
this.store.dispatch(LoadUser({ id: userId }));
this.user$ = this.store.select(selectUserById(userId));

// In template: async pipe prevents subscription leaks
<div>{{ user$ | async }}</div>
```

**Observable Subscription Pattern** — prevent memory leaks:
```typescript
private destroy$ = new Subject<void>();

ngOnInit() {
  this.store.select(selectUser).pipe(
    takeUntil(this.destroy$),
    tap(user => this.user = user)
  ).subscribe();
}

ngOnDestroy() {
  this.destroy$.next();
  this.destroy$.complete();
}
```

Rules for Angular 12:
- Use NgModules for component organization.
- Use NgRx for state management.
- DO NOT use standalone components, signals, or @if/@for syntax.

## Angular 19 Patterns

**Signals for Reactive State** — synchronous, type-safe alternative to observables:
```typescript
export class LoginComponent {
  username = signal('');
  password = signal('');
  isLoading = signal(false);
  
  isFormValid = computed(() => 
    this.username().length > 0 && this.password().length > 6
  );
}
```

**New Control Flow Syntax** — replaces *ngIf, *ngFor:
```typescript
@if (isLoading()) {
  <app-spinner></app-spinner>
}

@for (item of items(); track item.id) {
  <div>{{ item.name }}</div>
}
```

**Standalone Components** — no NgModules:
```typescript
@Component({
  selector: 'app-login',
  standalone: true,
  imports: [CommonModule, ReactiveFormsModule],
  template: `...`
})
export class LoginComponent {}
```

Rules for Angular 19:
- Use standalone components (no NgModules).
- Use signals for state.
- DO NOT use NgModules or NgRx.

---

## Isolated Real-Persistence-Path Tests

For changes matching `@rules/operational/ai-regression-patterns.md §P1`–`§P4`: exercise the service + HTTP layer end-to-end with `HttpTestingController`, and test state-cleanup / rollback paths explicitly. Per `@rules/operational/testing.md §Persistence-Path Rule for Shape/Query Changes`, do NOT stub the service method for response-shape assertions — that hides projection bugs from the API consumer's perspective.

### Service tests with HttpTestingController (response shape — P1, P2)

```typescript
import { TestBed } from '@angular/core/testing';
import { HttpClientTestingModule, HttpTestingController } from '@angular/common/http/testing';
import { UserService } from './user.service';

describe('UserService', () => {
  let service: UserService;
  let http: HttpTestingController;

  beforeEach(() => {
    TestBed.configureTestingModule({
      imports: [HttpClientTestingModule],
      providers: [UserService],
    });
    service = TestBed.inject(UserService);
    http = TestBed.inject(HttpTestingController);
  });

  afterEach(() => http.verify());

  it('returns notification_settings value from API', (done) => {
    service.getProfile(1).subscribe(profile => {
      // VALUE assertion — catches P2 (API drops the field) and P1
      // (sandbox path returns a different shape than production).
      expect(profile.notificationSettings.email).toBe(true);
      expect(profile.notificationSettings.sms).toBe(false);
      done();
    });

    const req = http.expectOne('/api/user/1/profile');
    expect(req.request.method).toBe('GET');
    req.flush({
      data: {
        id: 1,
        notification_settings: { email: true, sms: false },
      },
    });
  });
});
```

### State cleanup on error (P3 — Error State Leakage)

When an error path is added or modified, assert that prior success state is cleared. Otherwise the UI may show stale success data alongside an error.

```typescript
it('clears prior loaded users when refresh fails', (done) => {
  // First load succeeds — populates state.
  component.loadUsers();
  const firstReq = http.expectOne('/api/users');
  firstReq.flush([{ id: 1, name: 'A' }]);
  expect(component.users.length).toBe(1);

  // Second load fails — state must be cleared, not retained.
  component.loadUsers();
  const secondReq = http.expectOne('/api/users');
  secondReq.flush('boom', { status: 500, statusText: 'Server Error' });

  // P3 assertion: stale success data must NOT remain.
  expect(component.users).toEqual([]);
  expect(component.error).toBeTruthy();
  done();
});
```

### Optimistic update with rollback (P4 — Optimistic Update Without Rollback)

When a UI mutation occurs before API confirmation, simulate API failure and assert the prior state is restored.

```typescript
it('rolls back optimistic delete when API fails', (done) => {
  component.items = [
    { id: 1, name: 'A' },
    { id: 2, name: 'B' },
  ];

  component.removeItem(1);

  // Optimistic mutation visible immediately.
  expect(component.items.find(i => i.id === 1)).toBeUndefined();

  // API fails.
  const req = http.expectOne('/api/items/1');
  req.flush('nope', { status: 500, statusText: 'Server Error' });

  // P4 assertion: prior state must be restored.
  expect(component.items.find(i => i.id === 1)).toBeDefined();
  expect(component.items.length).toBe(2);
  done();
});
```

**Anti-patterns (do NOT use for risk-pattern changes):**
- Stubbing `userService.getProfile()` to return a hardcoded shape — hides P1 / P2 because the stub shares the writer's mental model.
- Asserting only that an error message is set, without asserting prior state is cleared — misses P3.
- Testing only the success path of an optimistic update — misses P4.

**Rule of thumb:** if the test does not exercise the failure / rollback / cleanup path, it cannot catch P3 or P4. If the test stubs the service method, it cannot catch P1 or P2.

---

## Security

- **XSS prevention**: Never use `innerHTML`, `dangerouslySetInnerHTML`, or `bypassSecurityTrustHtml` with user-supplied data. Angular's template binding (`{{ value }}`) escapes by default — use it.
- If you must render raw HTML (e.g., rich text from a CMS), sanitize with Angular's `DomSanitizer.sanitize(SecurityContext.HTML, value)` and document the exception in the PR.
