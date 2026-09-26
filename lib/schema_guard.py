#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.*"
# dependencies = [
#     "psycopg2-binary==2.9.10",
# ]
# ///
"""Schema-applied guard for bring-up Stage 3 (Database).

db/schema.sql uses bare `create table` (no `if not exists`), so re-running it
against an already-applied schema fails outright. Run via
`uv run lib/schema_guard.py <schema-applied|apply-schema>` through the RDS
SSM tunnel — connection comes from DB_HOST/DB_PORT/DB_NAME/DB_USER/
DB_PASSWORD env vars, the same convention generator/seed.py uses so both
scripts share one tunnel/env setup.
"""

import argparse
import os
import sys
from pathlib import Path

import psycopg2

SCHEMA_FILE = Path(__file__).resolve().parent.parent / "db" / "schema.sql"


def _connect():
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=5,
    )


def schema_applied(conn):
    with conn.cursor() as cur:
        cur.execute("select to_regclass('public.users') is not null;")
        return cur.fetchone()[0]


def cmd_schema_applied(conn):
    applied = schema_applied(conn)
    print("true" if applied else "false")
    sys.exit(0 if applied else 1)


def cmd_apply_schema(conn):
    if schema_applied(conn):
        print("schema already applied")
        return
    sql = SCHEMA_FILE.read_text()
    with conn, conn.cursor() as cur:
        cur.execute(sql)
    print(f"applied {SCHEMA_FILE.name}")


COMMANDS = {
    "schema-applied": cmd_schema_applied,
    "apply-schema": cmd_apply_schema,
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=sorted(COMMANDS))
    args = parser.parse_args()

    conn = _connect()
    try:
        COMMANDS[args.command](conn)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
