# Fault record: deletion execution

- **Module**: `scenarios/deletion_execution.py`
- **Entrypoint**: `scripts/scenarios/run.sh deletion_execution` (target user via `DELETION_REQUEST_USERNAME`)

## Fault

None, strictly speaking -- this is the execute half of compliance erasure,
not a fault. It performs the actual three-tier erasure for a user whose
deletion request (`scenarios/deletion_request.py`) has not been reversed
(`scenarios/deletion_reversal.py`) within the grace period
(`DELETION_GRACE_PERIOD_SECONDS`, default 30 days):

1. **Hard delete** -- `client_events`, `playtime_sessions`,
   `wishlist_items` rows for the user, deleted by `user_id`.
2. **Anonymize in place** -- the `users` row is kept, `username`/`email`
   overwritten with a tombstone value derived from the user's id
   (`deleted-user-<id>` / `deleted-<id>@erased.invalid`), `country`
   cleared, `deletion_executed_at` set to the now() read at the top of
   the call. Added (steam-infra#129 integration review, finding 9) as
   the durable "execution happened" signal: a re-run against the same
   user now raises rather than re-tombstoning, and a warehouse consumer
   can key off a real column instead of pattern-matching the username
   tombstone.
3. **Retain untouched** -- `purchases`, `refunds`, `ownership_grants`
   (and every other table with a `user_id` FK -- `gifts`,
   `key_redemptions`, `reviews`, `family_shares`) are never written here.

Raises -- refusing to act -- if there's no pending request, if
`deletion_executed_at` is already set (erasure already ran for this
user), or if the grace period hasn't elapsed yet. The grace-period comparison reuses
`deletion_reversal.py`'s elapsed-time logic (same env var, same
now()-vs-`deletion_requested_at` comparison), so the override-to-seconds
trick that proves `deletion_reversal` also proves this scenario without
waiting out 30 real days.

## Blast radius

- Three OLTP tables lose rows outright (tier 1): a hard `DELETE`, not a
  soft-delete `UPDATE` -- the one documented exception to this repo's
  otherwise-universal soft-delete convention (`db/schema.sql:4`; see
  `docs/adr/0004-three-tier-compliance-erasure-143.md`).
  - Via Debezium/CDC, each hard delete arrives downstream as a
    delete-derived row in the corresponding Snowflake landing table
    (`__deleted = TRUE`, carrying the row's primary key -- rewrite-mode
    delete handling, no connector change needed).
  - `stg_steam__client_events` / `stg_steam__playtime_sessions` /
    `stg_steam__wishlist_items` already derive `is_deleted` from
    `__deleted`; `fct_playtime_sessions` / `fct_wishlist_items` already
    filter `where not is_deleted`. `fct_product_funnel_sessions` refs
    `stg_steam__client_events` directly and must filter the same way.
    Erased rows disappear from marts on the next run once the
    delete-derived landing row lands.
- One row in `users` changes identity (tier 2): an ordinary `UPDATE`,
  replicates as an `op='u'` CDC event, same as any other business
  update -- not a delete event, so the row (and every fact row's
  `user_id` FK into it) stays intact. `dim_users` keeps exactly one row
  for this `user_id`, now carrying tombstone `username`/`email`.
- Everything in tier 3 is unaffected -- no write, no CDC event, no
  change anywhere downstream.

## Detection

- `select count(*) from client_events where user_id = ...` (and the same
  for `playtime_sessions`, `wishlist_items`) returning `0` confirms tier
  1 ran.
- `select username, email, country from users where id = ...` showing
  the tombstone values confirms tier 2.
- `select count(*) from purchases where user_id = ...` (and `refunds`
  via its `purchase_id` join, and `ownership_grants`) unchanged
  before/after confirms tier 3 was left alone.
- Downstream: the landing tables carrying delete-derived rows for the
  erased primary keys, and the next `dbt build`'s marts no longer
  containing them -- the orchestrator's live-verification procedure for
  this ticket (outside this repo) has the exact queries.

## Handling

This scenario *is* the handling -- it's the terminal step of the
request-then-execute sequence, not a fault something else catches. What
it depends on: the connector's existing rewrite-mode delete handling
(no change needed, per #143's scope) to carry the hard deletes
downstream, and the `stg`/mart `is_deleted` filter already in place to
drop them from marts. A gap in either of those would surface as erased
rows persisting in a landing table or a mart -- exactly what the
warehouse tests added for #143 are there to catch.
