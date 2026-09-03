"""Standalone seed script: populates users, games, and game_prices.

Run once against a fresh database (schema already applied) before the
generator starts writing event rows.
"""

import logging
import os
import random
from datetime import datetime, timedelta, timezone

import psycopg2
import psycopg2.extras
from faker import Faker

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")

NUM_USERS = int(os.environ.get("SEED_NUM_USERS", "50000"))
NUM_GAMES = int(os.environ.get("SEED_NUM_GAMES", "3000"))
NUM_CAMPAIGNS = int(os.environ.get("SEED_NUM_CAMPAIGNS", "40"))
_seed_env = os.environ.get("SEED_RANDOM_SEED")
RANDOM_SEED = int(_seed_env) if _seed_env else None

NULL_RATE = 0.03
BATCH_SIZE = 5000

REGIONS = [
    ("US", "USD"),
    ("EU", "EUR"),
    ("GB", "GBP"),
    ("BR", "BRL"),
    ("JP", "JPY"),
]

GENRE_POOL = [
    "Action", "Adventure", "RPG", "Strategy", "Simulation",
    "Sports", "Puzzle", "Horror", "Indie", "Racing",
]
LANGUAGE_POOL = ["English", "French", "German", "Spanish", "Japanese", "Portuguese"]

# Fixed channel enum, mirrored by the marketing_campaigns.channel check
# constraint in db/schema.sql and the ownership_grants.source snake_case
# convention. Extend both together.
CHANNELS = ["paid_search", "paid_social", "email", "influencer", "affiliate"]


def generate_users(n, fake, rng):
    rows = []
    for i in range(n):
        username = f"{fake.user_name()}_{i}"
        email = f"{fake.user_name()}{i}@{fake.free_email_domain()}"
        rows.append((username, email))
    return rows


def generate_games(n, fake, rng):
    rows = []
    for _ in range(n):
        developer = None if rng.random() < NULL_RATE else fake.company()
        publisher = None if rng.random() < NULL_RATE else fake.company()
        genres = rng.sample(GENRE_POOL, k=rng.randint(1, 3))
        languages = rng.sample(LANGUAGE_POOL, k=rng.randint(1, 3))
        rows.append((fake.catch_phrase(), developer, publisher, genres, languages))
    return rows


def generate_game_prices(game_ids, rng):
    rows = []
    for game_id in game_ids:
        base_cents = rng.randint(999, 5999)
        for region, currency in REGIONS:
            price_cents = int(base_cents * rng.uniform(0.85, 1.15))
            rows.append((game_id, region, currency, price_cents))
    return rows


def generate_marketing_campaigns(n, fake, rng):
    """One row per campaign: total spend only, no daily breakdown. Currency is
    USD-flat (spend_cents is already USD). starts_at/ends_at scatter over the
    last ~9 months so campaigns overlap the generator's event window."""
    now = datetime.now(timezone.utc)
    rows = []
    for _ in range(n):
        channel = rng.choice(CHANNELS)
        starts_at = now - timedelta(days=rng.randint(0, 270), hours=rng.randint(0, 23))
        ends_at = starts_at + timedelta(days=rng.randint(14, 90))
        spend_cents = rng.randint(50_000, 5_000_000)
        name = f"{fake.catch_phrase()} ({channel})"
        rows.append((name, channel, spend_cents, "USD", starts_at, ends_at))
    return rows


def connect():
    conn = psycopg2.connect(
        host=os.environ["DB_HOST"],
        port=os.environ.get("DB_PORT", "5432"),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=5,
    )
    logging.info("connected to postgres at %s", os.environ["DB_HOST"])
    return conn


def insert_users(cur, rows):
    psycopg2.extras.execute_values(
        cur, "insert into users (username, email) values %s", rows, page_size=BATCH_SIZE,
    )


def insert_games(cur, rows):
    fetched = psycopg2.extras.execute_values(
        cur,
        "insert into games (name, developer, publisher, genres, languages) "
        "values %s returning id",
        rows,
        page_size=BATCH_SIZE,
        fetch=True,
    )
    return [row[0] for row in fetched]


def insert_game_prices(cur, rows):
    psycopg2.extras.execute_values(
        cur,
        "insert into game_prices (game_id, region, currency, price_cents) values %s",
        rows,
        page_size=BATCH_SIZE,
    )


def insert_marketing_campaigns(cur, rows):
    psycopg2.extras.execute_values(
        cur,
        "insert into marketing_campaigns "
        "(name, channel, spend_cents, currency, starts_at, ends_at) values %s",
        rows,
        page_size=BATCH_SIZE,
    )


def main():
    fake = Faker()
    if RANDOM_SEED is not None:
        Faker.seed(RANDOM_SEED)
    rng = random.Random(RANDOM_SEED)

    conn = connect()
    try:
        with conn, conn.cursor() as cur:
            logging.info("seeding %d users", NUM_USERS)
            insert_users(cur, generate_users(NUM_USERS, fake, rng))

            logging.info("seeding %d games", NUM_GAMES)
            game_ids = insert_games(cur, generate_games(NUM_GAMES, fake, rng))

            logging.info("seeding game_prices for %d games", len(game_ids))
            insert_game_prices(cur, generate_game_prices(game_ids, rng))

            logging.info("seeding %d marketing_campaigns", NUM_CAMPAIGNS)
            insert_marketing_campaigns(cur, generate_marketing_campaigns(NUM_CAMPAIGNS, fake, rng))

        logging.info(
            "done: %d users, %d games, %d game_prices rows, %d marketing_campaigns",
            NUM_USERS, len(game_ids), len(game_ids) * len(REGIONS), NUM_CAMPAIGNS,
        )
    finally:
        conn.close()


if __name__ == "__main__":
    main()
