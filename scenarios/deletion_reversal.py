"""Scenario (#142): reverses a pending deletion request during the grace
period, restoring the user to normal active status.

The restoration half of the request-then-execute sequence paired with
deletion_request.py. Grace-period duration is DELETION_GRACE_PERIOD_SECONDS
(env-overridable; default 30 days, the real-world duration -- see
db/schema.sql's users table comment and CONTEXT.md's glossary entry).

This default must never be waited out in wall-clock time: live
verification sets the override to a handful of seconds instead. The
comparison is done against the database's own now(), not any generator
clock, so it holds however the override is set.

The env-with-code-default read follows #130's convention
(generator/dirty.py's `_env_float()`) -- duplicated locally rather than
imported, same as fake_cursor.py duplicates generator/test_generator.py's
FakeCursor, so scenario code never reaches into the generator package.

Run via scripts/scenarios/run.sh deletion_reversal.
"""

import logging
import os

logger = logging.getLogger(__name__)

USERNAME_ENV_VAR = "DELETION_REQUEST_USERNAME"


def _env_float(name, default):
    """Reads NAME from the environment as a float, falling back to the
    given code default (a string) when unset. See module docstring."""
    return float(os.environ.get(name, default))


GRACE_PERIOD_SECONDS = _env_float("DELETION_GRACE_PERIOD_SECONDS", str(30 * 24 * 3600))


def run(cur):
    return reverse_deletion(cur, os.environ[USERNAME_ENV_VAR])


def reverse_deletion(cur, username, grace_period_seconds=GRACE_PERIOD_SECONDS):
    """Restores `username` if their deletion request is still within the
    grace period. Raises if there's no pending request or the grace
    period has already expired -- by #143, that's #143's job to enforce,
    not this scenario's to quietly ignore."""
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
    if elapsed > grace_period_seconds:
        raise ValueError(
            f"{username}'s grace period ({grace_period_seconds:.0f}s) expired "
            f"{elapsed - grace_period_seconds:.0f}s ago -- cannot reverse"
        )

    cur.execute("update users set deletion_requested_at = null where id = %s;", (user_id,))
    logger.info(
        "%s: deletion request reversed (%.0fs into a %.0fs grace period)",
        username,
        elapsed,
        grace_period_seconds,
    )
    return {"username": username, "user_id": user_id, "reversed": True}
