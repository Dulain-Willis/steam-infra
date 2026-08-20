"""Skeleton generator: proves the network path to Postgres, writes no rows.

Connects once, then loops forever on a jittered interval running a no-op
query to confirm the connection is still alive.
"""

import logging
import os
import random
import time

import psycopg2

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")

DB_HOST = os.environ["DB_HOST"]
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]

TICK_MIN_SECONDS = float(os.environ.get("TICK_MIN_SECONDS", "5"))
TICK_MAX_SECONDS = float(os.environ.get("TICK_MAX_SECONDS", "15"))


def connect():
    while True:
        try:
            conn = psycopg2.connect(
                host=DB_HOST,
                port=DB_PORT,
                dbname=DB_NAME,
                user=DB_USER,
                password=DB_PASSWORD,
                connect_timeout=5,
            )
            conn.autocommit = True
            logging.info("connected to postgres at %s:%s", DB_HOST, DB_PORT)
            return conn
        except psycopg2.OperationalError as exc:
            logging.warning("connection failed, retrying in 5s: %s", exc)
            time.sleep(5)


def main():
    conn = connect()
    with conn.cursor() as cur:
        while True:
            cur.execute("SELECT 1")
            cur.fetchone()
            logging.info("heartbeat tick, connection alive")
            time.sleep(random.uniform(TICK_MIN_SECONDS, TICK_MAX_SECONDS))


if __name__ == "__main__":
    main()
