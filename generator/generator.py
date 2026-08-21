"""Generator core loop: weighted event-type selection against seeded data.

A single `tick(cur, clock, rng)` call picks an event type by weight (only
`purchase` is registered so far) and executes it, writing rows through the
given cursor. Clock and RNG are injected — never read from globals — so
ticks are forceable and unit-testable without a live Postgres connection.
"""

import logging
import os
import random
import time
from datetime import datetime, timezone

import psycopg2

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")

TICK_MIN_SECONDS = float(os.environ.get("TICK_MIN_SECONDS", "5"))
TICK_MAX_SECONDS = float(os.environ.get("TICK_MAX_SECONDS", "15"))

PAYMENT_METHODS = ["credit_card", "paypal", "steam_wallet"]
# ponytail: purchases are always USD regardless of the per-region
# game_prices seeded by #10; wire up region-aware pricing if/when a later
# ticket needs multi-currency purchases.
CURRENCY = "USD"

# Weighted event types: (name, weight). Only `purchase` exists so far, but
# the shape stays a list so later tickets add siblings without a rewrite.
EVENT_WEIGHTS = [("purchase", 1.0)]


def pick_event_type(rng, weights=EVENT_WEIGHTS):
    types = [name for name, _ in weights]
    values = [w for _, w in weights]
    return rng.choices(types, weights=values, k=1)[0]


def purchase_tick(cur, clock, rng):
    """Writes a purchases row against a random seeded user/game, then the
    fan-in ownership_grants row pointing back at it. Returns the purchase id.
    """
    cur.execute("select id from users order by random() limit 1")
    user_id = cur.fetchone()[0]
    cur.execute("select id from games order by random() limit 1")
    game_id = cur.fetchone()[0]

    purchased_at = clock()
    amount_cents = rng.randint(999, 5999)
    payment_method = rng.choice(PAYMENT_METHODS)

    cur.execute(
        "insert into purchases "
        "(user_id, game_id, amount_cents, currency, payment_method, purchased_at) "
        "values (%s, %s, %s, %s, %s, %s) returning id",
        (user_id, game_id, amount_cents, CURRENCY, payment_method, purchased_at),
    )
    purchase_id = cur.fetchone()[0]

    cur.execute(
        "insert into ownership_grants (user_id, game_id, source, source_id, granted_at) "
        "values (%s, %s, 'purchase', %s, %s)",
        (user_id, game_id, purchase_id, purchased_at),
    )
    return purchase_id


EVENT_HANDLERS = {"purchase": purchase_tick}


def tick(cur, clock, rng):
    """Picks an event type by weight and executes it. Returns the type name."""
    event_type = pick_event_type(rng)
    EVENT_HANDLERS[event_type](cur, clock, rng)
    return event_type


def utc_now():
    return datetime.now(timezone.utc)


def connect():
    host = os.environ["DB_HOST"]
    port = os.environ.get("DB_PORT", "5432")
    while True:
        try:
            conn = psycopg2.connect(
                host=host,
                port=port,
                dbname=os.environ["DB_NAME"],
                user=os.environ["DB_USER"],
                password=os.environ["DB_PASSWORD"],
                connect_timeout=5,
            )
            conn.autocommit = True
            logging.info("connected to postgres at %s:%s", host, port)
            return conn
        except psycopg2.OperationalError as exc:
            logging.warning("connection failed, retrying in 5s: %s", exc)
            time.sleep(5)


def main():
    conn = connect()
    rng = random.Random()
    with conn.cursor() as cur:
        while True:
            event_type = tick(cur, utc_now, rng)
            logging.info("tick: %s", event_type)
            time.sleep(rng.uniform(TICK_MIN_SECONDS, TICK_MAX_SECONDS))


if __name__ == "__main__":
    main()
