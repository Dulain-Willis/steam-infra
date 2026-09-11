"""Reset the Snowflake side of the RDS -> Debezium -> Kafka -> Snowflake sink
so a bring-up is idempotent.

Snowpipe Streaming channels and their committed offset tokens are server-side
state in Snowflake that survives `tofu destroy` (Snowflake is not managed by
Terraform here). The Debezium source runs with snapshot.mode=always, so every
session the Kafka topics are recreated and start again at offset 0. A channel
left over from a previous session still reports its old, far-higher committed
offset, so the sink connector treats every fresh record as already-processed
and skips it -- every target table stays at 0 rows and the end-to-end smoke
test fails (scripts/smoke-test.py).

Dropping each target table also drops its Snowflake-managed
`<TABLE>-STREAMING` pipe and every channel under it. The CDC stage's
connector then recreates the tables, pipes and channels from scratch and
ingests each topic from its earliest offset.

This is the sink-side mirror of scripts/teardown-replication-slot.sh, run at
the *start* of scripts/bootstrap.sh rather than at teardown so a skipped
teardown last session can't wedge this one. Every drop is IF EXISTS, so it is
safe to run when nothing exists yet.

Auth and target match scripts/smoke-test.py: the same SNOWFLAKE_* env vars and
RSA key file, connecting with a role that can DROP (ACCOUNTADMIN by default).
"""

import os
import sys

import snowflake.connector
from cryptography.hazmat.primitives import serialization

SNOWFLAKE_ACCOUNT = os.environ.get("SNOWFLAKE_ACCOUNT", "FMBSGSW-YU41950")
SNOWFLAKE_USER = os.environ.get("SNOWFLAKE_USER", "DULAIN")
SNOWFLAKE_DATABASE = os.environ.get("SNOWFLAKE_DATABASE", "STEAM_PROJECT")
SNOWFLAKE_SCHEMA = os.environ.get("SNOWFLAKE_SCHEMA", "PUBLIC")
SNOWFLAKE_ROLE = os.environ.get("SNOWFLAKE_ROLE", "ACCOUNTADMIN")
SNOWFLAKE_WAREHOUSE = os.environ.get("SNOWFLAKE_WAREHOUSE", "COMPUTE_WH")
SNOWFLAKE_KEY_FILE = os.environ.get("SNOWFLAKE_KEY_FILE", ".secrets/snowflake_key.p8")

# The 16 sink target tables — the value side of snowflake.topic2table.map in
# k8s/kafka/snowflake-connector.yaml. Kept in sync by hand, like the table
# list in scripts/check-rds-prereqs.sh.
TABLES = [
    "users", "games", "game_prices", "purchases", "ownership_grants", "gifts",
    "key_redemptions", "refunds", "family_shares", "wishlist_items",
    "playtime_sessions", "reviews", "price_changes",
    "concurrent_player_snapshots", "marketing_campaigns", "client_events",
]


def load_private_key():
    with open(SNOWFLAKE_KEY_FILE, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def main():
    schema_fqn = f"{SNOWFLAKE_DATABASE}.{SNOWFLAKE_SCHEMA}"
    conn = snowflake.connector.connect(
        account=SNOWFLAKE_ACCOUNT,
        user=SNOWFLAKE_USER,
        private_key=load_private_key(),
        database=SNOWFLAKE_DATABASE,
        schema=SNOWFLAKE_SCHEMA,
        role=SNOWFLAKE_ROLE,
        warehouse=SNOWFLAKE_WAREHOUSE,
    )
    try:
        with conn.cursor() as cur:
            for table in TABLES:
                name = table.upper()
                # Drop the table first: for the Snowpipe Streaming
                # high-performance architecture this also removes the
                # Snowflake-managed "<TABLE>-STREAMING" pipe and its channels.
                cur.execute(f'DROP TABLE IF EXISTS {schema_fqn}."{name}"')
                # Belt-and-suspenders: clear a pipe that somehow outlived its
                # table. A still-managed pipe can refuse a direct drop; the
                # table drop above already covers the normal case, so treat a
                # failure here as non-fatal.
                try:
                    cur.execute(f'DROP PIPE IF EXISTS {schema_fqn}."{name}-STREAMING"')
                except snowflake.connector.errors.ProgrammingError as exc:
                    print(f"  note: pipe {name}-STREAMING not dropped: {exc.msg}")
                print(f"  reset {table}")

            cur.execute(f"SHOW CHANNELS IN SCHEMA {schema_fqn}")
            leftover = cur.fetchall()
            if leftover:
                names = ", ".join(sorted(row[1] for row in leftover))
                print(f"  WARNING: {len(leftover)} sink channel(s) still present: {names}")
                print("  the connector may still skip records for those tables")
            else:
                print("  all sink channels cleared")
    finally:
        conn.close()

    print(f"Snowflake sink reset complete ({schema_fqn}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
