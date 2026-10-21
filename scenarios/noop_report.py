"""Reference scenario (#131): injects no fault.

Proves the scenario harness end to end — a cursor-taking function,
callable without a live database — and establishes the shape #142
(deletion request), #143 (erasure execution) and #144 (additive
migration) write their fault scenarios in. Run it through
scripts/scenarios/run.sh noop_report.

Written record: scenarios/records/noop_report.md (template:
scenarios/records/TEMPLATE.md).
"""

import logging

logger = logging.getLogger(__name__)


def run(cur):
    """Reports a row count per table in the public schema. Read-only, no
    fault injected. Takes a cursor (real or fake, see test_noop_report.py)
    so it's callable with no live database."""
    cur.execute("select tablename from pg_tables where schemaname = 'public' order by tablename;")
    tables = [row[0] for row in cur.fetchall()]

    counts = {}
    for table in tables:
        cur.execute(f"select count(*) from {table};")
        counts[table] = cur.fetchone()[0]
        logger.info("%s: %d rows", table, counts[table])
    return counts
