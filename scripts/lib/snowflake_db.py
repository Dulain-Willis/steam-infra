#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.*"
# dependencies = [
#     "snowflake-connector-python==3.12.3",
#     "cryptography==43.0.3",
# ]
# ///
"""STEAM_PROJECT Snowflake database lifecycle for bring-up/teardown stages.

Run via `uv run lib/snowflake_db.py <create-database|drop-database|
database-exists>` — uv resolves the pinned deps from the header above on
first use and caches them, so this is the only Python prerequisite (#84:
"uv is the only Python prerequisite").

Auth comes from .env (SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER,
SNOWFLAKE_PRIVATE_KEY_PATH); the database/role/warehouse are the fixed
values lib/env.sh exports, passed through as env vars so bash and Python
share one source of config.
"""

import argparse
import os
import sys

import snowflake.connector
from cryptography.hazmat.primitives import serialization


def _connect():
    key_path = os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"]
    with open(key_path, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    private_key = key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        private_key=private_key,
        role=os.environ.get("SNOWFLAKE_ROLE", "ACCOUNTADMIN"),
        warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "COMPUTE_WH"),
    )


def _database_name():
    return os.environ.get("SNOWFLAKE_DATABASE", "STEAM_PROJECT")


def database_exists(conn):
    with conn.cursor() as cur:
        cur.execute("SHOW DATABASES LIKE %s", (_database_name(),))
        return cur.fetchone() is not None


def cmd_create_database(conn):
    name = _database_name()
    if database_exists(conn):
        print(f"{name} already exists")
        return
    with conn.cursor() as cur:
        cur.execute(f'CREATE DATABASE "{name}"')
    print(f"created {name}")


def cmd_drop_database(conn):
    name = _database_name()
    with conn.cursor() as cur:
        cur.execute(f'DROP DATABASE IF EXISTS "{name}"')
    print(f"dropped {name} (if it existed)")


def cmd_database_exists(conn):
    exists = database_exists(conn)
    print("true" if exists else "false")
    # Exit code doubles as a bash `if` check, e.g.:
    #   if uv run lib/snowflake_db.py database-exists; then ...
    sys.exit(0 if exists else 1)


COMMANDS = {
    "create-database": cmd_create_database,
    "drop-database": cmd_drop_database,
    "database-exists": cmd_database_exists,
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
