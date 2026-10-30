# Knowledge Base — Term Ownership

**Load context**: Loaded ONLY when `/where-to-start` is invoked. NOT at baseline.
**Purpose**: Disambiguate business terms that appear in more than one service.

> **Fill this in for your organization.** It ships empty: an invented fleet would route real work to
> services that do not exist. While the table below is empty, `/where-to-start` asks which repository owns
> a change instead of guessing.

---

## Why This File Exists

`service-map.md` shows **relationships** (A depends on B), but not **ownership** (A owns concept X). The same
word often means different things in different services ("transaction" may be a ledger entry in one and a
card authorisation in another), so this file maps each business term to its OWNER, and flags it DISPUTED
when more than one service writes it.

---

## Term → Service Ownership

| Term | Owner | Readers | Writers | Disambiguate |
|------|-------|---------|---------|-------------|
<!-- One row per term, e.g.:
| **order_status** | orders-service | web-app | orders-service only | Status transitions → orders-service. Display bugs → web-app |
-->

---

## Disambiguation Rules (CRITICAL)

### Rule 1: DISPUTED Terms → Always Ask

If a term is marked DISPUTED (multiple writers, no single owner), Claude MUST ask a clarifying question instead of guessing.

Example (placeholder service names):
```
User: "Transaction is missing from the system"
Knowledge-base: transaction → DISPUTED (orders-service + billing-service both write)
Claude action: Ask "Is this an order payment or a billing ledger entry?"
```

**Never route a DISPUTED term blindly.** One word, two different code paths.

### Rule 2: Confidence <80% → Ask

If service-map.md + knowledge-base.md + CLAUDE.md Domain Terms agree <80%, ask for clarification.

Example:
```
User: "Payment failing"
Sources:
  - service-map: api-gateway → invoicing-service (payments)
  - knowledge-base: payment OWNER=invoicing-service
  - invoicing-service CLAUDE.md: "handles payment processing"
Confidence: 95% → Route to invoicing-service
But if only 2 of 3 sources agreed: 75% → "Payment could be invoicing-service (processing) or api-gateway (triggering). Which?"
```

### Rule 3: Not in This List → Check CLAUDE.md Domain Terms

If a term doesn't appear in this knowledge-base, check the **Domain Terms** section in each service's CLAUDE.md.

Each CLAUDE.md has a "Domain Terms" section listing terms the service cares about.

Example:
```
User mentions "widget" (not in knowledge-base)
Search: grep -r "widget" CLAUDE.md files
Result: "widget" defined in web-app CLAUDE.md
Route: web-app
```

### Rule 4: This + service-map.md + Domain Terms = 3-Source Confidence

Never route based on knowledge-base alone.

```
Requirement arrives with term X:
  1. service-map.md — does X appear in relationships? (70% of routing)
  2. knowledge-base.md — who owns X? Is it DISPUTED? (20% of routing)
  3. CLAUDE.md Domain Terms — find repo with X in its domain glossary (10% of routing)

All 3 sources point to same service → 95% confidence → Route
2 of 3 agree → 75% confidence → State uncertainty ("might be A or B")
1 of 3 or DISPUTED → Ask clarifying question
```

---

## When to Update This File

### Add New Term

When a new business concept is introduced across services:

1. Identify the OWNER (which service wrote the table/logic first?)
2. Identify all READERS and WRITERS
3. If multiple writers → mark DISPUTED
4. Add one-line entry with disambiguation rule

### Change OWNER

When services are refactored and ownership shifts:

1. Update OWNER field
2. Notify all READERS (they may need to update their code)
3. Increment version number in header
4. Document in CHANGELOG.md

### Mark New Terms as DISPUTED

When two services independently write the same concept (conflict):

1. Do NOT pick a side — mark DISPUTED
2. Add "Ask: [clarifying question]" in Disambiguate column
3. Escalate to architect agent for resolution
4. Once resolved, remove DISPUTED flag and assign OWNER

---

