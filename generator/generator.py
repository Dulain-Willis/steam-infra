"""Generator core loop: weighted event-type selection against seeded data.

A single `tick(cur, clock, rng)` call picks an event type by weight and
executes it, writing rows through the given cursor. Clock and RNG are
injected — never read from globals — so ticks are forceable and
unit-testable without a live Postgres connection.

`purchase`, `key_redemption`, and `refund` are single-phase: one call
writes the event row plus (for purchase/key_redemption) the fan-in
`ownership_grants` row, or (for refund) revokes an existing one. `gift`
is two-phase, following the open/close nullable-timestamp pattern used
elsewhere in the schema: a send half inserts a `gifts` row with
`redeemed_at` null, and a redeem half — picked probabilistically when an
unredeemed gift exists — closes it and only then writes the
`ownership_grants` row (source='gift'), since ownership doesn't change
hands until redemption.
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

REFUND_REASONS = ["not_as_described", "technical_issues", "accidental_purchase", "other"]
GIFT_REDEEM_CHANCE = 0.5  # when an unredeemed gift exists, chance a gift tick closes it instead of sending a new one
CHARGEBACK_CHANCE = 0.1

# Weighted event types: (name, weight). Relative weight reflects rarity —
# refunds are the rarest event.
EVENT_WEIGHTS = [
    ("purchase", 5.0),
    ("gift", 2.0),
    ("key_redemption", 2.0),
    ("refund", 1.0),
]


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


def gift_send_tick(cur, clock, rng):
    """Sender purchases a game and gifts it to a different user. Writes a
    purchases row (the sender's payment) and a gifts row with redeemed_at
    null — ownership doesn't transfer until the recipient redeems it.
    """
    cur.execute("select id from users order by random() limit 1")
    sender_id = cur.fetchone()[0]
    cur.execute("select id from users where id != %s order by random() limit 1", (sender_id,))
    recipient_id = cur.fetchone()[0]
    cur.execute("select id from games order by random() limit 1")
    game_id = cur.fetchone()[0]

    sent_at = clock()
    amount_cents = rng.randint(999, 5999)
    payment_method = rng.choice(PAYMENT_METHODS)

    cur.execute(
        "insert into purchases "
        "(user_id, game_id, amount_cents, currency, payment_method, purchased_at) "
        "values (%s, %s, %s, %s, %s, %s) returning id",
        (sender_id, game_id, amount_cents, CURRENCY, payment_method, sent_at),
    )
    purchase_id = cur.fetchone()[0]

    cur.execute(
        "insert into gifts (purchase_id, sender_id, recipient_id, sent_at) "
        "values (%s, %s, %s, %s) returning id",
        (purchase_id, sender_id, recipient_id, sent_at),
    )
    return cur.fetchone()[0]


def gift_redeem_tick(cur, clock, rng):
    """Closes a random unredeemed gift and writes the fan-in
    ownership_grants row (source='gift') at redemption time. Caller must
    have already confirmed an unredeemed gift exists.
    """
    cur.execute(
        "select g.id, g.recipient_id, p.game_id from gifts g "
        "join purchases p on p.id = g.purchase_id "
        "where g.redeemed_at is null order by random() limit 1"
    )
    gift_id, recipient_id, game_id = cur.fetchone()

    redeemed_at = clock()
    cur.execute("update gifts set redeemed_at = %s where id = %s", (redeemed_at, gift_id))

    cur.execute(
        "insert into ownership_grants (user_id, game_id, source, source_id, granted_at) "
        "values (%s, %s, 'gift', %s, %s)",
        (recipient_id, game_id, gift_id, redeemed_at),
    )
    return gift_id


def gift_tick(cur, clock, rng):
    """Gift events are two-phase: send (new gifts row, redeemed_at null) or
    redeem (close an existing unredeemed gift + write ownership_grants).
    Redemption is only picked, probabilistically, when an open gift exists.
    """
    cur.execute("select id from gifts where redeemed_at is null limit 1")
    has_open_gift = cur.fetchone() is not None

    if has_open_gift and rng.random() < GIFT_REDEEM_CHANCE:
        return gift_redeem_tick(cur, clock, rng)
    return gift_send_tick(cur, clock, rng)


def key_redemption_tick(cur, clock, rng):
    """Writes a key_redemptions row plus the fan-in ownership_grants row
    (source='key_redemption')."""
    cur.execute("select id from users order by random() limit 1")
    user_id = cur.fetchone()[0]
    cur.execute("select id from games order by random() limit 1")
    game_id = cur.fetchone()[0]

    redeemed_at = clock()
    key_hash = "%032x" % rng.getrandbits(128)

    cur.execute(
        "insert into key_redemptions (key_hash, user_id, game_id, redeemed_at) "
        "values (%s, %s, %s, %s) returning id",
        (key_hash, user_id, game_id, redeemed_at),
    )
    key_redemption_id = cur.fetchone()[0]

    cur.execute(
        "insert into ownership_grants (user_id, game_id, source, source_id, granted_at) "
        "values (%s, %s, 'key_redemption', %s, %s)",
        (user_id, game_id, key_redemption_id, redeemed_at),
    )
    return key_redemption_id


def refund_tick(cur, clock, rng):
    """Refunds a random purchase that still has a live (unrevoked)
    ownership_grants row: writes a refunds row and sets revoked_at on that
    grant — never deletes or duplicates it. No-ops if nothing is refundable
    yet (e.g. early in a fresh run before any purchase ticks land).
    """
    cur.execute(
        "select og.id, p.id from purchases p "
        "join ownership_grants og on og.source = 'purchase' and og.source_id = p.id "
        "where og.revoked_at is null order by random() limit 1"
    )
    row = cur.fetchone()
    if row is None:
        return None
    grant_id, purchase_id = row

    refunded_at = clock()
    reason = rng.choice(REFUND_REASONS)
    is_chargeback = rng.random() < CHARGEBACK_CHANCE

    cur.execute(
        "insert into refunds (purchase_id, reason, is_chargeback, refunded_at) "
        "values (%s, %s, %s, %s) returning id",
        (purchase_id, reason, is_chargeback, refunded_at),
    )
    refund_id = cur.fetchone()[0]

    cur.execute("update ownership_grants set revoked_at = %s where id = %s", (refunded_at, grant_id))
    return refund_id


EVENT_HANDLERS = {
    "purchase": purchase_tick,
    "gift": gift_tick,
    "key_redemption": key_redemption_tick,
    "refund": refund_tick,
}


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
