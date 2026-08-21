import random

from faker import Faker

from seed import REGIONS, generate_game_prices, generate_games, generate_users


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

    usernames = [username for username, _ in rows]
    emails = [email for _, email in rows]

    assert len(usernames) == len(set(usernames)) == 1000
    assert len(emails) == len(set(emails)) == 1000


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
