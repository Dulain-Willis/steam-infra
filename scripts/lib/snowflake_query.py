#!/usr/bin/env -S uv run --script
# /// script
# requires-python = "==3.12.*"
# dependencies = [
#     "snowflake-connector-python==3.12.3",
#     "cryptography==43.0.3",
# ]
# ///
"""Run one Snowflake statement and print its rows, for bring-up/teardown verify steps.

    uv run lib/snowflake_query.py "SHOW DATABASES LIKE 'STEAM_RAW'"
    uv run lib/snowflake_query.py --role LOADER "CREATE TABLE ..."

Rows go to stdout, one per line, fields tab-separated — so "did this find
anything" is `[[ -n "$(...)" ]]` in bash (see sf_query/snowflake_database_exists
in lib/env.sh) and a denied statement is a non-zero exit. That exit code is
what bring-up's grant-isolation check asserts on (#114).

Database lifecycle lives in terraform/snowflake, not here (#113): this is a
read/verify path only, so a "successful" apply or destroy is still checked
against what Snowflake actually reports.

Auth comes from the environment: SNOWFLAKE_ACCOUNT (the combined
<ORG>-<ACCOUNT> form the connector wants), SNOWFLAKE_USER,
SNOWFLAKE_PRIVATE_KEY_PATH — .env's operator values by default, or a service
user's name and a temporary key file exported by the caller, which is how the
grant-isolation check authenticates as each pipeline identity in turn.
SNOWFLAKE_WAREHOUSE comes from lib/env.sh.
"""

import argparse
import os

import snowflake.connector
from cryptography.hazmat.primitives import serialization


def _connect(role):
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
        role=role,
        warehouse=os.environ.get("SNOWFLAKE_WAREHOUSE", "COMPUTE_WH"),
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sql", help="the statement to run")
    parser.add_argument(
        "--role",
        default="ACCOUNTADMIN",
        help="run as this role (default: ACCOUNTADMIN, the bootstrap identity)",
    )
    args = parser.parse_args()

    conn = _connect(args.role)
    try:
        with conn.cursor() as cur:
            cur.execute(args.sql)
            for row in cur:
                print("\t".join("" if v is None else str(v) for v in row))
    finally:
        conn.close()


if __name__ == "__main__":
    main()
