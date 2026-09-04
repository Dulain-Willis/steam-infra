import random

from faker import Faker

from seed import (
    CHANNELS,
    COUNTRIES,
    REGIONS,
    generate_game_prices,
    generate_games,
    generate_marketing_campaigns,
    generate_users,
)


class StubRandom:
    """Forces rng.random() to a fixed roll; delegates everything else to a real RNG."""

    def __init__(self, next_random, real_rng):
        self._next_random = next_random
        self._real = real_rng

    def random(self):
        return self._next_random

    def sample(self, *args, **kwargs):
        return self._real.sample(*args, **kwargs)

    def randint(self, *args, **kwargs):
        return self._real.randint(*args, **kwargs)

    def uniform(self, *args, **kwargs):
        return self._real.uniform(*args, **kwargs)


def test_generate_users_unique_username_and_email():
    fake = Faker()
    Faker.seed(2)
    rows = generate_users(1000, fake, random.Random(2))

    usernames = [username for username, _, _ in rows]
    emails = [email for _, email, _ in rows]

    assert len(usernames) == len(set(usernames)) == 1000
    assert len(emails) == len(set(emails)) == 1000


def test_generate_users_country_distribution():
    fake = Faker()
    Faker.seed(2)
    rows = generate_users(2000, fake, random.Random(2))

    countries = [country for _, _, country in rows]
    assert any(c is None for c in countries)          # nullable in the data
    assert {c for c in countries if c is not None} <= set(COUNTRIES)
    assert countries.count("US") > countries.count("SE")  # weighting takes effect


def test_generate_games_null_rate_boundary_below_threshold_nulls_both():
    fake = Faker()
    Faker.seed(1)
    stub = StubRandom(next_random=0.0, real_rng=random.Random(1))

    _, developer, publisher, _, _ = generate_games(1, fake, stub)[0]

    assert developer is None
    assert publisher is None


def test_generate_games_null_rate_boundary_above_threshold_nulls_neither():
    fake = Faker()
    Faker.seed(1)
    stub = StubRandom(next_random=0.99, real_rng=random.Random(1))

    _, developer, publisher, _, _ = generate_games(1, fake, stub)[0]

    assert developer is not None
    assert publisher is not None


def test_generate_game_prices_covers_every_region_per_game():
    game_ids = ["game-1", "game-2"]
    rows = generate_game_prices(game_ids, random.Random(3))

    assert len(rows) == len(game_ids) * len(REGIONS)

    regions_for_game_1 = {region for game_id, region, _, _ in rows if game_id == "game-1"}
    assert regions_for_game_1 == {region for region, _ in REGIONS}


def test_generate_marketing_campaigns_shape_and_invariants():
    fake = Faker()
    Faker.seed(4)
    rows = generate_marketing_campaigns(200, fake, random.Random(4))

    assert len(rows) == 200
    for name, channel, spend_cents, currency, starts_at, ends_at in rows:
        assert name
        assert channel in CHANNELS
        assert spend_cents > 0
        assert currency == "USD"
        assert ends_at > starts_at
