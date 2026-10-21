"""Additive upstream migration scenario (#144): an upstream team adds a
nullable column to the games table without telling anyone, and the
warehouse has to absorb it.

Reversible by design, via the GAMES_ADD_COLUMN_REVERSE env var — this is
the one alter table in the repo, and it needs an undo path that doesn't
require a teardown. Run forward: scripts/scenarios/run.sh games_add_column.
Run in reverse: GAMES_ADD_COLUMN_REVERSE=true scripts/scenarios/run.sh
games_add_column.

db/schema.sql deliberately does NOT gain this column — see the written
record (scenarios/records/games_add_column.md) for why.
"""

import logging
import os

logger = logging.getLogger(__name__)

NEW_COLUMN = "early_access"
NEW_COLUMN_TYPE = "boolean"


def run(cur):
    """Adds NEW_COLUMN to games (or drops it, when GAMES_ADD_COLUMN_REVERSE
    is set) — idempotent either direction via if [not] exists, so the
    scenario is safe to run more than once. Takes a cursor (real or fake,
    see test_games_add_column.py) so it's callable with no live database."""
    reverse = os.environ.get("GAMES_ADD_COLUMN_REVERSE", "false").lower() == "true"

    if reverse:
        sql = f"alter table games drop column if exists {NEW_COLUMN};"
    else:
        sql = f"alter table games add column if not exists {NEW_COLUMN} {NEW_COLUMN_TYPE};"

    cur.execute(sql)
    logger.info("%s", sql)
    return {"column": NEW_COLUMN, "reversed": reverse}
