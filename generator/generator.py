"""Generator core loop: weighted event-type selection against seeded data.

A single `tick(cur, clock, rng)` call picks an event type by weight
(purchase, price_change, concurrent_player_snapshot, playtime_session,
family_share, wishlist_item, review) and executes it, writing rows through
the given cursor. Clock and RNG are injected — never read from globals — so
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

# Weighted event types: (name, weight). Catalog events (price_change,
# concurrent_player_snapshot) are rarer than per-user purchases; playtime
# sessions fire far more often than the ownership events (#11/#12) since a
# real player racks up many sessions per purchase.
EVENT_WEIGHTS = [
    ("purchase", 5.0),
    ("price_change", 1.0),
    ("concurrent_player_snapshot", 2.0),
    ("playtime_session", 6.0),
    ("family_share", 0.5),
    ("wishlist_item", 1.5),
    ("review", 0.8),
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


def price_change_tick(cur, clock, rng):
    """Nudges a random seeded game_prices row and writes the price_changes
    audit row capturing old/new price_cents.
    """
    cur.execute(
        "select id, game_id, region, currency, price_cents "
        "from game_prices order by random() limit 1"
    )
    price_id, game_id, region, currency, old_price_cents = cur.fetchone()

    changed_at = clock()
    # ponytail: +/-20% random walk, floored at 99c to keep prices at a
    # plausible minimum (rather than drifting to 0 over many changes);
    # revisit if #16 wants sale-shaped price curves instead.
    delta = int(old_price_cents * rng.uniform(-0.2, 0.2))
    new_price_cents = max(99, old_price_cents + delta)

    cur.execute(
        "insert into price_changes "
        "(game_id, region, currency, old_price_cents, new_price_cents, changed_at) "
        "values (%s, %s, %s, %s, %s, %s)",
        (game_id, region, currency, old_price_cents, new_price_cents, changed_at),
    )
    cur.execute(
        "update game_prices set price_cents = %s, updated_at = %s where id = %s",
        (new_price_cents, changed_at, price_id),
    )
    return price_id


# ponytail: each snapshot tick samples 25 games and gives each a
# player_count in [0, 60] (avg ~750 summed across the sample), so a
# "latest snapshot per game" read taken shortly after a burst of
# concurrent_player_snapshot ticks lands in the ~500-1,000 peak target.
# A single tick only covers 25 of 3000 games though — sweeping the whole
# catalog takes ~120 ticks at this sample size, so "instant" is
# approximate until #16 tunes tick interval/weight for a faster sweep.
SNAPSHOT_SAMPLE_SIZE = 25


def concurrent_player_snapshot_tick(cur, clock, rng):
    """Writes a concurrent_player_snapshots row for a random sample of
    games, simulating an instant read of catalog-wide concurrency.
    """
    snapshot_at = clock()
    cur.execute(
        "select id from games order by random() limit %s", (SNAPSHOT_SAMPLE_SIZE,)
    )
    game_ids = [row[0] for row in cur.fetchall()]

    for game_id in game_ids:
        player_count = rng.randint(0, 60)
        cur.execute(
            "insert into concurrent_player_snapshots "
            "(game_id, player_count, snapshot_at) values (%s, %s, %s)",
            (game_id, player_count, snapshot_at),
        )
    return game_ids


def _open_close_tick(cur, clock, rng, table, start_col, end_col):
    """Shared open/close pattern for playtime_sessions, family_shares, and
    wishlist_items: with an open row available, roughly half the time close
    it; otherwise (or if none is open) start a new one. Returns the row id.
    """
    cur.execute(
        f"select id from {table} where {end_col} is null order by random() limit 1"
    )
    open_row = cur.fetchone()
    if open_row and rng.random() < 0.5:
        row_id = open_row[0]
        cur.execute(
            f"update {table} set {end_col} = %s where id = %s",
            (clock(), row_id),
        )
        return row_id

    cur.execute("select id from users order by random() limit 1")
    user_id = cur.fetchone()[0]
    cur.execute("select id from games order by random() limit 1")
    game_id = cur.fetchone()[0]
    cur.execute(
        f"insert into {table} (user_id, game_id, {start_col}) "
        "values (%s, %s, %s) returning id",
        (user_id, game_id, clock()),
    )
    return cur.fetchone()[0]


def playtime_session_tick(cur, clock, rng):
    """Open/close pattern on playtime_sessions: starts a session (started_at
    set, ended_at null) or, with an open session available, closes it
    (ended_at set). Returns the session id.
    """
    return _open_close_tick(cur, clock, rng, "playtime_sessions", "started_at", "ended_at")


def wishlist_item_tick(cur, clock, rng):
    """Open/close pattern on wishlist_items: adds an item (added_at set,
    removed_at null) or, with an open item available, removes it
    (removed_at set). Returns the item id.
    """
    return _open_close_tick(cur, clock, rng, "wishlist_items", "added_at", "removed_at")


def family_share_tick(cur, clock, rng):
    """Same open/close pattern, but family_shares keys on owner_id/borrower_id
    rather than user_id/game_id, so it can't share the generic helper's
    insert shape.
    """
    cur.execute(
        "select id from family_shares where ended_at is null order by random() limit 1"
    )
    open_row = cur.fetchone()
    if open_row and rng.random() < 0.5:
        share_id = open_row[0]
        cur.execute(
            "update family_shares set ended_at = %s where id = %s",
            (clock(), share_id),
        )
        return share_id

    cur.execute("select id from users order by random() limit 2")
    owner_id = cur.fetchone()[0]
    borrower_id = cur.fetchone()[0]
    cur.execute(
        "insert into family_shares (owner_id, borrower_id, started_at) "
        "values (%s, %s, %s) returning id",
        (owner_id, borrower_id, clock()),
    )
    return cur.fetchone()[0]


def review_tick(cur, clock, rng):
    """Writes a reviews row for a random (user, game) pair. reviews carries
    unique(user_id, game_id); a pair that's already reviewed is a
    rejected/retried write, pre-checked here rather than caught as a
    constraint violation, since the tick loop has no existing retry/rollback
    machinery to catch into. Returns the review id, or None if rejected.
    """
    cur.execute("select id from users order by random() limit 1")
    user_id = cur.fetchone()[0]
    cur.execute("select id from games order by random() limit 1")
    game_id = cur.fetchone()[0]

    cur.execute(
        "select id from reviews where user_id = %s and game_id = %s",
        (user_id, game_id),
    )
    if cur.fetchone() is not None:
        return None

    cur.execute(
        "insert into reviews (user_id, game_id, recommended, playtime_at_review_minutes, submitted_at) "
        "values (%s, %s, %s, %s, %s) returning id",
        (user_id, game_id, rng.random() < 0.7, rng.randint(0, 6000), clock()),
    )
    return cur.fetchone()[0]


EVENT_HANDLERS = {
    "purchase": purchase_tick,
    "price_change": price_change_tick,
    "concurrent_player_snapshot": concurrent_player_snapshot_tick,
    "playtime_session": playtime_session_tick,
    "family_share": family_share_tick,
    "wishlist_item": wishlist_item_tick,
    "review": review_tick,
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
