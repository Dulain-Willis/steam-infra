"""Scenario (#143): executes a pending deletion request, once its grace
period has elapsed, as a three-tier erasure rather than a cascade.

The execute half of the request-then-execute sequence started by
deletion_request.py and paired with deletion_reversal.py's within-window
undo. By the time this runs, either #142's scenarios already settled the
request (unreversed) or this call's own grace-period check refuses it:

1. **Hard delete** -- behavioural data with no retention duty
   (client_events, playtime_sessions, wishlist_items), deleted by
   user_id.
2. **Anonymize in place** -- the user row is kept (so every foreign key
   into it -- purchases, refunds, ownership_grants, gifts,
   key_redemptions, reviews, family_shares -- stays intact), but its
   identifying attributes (username, email) are overwritten with a
   tombstone value derived from the user's id, and country is cleared.
3. **Retain untouched** -- purchases, refunds and ownership_grants are
   never touched here: they fall under statutory commercial/tax
   retention, which overrides the erasure request. See
   docs/adr/0004-three-tier-compliance-erasure-143.md.

The grace-period gate reuses deletion_reversal.py's elapsed-time logic
(same env var, same now()-vs-deletion_requested_at comparison) rather
than reimplementing it, so an override to seconds proves both scenarios
without waiting out 30 real days.

Run via scripts/scenarios/run.sh deletion_execution.
"""

import logging
import os

logger = logging.getLogger(__name__)

USERNAME_ENV_VAR = "DELETION_REQUEST_USERNAME"

# Tier 1: hard-deleted by user_id. No other OLTP table has a foreign key
# into any of these three (db/schema.sql), so deleting rows here needs no
# cascading cleanup.
HARD_DELETE_TABLES = ("client_events", "playtime_sessions", "wishlist_items")


def _env_float(name, default):
    """Reads NAME from the environment as a float, falling back to the
    given code default (a string) when unset. Duplicated from
    deletion_reversal.py's helper of the same name and shape -- see that
    module's docstring for why scenario code never imports generator.py,
    which is the same reason it doesn't import across scenario modules
    either."""
    return float(os.environ.get(name, default))


GRACE_PERIOD_SECONDS = _env_float("DELETION_GRACE_PERIOD_SECONDS", str(30 * 24 * 3600))


def run(cur):
    return execute_deletion(cur, os.environ[USERNAME_ENV_VAR])


def execute_deletion(cur, username, grace_period_seconds=GRACE_PERIOD_SECONDS):
    """Executes `username`'s pending deletion request if the grace period
    has elapsed: hard-deletes their behavioural rows (tier 1) and
    anonymizes their user row in place (tier 2), leaving transaction rows
    (tier 3) completely untouched. Raises if there's no pending request
    or the grace period hasn't elapsed yet -- this refuses rather than
    quietly no-opping, the same way deletion_reversal.py refuses past the
    window instead of silently succeeding."""
    cur.execute(
        "select id, deletion_requested_at, now() from users where username = %s;",
        (username,),
    )
    row = cur.fetchone()
    if row is None:
        raise ValueError(f"no such user: {username}")

    user_id, requested_at, now = row
    if requested_at is None:
        raise ValueError(f"{username} has no pending deletion request")

    elapsed = (now - requested_at).total_seconds()
    if elapsed < grace_period_seconds:
        raise ValueError(
            f"{username}'s grace period ({grace_period_seconds:.0f}s) has not "
            f"elapsed yet ({grace_period_seconds - elapsed:.0f}s remaining) -- "
            "refusing to erase"
        )

    # The caller's connection runs autocommit (see scenarios/_run.py), so
    # without an explicit transaction each delete/update below commits on
    # its own -- a dropped tunnel partway through would leave tier 1 done
    # and tier 2 not, a silent partial erasure. begin/commit/rollback as
    # plain statements wrap all of it as one unit: either every tier-1
    # table is hard-deleted and the user row is anonymized, or none of it
    # is.
    cur.execute("begin;")
    try:
        hard_deleted = {}
        for table in HARD_DELETE_TABLES:
            cur.execute(f"delete from {table} where user_id = %s returning 1;", (user_id,))
            hard_deleted[table] = len(cur.fetchall())

        tombstone_username = f"deleted-user-{user_id}"
        tombstone_email = f"deleted-{user_id}@erased.invalid"
        cur.execute(
            """
            update users
            set username = %s,
                email = %s,
                country = null
            where id = %s
            returning id;
            """,
            (tombstone_username, tombstone_email, user_id),
        )
        cur.fetchone()
    except Exception:
        cur.execute("rollback;")
        raise
    else:
        cur.execute("commit;")

    logger.info(
        "%s: erased (%.0fs into a %.0fs grace period) -- hard deleted %s, "
        "anonymized user row to %s",
        username,
        elapsed,
        grace_period_seconds,
        hard_deleted,
        tombstone_username,
    )
    return {
        "username": username,
        "user_id": user_id,
        "hard_deleted": hard_deleted,
        "anonymized": True,
    }
