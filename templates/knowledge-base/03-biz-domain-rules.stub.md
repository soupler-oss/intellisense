<!-- intellisense: stub — placeholder, safe to overwrite by generate-kb-stubs.sh -->
# Business Domain Rules

## Domain Terms

<!-- TODO: Terms specific to this service and their definitions -->

**Example** (payment service):
- **invoice_cycle**: Grouped collection of payments processed in one batch per day
- **account_balance**: Current available balance in user's account (stored as int64 minor-currency-units)
- **reconciliation**: Process of verifying account_balance matches SUM(transactions) for audit compliance
- **idempotency_key**: Unique transaction_reference preventing duplicate charges on retry

Use this section to disambiguate terms that mean different things in different services.

## Business Rules

<!-- TODO: Rules that enforce domain constraints -->

**Example** (payment service):
- Invoice can only proceed if account_balance >= invoice_amount
- Once a invoice is marked COMPLETED, it cannot be reversed (soft-delete only for audit)
- Invoice generation must happen within 24 hours of invoice completion
- Refunds require manual approval from finance team

## Financial Rules (CRITICAL if applicable)

<!-- TODO: Rules governing money handling, audits, compliance -->

**Example**:
- Balance mutations use SELECT FOR UPDATE: Prevents race conditions during concurrent invoice
- All currency stored as int64 minor-currency-units: Prevents float rounding errors (e.g., 10.50 major units = 1050 minor units)
- Idempotency key (transaction_reference) required: Ensures no duplicate charges on retry
- Soft-delete only (no hard deletes): Maintains audit trail for regulatory compliance
- Tax calculation: Must use tax_rate from tax_rules table, not hardcoded

## Workflow Rules

<!-- TODO: State machines, approval processes, timing constraints -->

**Example** (invoice workflow):
```
NEW → PENDING_RECONCILIATION → COMPLETED → INVOICED

Transitions:
- NEW → PENDING: Automatic after account verification
- PENDING → COMPLETED: Only if reconciliation passes
- COMPLETED → INVOICED: Automatic within 24 hours (async job)
- Any state → CANCELLED: Manual by finance team only
```

## Access Control

<!-- TODO: Who can do what with this service's data -->

**Example**:
- User can view only their own invoice history
- Finance team can view all invoices and export for accounting
- Admin can cancel invoices with approval from CFO
