import random
from collections import Counter
from datetime import datetime, timezone

from generator import EVENT_WEIGHTS, pick_event_type, purchase_tick, tick


class FakeCursor:
    """Records executed statements/params; returns canned fetchone() values
    in order. Stands in for psycopg2's cursor so tick logic is testable
    without a live Postgres connection.
    """

    def __init__(self, fetchone_values):
        self.calls = []
        self._fetchone_values = list(fetchone_values)

    def execute(self, sql, params=None):
        self.calls.append((sql, params))

    def fetchone(self):
        return self._fetchone_values.pop(0)


def fixed_clock():
    return datetime(2026, 1, 1, tzinfo=timezone.utc)


def test_pick_event_type_seeded_rng_matches_expected_distribution():
    rng = random.Random(42)
    picks = [pick_event_type(rng) for _ in range(500)]
    # Single registered type today, but exercised through the weighted
    # selector (not a shortcut), so a second entry changes this test's
    # expectations rather than silently passing.
    assert set(picks) == {"purchase"}
    assert Counter(picks)["purchase"] == 500


def test_pick_event_type_respects_weights_with_multiple_types():
    rng = random.Random(1)
    weights = [("purchase", 3.0), ("noop", 1.0)]
    picks = [pick_event_type(rng, weights) for _ in range(2000)]
    counts = Counter(picks)
    # seeded RNG over many draws: ~75/25 split, allow slack for variance
    assert 0.65 < counts["purchase"] / len(picks) < 0.85


def test_purchase_tick_produces_exactly_one_ownership_grant_for_the_purchase():
    user_id = "user-1"
    game_id = "game-1"
    purchase_id = "purchase-1"
    cur = FakeCursor(fetchone_values=[(user_id,), (game_id,), (purchase_id,)])

    result = purchase_tick(cur, fixed_clock, random.Random(7))

    assert result == purchase_id

    grant_calls = [
        (sql, params) for sql, params in cur.calls if "ownership_grants" in sql
    ]
    assert len(grant_calls) == 1

    sql, params = grant_calls[0]
    assert "'purchase'" in sql
    granted_user_id, granted_game_id, source_id, granted_at = params
    assert granted_user_id == user_id
    assert granted_game_id == game_id
    assert source_id == purchase_id
    assert granted_at == fixed_clock()

    purchase_calls = [(sql, params) for sql, params in cur.calls if "insert into purchases" in sql]
    assert len(purchase_calls) == 1


def test_tick_dispatches_to_the_selected_event_type():
    cur = FakeCursor(fetchone_values=[("u",), ("g",), ("p",)])
    event_type = tick(cur, fixed_clock, random.Random(0))

    assert event_type == "purchase"
    assert EVENT_WEIGHTS == [("purchase", 1.0)]
