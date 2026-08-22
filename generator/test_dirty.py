import random
from collections import Counter
from datetime import datetime, timezone

from dirty import (
    DUPLICATE_SKIP_LIST,
    PLAYTIME_START_DUPLICATE_RATE,
    REFUND_REASON_NULL_RATE,
    WISHLIST_ADD_DUPLICATE_RATE,
    jittered,
    maybe_null,
    should_duplicate,
)


class AlwaysRng:
    """Forces every roll to hit (random() == 0.0) or miss (random() == 1.0)."""

    def __init__(self, value):
        self._value = value

    def random(self):
        return self._value

    def uniform(self, a, b):
        return a + (b - a) * self._value


def test_maybe_null_returns_none_on_a_hit():
    assert maybe_null(AlwaysRng(0.0), 0.5, "value") is None


def test_maybe_null_returns_value_on_a_miss():
    assert maybe_null(AlwaysRng(0.999), 0.5, "value") == "value"


def test_jittered_adds_a_nonnegative_offset_after_the_event_time():
    event_time = datetime(2026, 1, 1, tzinfo=timezone.utc)

    assert jittered(event_time, AlwaysRng(0.0), 30) == event_time
    result = jittered(event_time, AlwaysRng(1.0), 30)
    assert (result - event_time).total_seconds() == 30


def test_should_duplicate_rolls_against_the_given_rate_for_allowed_tables():
    assert should_duplicate(AlwaysRng(0.0), WISHLIST_ADD_DUPLICATE_RATE, "wishlist_items") is True
    assert should_duplicate(AlwaysRng(0.999), WISHLIST_ADD_DUPLICATE_RATE, "wishlist_items") is False
    assert should_duplicate(AlwaysRng(0.0), PLAYTIME_START_DUPLICATE_RATE, "playtime_sessions") is True


def test_should_duplicate_never_hits_for_skip_listed_tables_even_on_a_forced_roll():
    for table in DUPLICATE_SKIP_LIST:
        assert should_duplicate(AlwaysRng(0.0), 1.0, table) is False


def test_duplicate_skip_list_covers_the_ownership_and_identity_tables():
    assert DUPLICATE_SKIP_LIST == {"purchases", "refunds", "key_redemptions", "gifts", "reviews"}


def test_maybe_null_rate_roughly_matches_over_many_rolls():
    rng = random.Random(42)
    picks = [maybe_null(rng, REFUND_REASON_NULL_RATE, "other") for _ in range(20000)]
    null_rate = Counter(picks)[None] / len(picks)
    assert 0.13 < null_rate < 0.17


def test_should_duplicate_rate_roughly_matches_over_many_rolls():
    rng = random.Random(42)
    hits = [should_duplicate(rng, WISHLIST_ADD_DUPLICATE_RATE, "wishlist_items") for _ in range(20000)]
    hit_rate = sum(hits) / len(hits)
    assert 0.015 < hit_rate < 0.025


def test_should_duplicate_playtime_rate_roughly_matches_over_many_rolls():
    rng = random.Random(42)
    hits = [should_duplicate(rng, PLAYTIME_START_DUPLICATE_RATE, "playtime_sessions") for _ in range(20000)]
    hit_rate = sum(hits) / len(hits)
    assert 0.005 < hit_rate < 0.015
