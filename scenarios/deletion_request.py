"""Scenario (#142): marks a named user as having requested deletion.

The request half of the request-then-execute sequence: sets
users.deletion_requested_at to now() for one user. Nothing is deleted --
the row stays a normal active user (see
scenarios/records/deletion_request.md). #143 writes the execution half
(the hard delete, after the grace period).

Target user comes from DELETION_REQUEST_USERNAME so this scenario (and
its paired reversal in deletion_reversal.py) can be pointed at the same
user without editing code.

Run via scripts/scenarios/run.sh deletion_request.
"""

import logging
import os

logger = logging.getLogger(__name__)

USERNAME_ENV_VAR = "DELETION_REQUEST_USERNAME"


def run(cur):
    return request_deletion(cur, os.environ[USERNAME_ENV_VAR])


def request_deletion(cur, username):
    """Marks `username` as having requested deletion. Raises if the user
    doesn't exist or already has a pending request -- a second request
    on top of an existing one means something upstream is confused about
    state, so this doesn't silently no-op."""
    cur.execute("select id, deletion_requested_at from users where username = %s;", (username,))
    row = cur.fetchone()
    if row is None:
        raise ValueError(f"no such user: {username}")

    user_id, existing = row
    if existing is not None:
        raise ValueError(f"{username} already has a pending deletion request as of {existing}")

    cur.execute(
        "update users set deletion_requested_at = now() where id = %s returning deletion_requested_at;",
        (user_id,),
    )
    requested_at = cur.fetchone()[0]
    logger.info("%s: deletion requested at %s", username, requested_at)
    return {"username": username, "user_id": user_id, "deletion_requested_at": requested_at}
