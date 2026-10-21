# ADR 0004: three-tier compliance erasure, not a cascade

## Status

Accepted.

## Context

`db/schema.sql`'s header documents one universal convention: "Revocation/end
pattern: nullable `*_at` column, never delete rows." Every state change in
this schema -- a refund, a gift redemption, an ended family share, a closed
wishlist item -- is a soft delete: a nullable `*_at` column flips, and the
row stays.

#142 added the request half of compliance erasure: `users.deletion_requested_at`
records that a user asked to be forgotten, with a grace period during which
the request can be reversed (`scenarios/deletion_request.py`,
`scenarios/deletion_reversal.py`). #143 is the execute half -- once the grace
period elapses with no reversal, something has to actually erase the user's
data. A real erasure request cannot be satisfied by another nullable-column
flip: "the user asked to be forgotten" and "the row still carries their
email address, just flagged" are not the same outcome.

This is modelled on the platform's real published behaviour: a mix of
deletion and anonymization scoped per data category, not one blanket action.

## Decision

Erasure executes in **three tiers**, not a cascade down from the user row:

1. **Hard delete** -- behavioural data with no retention duty:
   `client_events`, `playtime_sessions`, `wishlist_items`. These rows are
   deleted outright by `user_id`. This is the one place in the schema a row
   is ever actually removed rather than soft-deleted, and it is scoped to
   exactly these three tables (`scenarios/deletion_execution.py`).
2. **Anonymize in place** -- the `users` row itself is kept, not deleted.
   Its identifying attributes (`username`, `email`) are overwritten with a
   tombstone value derived from the user's own id (so it stays unique
   without inventing a sentinel user), and `country` is cleared. Every
   foreign key into `users.id` -- from `purchases`, `refunds` (via
   `purchases`), `ownership_grants`, `gifts`, `key_redemptions`, `reviews`,
   `family_shares` -- stays intact, and historical aggregates keyed on
   `user_id` do not shift under the erased user.
3. **Retain untouched** -- `purchases`, `refunds`, and `ownership_grants`
   are never written by erasure. They fall under a statutory commercial and
   tax retention period that overrides the erasure request, and they
   remain attributable to the now-anonymized user row via tier 2's intact
   foreign keys.

This is a *named exception* to the soft-delete convention, not a
contradiction of it: `db/schema.sql`'s header now reads "soft delete for
all business state, hard delete only for compliance erasure
(`scenarios/deletion_execution.py`, #143) and retention purge."

No connector change is needed. The source connector already flattens
events with rewrite-mode delete handling: a tier-1 hard delete arrives
downstream as a real row carrying the deleted flag and the primary key,
which the existing `stg` layer's derived `is_deleted` column and mart
`where not is_deleted` filters already consume.

## Considered options

- **Blanket cascade deletion** (delete the user row and let foreign keys
  cascade everywhere) -- rejected. Statutory retention forbids removing
  transaction records (`purchases`, `refunds`, `ownership_grants`); a
  cascade would delete exactly the rows that are legally required to
  survive the request.
- **Anonymize everything** (treat all of a user's data, behavioural
  included, as tier 2) -- rejected. Overwriting columns on a
  `client_events`/`playtime_sessions`/`wishlist_items` row does not satisfy
  erasure for behavioural data -- the row, and the behavioural fact it
  records, is still there. Erasure for data with no retention duty means
  the row stops existing.
- **`REPLICA IDENTITY FULL`** (so a delete's CDC event carries the full
  pre-image instead of just the primary key) -- rejected. It would write
  the erased user's identifying attributes -- everything tier 1's hard
  delete just removed from Postgres -- into the Snowflake landing table as
  part of the delete event itself, retaining in the warehouse exactly the
  personal data the erasure was meant to remove. The default replica
  identity (primary key only) is correct here precisely because it carries
  nothing else.

## Consequences

- Hard delete is no longer theoretical in this schema -- it exists, scoped
  to three named tables, and `db/schema.sql`'s convention comment names the
  exception explicitly so a future table addition doesn't assume "never
  delete rows" applies unconditionally.
- A deleted row's absence from a mart depends on the `stg`/mart
  `is_deleted` filter already in place, not on anything new -- the risk
  this ADR doesn't remove is that filter rotting silently between drills,
  which is why #143 also adds model-boundary unit tests that pass whether
  or not a drill has run (`steam-analytics`'s `_core__models.yml` /
  `_product__models.yml` unit tests) plus warehouse tests that fail if
  either direction breaks (erased behavioural rows persisting, or
  transaction rows disappearing).
- Anonymization is irreversible by design: once tier 2 runs, the original
  `username`/`email` are gone. This is intentional -- the grace period
  (`deletion_reversal.py`) is the only reversal window; tiers 1 and 2 only
  run after it has elapsed.
