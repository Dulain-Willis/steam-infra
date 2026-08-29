"""End-to-end pipeline smoke test (#47): writes one row to RDS via the same
connection settings the generator uses, then polls Snowflake until the
Debezium/Kafka Connect pipeline has replicated it or a timeout elapses.

Proves RDS -> WAL -> Debezium -> Kafka -> Snowflake connector -> Snowflake
table actually moves data, without inspecting any intermediate (topics,
connector internals, pod state) — only the two systems' own public
interfaces (a Postgres write, a Snowflake read).

Writes an audit-only row (insert, no update-in-place) to `price_changes`
rather than driving a full generator tick: it's the simplest OLTP table to
insert into and identify by primary key alone, and this seam only needs one
identifiable row, not realistic event data.

Snowflake schematization is disabled (#45), so rows land as raw JSON in
RECORD_CONTENT rather than typed columns — Debezium's own envelope
(schema + payload.after/before/op) is preserved as-is inside it, so this
queries record_content:payload:after:id with Snowflake's JSON path syntax.

Run through the same SSM tunnel as bootstrap.sh/rds-bootstrap.md (DB_HOST
defaults to localhost:15432); Snowflake auth reuses the RSA key pair at
.secrets/snowflake_key.p8 already registered for the sink connector
(scripts/create-connector-secrets.sh).
"""

import os
import sys
import time

import psycopg2
import snowflake.connector
from cryptography.hazmat.primitives import serialization

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = os.environ.get("DB_PORT", "15432")
DB_NAME = os.environ.get("DB_NAME", "steam")
DB_USER = os.environ.get("DB_USER", "steam_proj_admin")

SNOWFLAKE_ACCOUNT = os.environ.get("SNOWFLAKE_ACCOUNT", "FMBSGSW-YU41950")
SNOWFLAKE_USER = os.environ.get("SNOWFLAKE_USER", "DULAIN")
SNOWFLAKE_DATABASE = os.environ.get("SNOWFLAKE_DATABASE", "STEAM_PROJECT")
SNOWFLAKE_SCHEMA = os.environ.get("SNOWFLAKE_SCHEMA", "PUBLIC")
SNOWFLAKE_ROLE = os.environ.get("SNOWFLAKE_ROLE", "ACCOUNTADMIN")
SNOWFLAKE_WAREHOUSE = os.environ.get("SNOWFLAKE_WAREHOUSE", "COMPUTE_WH")
SNOWFLAKE_KEY_FILE = os.environ.get("SNOWFLAKE_KEY_FILE", ".secrets/snowflake_key.p8")

TIMEOUT_SECONDS = float(os.environ.get("SMOKE_TEST_TIMEOUT_SECONDS", "180"))
POLL_INTERVAL_SECONDS = float(os.environ.get("SMOKE_TEST_POLL_INTERVAL_SECONDS", "5"))

MARKER_REGION = "smoke_test"


def write_marker_row():
    conn = psycopg2.connect(
        host=DB_HOST,
        port=DB_PORT,
        dbname=DB_NAME,
        user=DB_USER,
        password=os.environ["DB_PASSWORD"],
        connect_timeout=10,
    )
    with conn, conn.cursor() as cur:
        cur.execute("select id from games order by random() limit 1")
        row = cur.fetchone()
        if row is None:
            raise RuntimeError("games table is empty — run generator/seed.py first")
        game_id = row[0]

        cur.execute(
            "insert into price_changes "
            "(game_id, region, currency, new_price_cents, changed_at) "
            "values (%s, %s, 'USD', 1, now()) returning id",
            (game_id, MARKER_REGION),
        )
        row_id = cur.fetchone()[0]
    conn.close()
    return str(row_id)


def load_private_key():
    with open(SNOWFLAKE_KEY_FILE, "rb") as f:
        key = serialization.load_pem_private_key(f.read(), password=None)
    return key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def poll_for_row(row_id, deadline):
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
            while time.time() < deadline:
                cur.execute(
                    "select record_content from price_changes "
                    "where record_content:payload:after:id::string = %s",
                    (row_id,),
                )
                if cur.fetchone() is not None:
                    return True
                time.sleep(POLL_INTERVAL_SECONDS)
        return False
    finally:
        conn.close()


def main():
    print(f"==> writing marker row to price_changes (region={MARKER_REGION!r})")
    row_id = write_marker_row()
    print(f"==> wrote id={row_id}, polling Snowflake for up to {TIMEOUT_SECONDS:.0f}s")

    deadline = time.time() + TIMEOUT_SECONDS
    if poll_for_row(row_id, deadline):
        print(f"==> OK: row {row_id} replicated to Snowflake")
        return 0

    print(
        f"FAIL: row {row_id} did not appear in Snowflake within "
        f"{TIMEOUT_SECONDS:.0f}s. Check, in order: "
        "./scripts/check-connector-health.sh (connectors/tasks RUNNING?), "
        "RDS logical replication (./scripts/check-rds-prereqs.sh), "
        "then Snowflake ingestion latency/errors.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
