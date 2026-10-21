import random
from collections import Counter
from datetime import datetime, timezone

import dirty
from dirty import (
    DUPLICATE_RATES,
    ORPHAN_LATE_ARRIVAL_RATE,
    ORPHAN_NEVER_ARRIVES_RATE,
    PURCHASE_RECORDED_AT_JITTER_MAX_SECONDS,
    REFUND_REASON_NULL_RATE,
    jittered,
    maybe_null,
    orphan_flavor,
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


def test_should_duplicate_rolls_against_the_configured_rate_for_a_listed_table():
    assert should_duplicate(AlwaysRng(0.0), "wishlist_items") is True
    assert should_duplicate(AlwaysRng(0.999), "wishlist_items") is False
    assert should_duplicate(AlwaysRng(0.0), "playtime_sessions") is True


def test_should_duplicate_never_hits_for_a_table_with_no_configured_rate():
    for table in ("purchases", "refunds", "key_redemptions", "gifts", "reviews", "some_future_table"):
        assert table not in DUPLICATE_RATES
        assert should_duplicate(AlwaysRng(0.0), table) is False


def test_maybe_null_rate_roughly_matches_over_many_rolls():
    rng = random.Random(42)
    picks = [maybe_null(rng, REFUND_REASON_NULL_RATE, "other") for _ in range(20000)]
    null_rate = Counter(picks)[None] / len(picks)
    assert 0.13 < null_rate < 0.17


def test_should_duplicate_rate_roughly_matches_over_many_rolls():
    rng = random.Random(42)
    hits = [should_duplicate(rng, "wishlist_items") for _ in range(20000)]
    hit_rate = sum(hits) / len(hits)
    assert 0.015 < hit_rate < 0.025


def test_should_duplicate_playtime_rate_roughly_matches_over_many_rolls():
    rng = random.Random(42)
    hits = [should_duplicate(rng, "playtime_sessions") for _ in range(20000)]
    hit_rate = sum(hits) / len(hits)
    assert 0.005 < hit_rate < 0.015


def test_purchase_recorded_at_jitter_max_seconds_has_a_sane_code_default():
    assert PURCHASE_RECORDED_AT_JITTER_MAX_SECONDS == 30


def test_orphan_flavor_returns_never_within_the_never_arrives_budget():
    assert orphan_flavor(AlwaysRng(0.0)) == "never"


def test_orphan_flavor_returns_late_within_the_late_arrival_budget():
    # just past the never-arrives budget, still within never+late
    midpoint = ORPHAN_NEVER_ARRIVES_RATE + ORPHAN_LATE_ARRIVAL_RATE / 2
    assert orphan_flavor(AlwaysRng(midpoint)) == "late"


def test_orphan_flavor_returns_none_outside_both_budgets():
    assert orphan_flavor(AlwaysRng(0.999)) is None


def test_orphan_rates_roughly_match_over_many_rolls():
    rng = random.Random(42)
    flavors = Counter(orphan_flavor(rng) for _ in range(40000))
    never_rate = flavors["never"] / 40000
    late_rate = flavors["late"] / 40000
    assert abs(never_rate - ORPHAN_NEVER_ARRIVES_RATE) < 0.01
    assert abs(late_rate - ORPHAN_LATE_ARRIVAL_RATE) < 0.01


def test_env_float_falls_back_to_the_code_default_when_unset(monkeypatch):
    monkeypatch.delenv("SOME_UNSET_KNOB", raising=False)
    assert dirty._env_float("SOME_UNSET_KNOB", "0.42") == 0.42


def test_env_float_reads_an_override_from_the_environment(monkeypatch):
    monkeypatch.setenv("SOME_KNOB", "7.5")
    assert dirty._env_float("SOME_KNOB", "0.42") == 7.5
