<!-- intellisense: stub — placeholder, safe to overwrite by generate-kb-stubs.sh -->
# Business Critical Flows

Mission-critical user journeys. Each flow must complete successfully for the service to function.

## Flow 1: [Main User Journey]

<!-- TODO: Most critical flow for this service -->

**Trigger**: [User action or system event]

**Steps**:
1. [Handler receives request, validates auth]
2. [Service fetches dependencies]
3. [Service mutates state (WITH transaction)]
4. [Event emitted to downstream]
5. [Response returned to caller]

**Success Criteria**: [What must be true when done]

**Failure Mode**: [What breaks if this flow fails]

**Data Consistency**: 
- Transaction isolation: SERIALIZABLE / READ_COMMITTED
- Locks: SELECT FOR UPDATE on [table]
- Rollback: [What happens if step X fails]

**Monitoring**: [Key metrics, alerts if fails]

---

## Flow 2: [Second Critical Flow]

<!-- TODO: Add another mission-critical flow if exists -->

**Trigger**: [User action or system event]

**Steps**:
1. ...

---

## Example: Payout Flow (Payment Service)

**Trigger**: User initiates payout

**Steps**:
1. Handler receives POST /api/v1/settle with account_id and amount
2. Service fetches account_balance from accounts-service (via API call)
3. Service verifies balance >= amount (SELECT FOR UPDATE account_balances)
4. Service deducts from account_balance, logs transaction
5. Service emits "payout.completed" event to reporting-service
6. Async job processes event → generates invoice, updates accounting
7. Handler returns 200 OK to user

**Success Criteria**: 
- account_balance updated in DB
- transaction logged
- event emitted to reporting-service
- invoice generated within 24 hours

**Failure Mode**:
- If balance < amount: reject with 400 before transaction starts
- If event fails to emit: rollback transaction, user sees error, retry available
- If invoice job fails: alert ops team, payout stays in COMPLETED state, retry job manually

**Data Consistency**:
- Transaction isolation: SERIALIZABLE (prevents phantom reads on concurrent payouts)
- Lock: SELECT FOR UPDATE on account_balances during balance check and deduction
- Rollback: If step 4 fails, transaction rolled back, balance unchanged

**Monitoring**:
- Payout success rate (target: 99.9%)
- Payout latency p95 (target: <500ms)
- Alert if >2% of payouts fail to emit event
