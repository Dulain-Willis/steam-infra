# Fault record: deletion request

- **Module**: `scenarios/deletion_request.py`
- **Entrypoint**: `scripts/scenarios/run.sh deletion_request` (target user via `DELETION_REQUEST_USERNAME`)

## Fault

None, strictly speaking — this is the request half of compliance
erasure, not a fault. It sets `users.deletion_requested_at` to `now()`
for one named user. Nothing is deleted; the row is otherwise untouched
and the user stays a normal active user to every downstream consumer.
Raises if the user doesn't exist or already has a pending request.

## Blast radius

One row in `users`, one column. The write is an ordinary `UPDATE`, so it
replicates through Debezium/CDC exactly like any other business update —
visible in the landing table and (via `stg_steam__users`) the staging
layer — not as a delete event. Marts that join to `dim_users` see no
change at all, since nothing filters on this column (see
`scenarios/records/TEMPLATE.md`-style note: a pending request is a
normal active user).

## Detection

A query against `users.deletion_requested_at is not null`. Downstream,
the same row appearing in the landing table/staging layer with the new
column populated, via an `op='u'` (update) CDC event rather than a
delete.

## Handling

Paired with `scenarios/deletion_reversal.py`, which can undo this within
the grace period (`DELETION_GRACE_PERIOD_SECONDS`, default 30 days).
After the grace period lapses with no reversal, #143's execution scenario
does the actual hard delete. Nothing in this repo today enforces the
grace-period boundary from the request side — that's `deletion_reversal`'s
job on the way back in, and #143's job on the way to execution.
