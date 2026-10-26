import random
from collections import Counter
from datetime import date, datetime, timezone

import dirty
from dirty import (
    DUPLICATE_RATES,
    LATE_ARRIVAL_MAX_DAYS,
    LATE_ARRIVAL_RATE,
    ORPHAN_LATE_ARRIVAL_RATE,
    ORPHAN_NEVER_ARRIVES_RATE,
    PAYMENT_METHOD_NEW_ONSET_DATE,
    PURCHASE_RECORDED_AT_JITTER_MAX_SECONDS,
    REFUND_REASON_NULL_RATE,
    jittered,
    late_arrival_offset,
    maybe_null,
    orphan_flavor,
    should_duplicate,
    should_emit_new_payment_method,
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
    assert should_duplicate(AlwaysRng(0.0), "purchases") is True
    assert should_duplicate(AlwaysRng(0.999), "purchases") is False


def test_should_duplicate_never_hits_for_a_table_with_no_configured_rate():
    # reviews/game_prices/key_redemptions carry a unique constraint
    # (db/schema.sql) that makes a literal duplicate row physically
    # impossible, so none of them get a rate.
    for table in ("refunds", "key_redemptions", "gifts", "reviews", "game_prices", "some_future_table"):
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


def test_should_duplicate_purchases_rate_roughly_matches_over_many_rolls():
    rng = random.Random(42)
    hits = [should_duplicate(rng, "purchases") for _ in range(20000)]
    hit_rate = sum(hits) / len(hits)
    assert 0.015 < hit_rate < 0.025


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


def test_env_date_falls_back_to_the_code_default_when_unset(monkeypatch):
    monkeypatch.delenv("SOME_UNSET_DATE_KNOB", raising=False)
    assert dirty._env_date("SOME_UNSET_DATE_KNOB", "2099-01-01") == date(2099, 1, 1)


def test_env_date_reads_an_override_from_the_environment(monkeypatch):
    monkeypatch.setenv("SOME_DATE_KNOB", "2026-03-15")
    assert dirty._env_date("SOME_DATE_KNOB", "2099-01-01") == date(2026, 3, 15)


def test_payment_method_new_onset_date_has_a_sane_code_default():
    # Far enough out that default generator output never changes.
    assert PAYMENT_METHOD_NEW_ONSET_DATE == date(2099, 1, 1)


def test_should_emit_new_payment_method_is_false_before_the_onset_date():
    purchased_at = datetime(2098, 12, 31, tzinfo=timezone.utc)
    assert should_emit_new_payment_method(purchased_at) is False


def test_should_emit_new_payment_method_is_true_on_and_after_the_onset_date(monkeypatch):
    monkeypatch.setattr(dirty, "PAYMENT_METHOD_NEW_ONSET_DATE", date(2026, 6, 1))

    before = datetime(2026, 5, 31, 23, 59, 59, tzinfo=timezone.utc)
    on_the_day = datetime(2026, 6, 1, tzinfo=timezone.utc)
    after = datetime(2026, 6, 2, tzinfo=timezone.utc)

    assert should_emit_new_payment_method(before) is False
    assert should_emit_new_payment_method(on_the_day) is True
    assert should_emit_new_payment_method(after) is True


def test_late_arrival_rate_and_max_days_have_sane_code_defaults():
    # Low hit rate, tail bound well inside #134's 14-day lookback window
    # (double the tail, per #134's own reasoning).
    assert LATE_ARRIVAL_RATE == 0.01
    assert LATE_ARRIVAL_MAX_DAYS == 7


def test_late_arrival_offset_returns_none_on_a_miss():
    assert late_arrival_offset(AlwaysRng(0.999)) is None


def test_late_arrival_offset_returns_a_timedelta_on_a_hit():
    offset = late_arrival_offset(AlwaysRng(0.0))
    assert offset is not None
    assert offset.total_seconds() >= 0


def test_late_arrival_offset_never_exceeds_the_configured_tail_bound():
    rng = random.Random(42)
    offsets = [o for o in (late_arrival_offset(rng) for _ in range(20000)) if o is not None]
    assert offsets  # the default rate still produces some hits over this many draws
    max_days = max(o.total_seconds() for o in offsets) / 86400
    assert max_days <= LATE_ARRIVAL_MAX_DAYS


def test_late_arrival_rate_roughly_matches_over_many_rolls():
    rng = random.Random(42)
    hits = [late_arrival_offset(rng) is not None for _ in range(20000)]
    hit_rate = sum(hits) / len(hits)
    assert 0.005 < hit_rate < 0.015


def test_late_arrival_default_rate_leaves_the_overwhelming_majority_same_second():
    # AC: "at default rates the overwhelming majority of events remain
    # same-second" -- a miss returns None, meaning the caller inserts at
    # clock() unmodified (same second as the tick that generated it).
    rng = random.Random(42)
    results = [late_arrival_offset(rng) for _ in range(20000)]
    same_second = sum(1 for r in results if r is None)
    assert same_second / len(results) > 0.98
