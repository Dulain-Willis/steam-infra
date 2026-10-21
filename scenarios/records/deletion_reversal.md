# Fault record: deletion reversal

- **Module**: `scenarios/deletion_reversal.py`
- **Entrypoint**: `scripts/scenarios/run.sh deletion_reversal` (target user via `DELETION_REQUEST_USERNAME`)

## Fault

None. This reverses a pending deletion request made by
`scenarios/deletion_request.py`, restoring the user by setting
`users.deletion_requested_at` back to `null` — but only while the
request is still within the grace period
(`DELETION_GRACE_PERIOD_SECONDS`, default 30 days, the real-world
duration). Raises if there's no pending request or the grace period has
already expired, rather than silently no-opping.

The grace-period check compares against the database's own `now()`, not
a generator clock or wall-clock sleep, so verification can set the
override to a few seconds and prove both outcomes (reversal succeeds
inside the window, fails outside it) without ever waiting out 30 real
days.

## Blast radius

One row in `users`, one column, reverted via an ordinary `UPDATE` — same
replication path as the request. No downstream effect beyond undoing
what `deletion_request` caused.

## Detection

A query against `users.deletion_requested_at is null` where it was
previously set. The scenario itself raises (and the entrypoint exits
non-zero) if called after the grace period lapses, rather than
succeeding silently.

## Handling

This scenario *is* the handling for a reversed-within-window request.
Once the grace period lapses without a reversal, #143's execution
scenario takes over and performs the actual hard delete — this scenario
refuses to act past that point so the two can't race or double-handle
the same user.
