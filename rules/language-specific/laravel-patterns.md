---
applies_to: [full_feature, bug_fix, fix_pr_comments]
phase: [2, 3, 4]
priority: HIGH
enforcement: advisory
load_when: coding
---

# PHP/Laravel Development Rules

## Naming Conventions

**PHP Variable Naming:**
- Variables: `$camelCase` (with $ prefix) — `$userBalance`, `$emailAddress`
- Class/type names: `PascalCase` — `User`, `UserProfile`, `PaymentProcessor`
- Constants: `UPPER_SNAKE_CASE` — `const STATUS_ACTIVE = 'active'`
- Global constants: `UPPER_SNAKE_CASE` — `MAX_RETRIES`, `DEFAULT_TIMEOUT`

**Database Naming (CRITICAL — affects migrations and queries):**
- Tables: `snake_case` (plural) — `users`, `user_profiles`, `payment_transactions`
- Columns: `snake_case` — `user_email`, `created_at`, `updated_at`, `first_name`
- Primary keys: `id` (implicit) — `users.id`
- Foreign keys: `{table_singular}_id` — `users.id`, `user_profiles.user_id`
- Booleans: `is_{attribute}` or `has_{attribute}` — `is_active`, `has_permission`
- Timestamps: `created_at`, `updated_at` (Laravel convention)

**Laravel Model Naming (Class → Table mapping):**
- Model class: `PascalCase` singular — `User`, `UserProfile`, `PaymentTransaction`
- Inferred table: automatic `snake_case` plural — `users`, `user_profiles`, `payment_transactions`
- Override if needed: `protected $table = 'custom_table_name'`

**Laravel Method Naming Patterns:**
- **Accessors** (computed fields): `get{Attribute}Attribute()` — `getFullNameAttribute()` accessed as `$user->full_name`
- **Mutators** (field transformation): `set{Attribute}Attribute()` — `setPasswordAttribute()` called on assignment
- **Query Scopes** (reusable filters): `scope{Name}()` — `scopeActive()` used as `User::active()`
- **Relations**: `camelCase()` method name — `profile()`, `posts()`, `userProfile()`

**Migration Naming:**
- Files: `YYYY_MM_DD_HHMMSS_{action}_{table}.php` — `2026_04_28_120000_create_users_table.php`
- Method names: `{action}_{table}` — `create_users_table`, `add_email_to_users`
- Column operations: `table->columnType('column_name')` — `table->string('user_email')`

**Example — Full naming in context:**
```php
// Migration: 2026_04_28_120000_create_user_profiles_table.php
Schema::create('user_profiles', function (Blueprint $table) {
    $table->id();  // creates id column
    $table->unsignedBigInteger('user_id');  // foreign key
    $table->string('first_name');  // snake_case column
    $table->string('last_name');
    $table->boolean('is_active')->default(true);  // is_ prefix for boolean
    $table->timestamps();  // creates created_at, updated_at
    $table->foreign('user_id')->references('id')->on('users');
});

// Model: UserProfile.php
class UserProfile extends Model {
    protected $table = 'user_profiles';  // explicit table name (optional)
    
    // Accessor: accessed as $profile->full_name
    public function getFullNameAttribute() {
        return $this->first_name . ' ' . $this->last_name;
    }
    
    // Mutator: called on assignment
    public function setPasswordAttribute($value) {
        $this->attributes['password'] = Hash::make($value);
    }
    
    // Scope: used as UserProfile::active()
    public function scopeActive($query) {
        return $query->where('is_active', true);
    }
    
    // Relation: called as $profile->user()
    public function user() {
        return $this->belongsTo(User::class);
    }
}
```

---

## Code Patterns
- Use Eloquent ORM patterns — no raw SQL unless absolutely necessary.
- Use Laravel's service container for dependency injection.
- Use Form Requests for input validation.
- Use Laravel Jobs for async processing.
- Use Laravel Events for decoupled communication within the service.

## Database
- Never modify shared database tables without checking all services that read them.
- Use Laravel migrations for schema changes.
- Soft-delete financial records (use `SoftDeletes` trait). Audit trail fields `created_by` and `reason` are required on financial tables.

## Jobs & Queues
- Always set `ShouldQueue` + explicit `$queue` property on new Job classes — never rely on the default queue for domain operations.
- Jobs must be idempotent: safe to re-run if dispatched twice or if a worker crashes mid-execution.
- Implement `failed()` on every Job for retry logic and alerting.
- Name queues after their domain concern. Document named queues in the repo's CLAUDE.md.

## Multi-Tenancy

When a repo uses tenant isolation middleware:
- Queries are automatically scoped to the authenticated tenant via middleware
- **Read Replica Coordination**: If using read replica with tenant isolation:
  - Tenant middleware scopes the query **before** connection routing
  - Safe to use `Model::on('read')` — tenant scope is preserved
  - Verify in tests: use DatabaseTransactions + withoutMiddleware() to bypass scoping, then manually set context for testing multi-tenant isolation

## Read Replica
- Use `Model::on('read')` for read-heavy queries when a read replica is configured.
- Never route writes to the read replica.
- In multi-tenant contexts: read replica respects tenant scoping, safe to use together

## Job Checklist
Before merging any new Job:
- [ ] `$queue` property set explicitly (no default queue for domain jobs)
- [ ] Job is idempotent
- [ ] `failed()` method implemented

## Feature Testing

### Isolated Persistence-Path Feature Tests (RefreshDatabase)

For changes matching `@rules/operational/ai-regression-patterns.md §P2` (SELECT/projection omission) or §P1 (sandbox/prod divergence): use `RefreshDatabase` + factory + `assertJsonPath` with **value** assertions. Per `@rules/operational/testing.md §Persistence-Path Rule for Shape/Query Changes`, do NOT mock the User model or the underlying Eloquent query — that hides projection bugs.

**Canonical pattern:**
```php
use Illuminate\Foundation\Testing\RefreshDatabase;

class UserProfileTest extends TestCase
{
    use RefreshDatabase;

    public function test_profile_returns_notification_settings_value_from_db(): void
    {
        $user = User::factory()->create([
            'notification_settings' => ['email' => true, 'sms' => false],
        ]);

        $response = $this->actingAs($user)->getJson('/api/user/profile');

        // VALUE assertion — catches SELECT-omission. If notification_settings
        // is missing from the controller's ->select([...]) clause, Eloquent
        // returns null and this assertion fails. A key-only assertion would
        // pass against null and miss the bug.
        $response->assertJsonPath('data.notification_settings.email', true);
        $response->assertJsonPath('data.notification_settings.sms', false);
    }
}
```

**Anti-pattern (do NOT use for shape/query changes):**
```php
// ❌ Mocking the Eloquent query — this hides P2 (SELECT omission).
$mock = Mockery::mock(User::class);
$mock->shouldReceive('find')->andReturn((object)[
    'id' => 1,
    'notification_settings' => ['email' => true],  // mock RETURNS the field
]);
// ...test passes even if the real ->select() omits the column.

// ❌ Key-only assertion against real DB — passes against null returns.
$response->assertJsonStructure(['data' => ['notification_settings']]);
// notification_settings = null still satisfies "key exists".
```

**Rule of thumb:** if the test could pass when `notification_settings` is `null`, the test is not catching the bug class P2 was designed for. Always assert a value.

### Auth in Feature Tests
When the repo uses a **custom authentication middleware** (not Laravel's built-in `auth:api` or Sanctum), `actingAs($user, 'api')` alone will not satisfy the custom middleware — the request will receive a 401 before reaching the controller. Use:
```php
$this->withoutMiddleware(App\Http\Middleware\CustomAuthClass::class)
    ->actingAs($user)
    ->getJson('/api/...');
```
`Auth::user()` inside the controller still resolves because `actingAs()` sets the authenticated user on the default guard. Verify this pattern is used in existing tests before writing new ones.

### Design File Dependency
When a ticket references a design file (Figma, UX-NNN, wireframe URL) to define a new response structure, **stop and ask for the local path** before attempting to infer the structure from the Jira description. Do not proceed with an assumed structure — incorrect structure wastes implementation cycles and QA rounds.

### Worktree PHP Dependencies

`git worktree add` does not copy `vendor/` (it's .gitignored). PHP dependencies must be available to the worktree before testing.

**Ensure PHP dependencies are available. Choose one option:**

**Option A: Local install (standard)**
```bash
cd /path/to/worktree && composer install --no-interaction --prefer-dist
```

**Option B: Symlink from dev machine** (if already installed locally)
```bash
cd /path/to/worktree && ln -s /path/to/dev/vendor vendor
```

**Option C: Docker volume mount** (if using containers)
```bash
docker run -v /path/to/worktree:/app -v vendor:/app/vendor php:latest composer install
```

**Option D: Environment-managed** (shared cache, NixOS, etc.)
- Verify with package manager: `composer --version`

**Verification (all options):**
```bash
cd /path/to/worktree
php artisan tinker  # Should not fail with "vendor/autoload.php not found"
# OR
./vendor/bin/phpunit --version  # Should print PHPUnit version
```

If verification fails → dependencies are not available → choose a different setup option above.
