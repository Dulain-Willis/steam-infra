import random
from collections import Counter
from datetime import datetime, timezone

from generator import (
    EVENT_WEIGHTS,
    gift_redeem_tick,
    gift_send_tick,
    gift_tick,
    key_redemption_tick,
    pick_event_type,
    purchase_tick,
    refund_tick,
    tick,
)


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
    picks = [pick_event_type(rng) for _ in range(2000)]
    # Exercised through the real weighted selector (not a shortcut), so
    # adding/reweighting event types changes this test's expectations
    # rather than silently passing.
    assert set(picks) == {"purchase", "gift", "key_redemption", "refund"}
    counts = Counter(picks)
    total = sum(w for _, w in EVENT_WEIGHTS)
    for name, weight in EVENT_WEIGHTS:
        expected = weight / total
        assert abs(counts[name] / len(picks) - expected) < 0.05
    # Acceptance criterion: refunds are the rarest event.
    assert counts["refund"] == min(counts.values())


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
    # seed 1 draws "purchase" first against EVENT_WEIGHTS (verified empirically)
    cur = FakeCursor(fetchone_values=[("u",), ("g",), ("p",)])
    event_type = tick(cur, fixed_clock, random.Random(1))

    assert event_type == "purchase"
    assert {name for name, _ in EVENT_WEIGHTS} == {"purchase", "gift", "key_redemption", "refund"}


def test_gift_send_tick_creates_purchase_and_open_gift_row():
    sender_id, recipient_id, game_id, purchase_id, gift_id = (
        "sender-1",
        "recipient-1",
        "game-1",
        "purchase-1",
        "gift-1",
    )
    cur = FakeCursor(
        fetchone_values=[(sender_id,), (recipient_id,), (game_id,), (purchase_id,), (gift_id,)]
    )

    result = gift_send_tick(cur, fixed_clock, random.Random(7))

    assert result == gift_id
    gift_calls = [(sql, params) for sql, params in cur.calls if "insert into gifts" in sql]
    assert len(gift_calls) == 1
    sql, params = gift_calls[0]
    assert params == (purchase_id, sender_id, recipient_id, fixed_clock())
    # no ownership_grants row yet — ownership doesn't move until redemption
    assert not any("ownership_grants" in sql for sql, _ in cur.calls)


def test_gift_redeem_tick_writes_ownership_grant_at_redemption_time():
    gift_id, recipient_id, game_id = "gift-1", "recipient-1", "game-1"
    cur = FakeCursor(fetchone_values=[(gift_id, recipient_id, game_id)])

    result = gift_redeem_tick(cur, fixed_clock, random.Random(7))

    assert result == gift_id
    update_calls = [(sql, params) for sql, params in cur.calls if sql.startswith("update gifts")]
    assert update_calls == [("update gifts set redeemed_at = %s where id = %s", (fixed_clock(), gift_id))]

    grant_calls = [(sql, params) for sql, params in cur.calls if "ownership_grants" in sql]
    assert len(grant_calls) == 1
    sql, params = grant_calls[0]
    assert "'gift'" in sql
    assert params == (recipient_id, game_id, gift_id, fixed_clock())


def test_gift_tick_sends_when_no_open_gift_exists():
    cur = FakeCursor(
        fetchone_values=[None, ("sender-1",), ("recipient-1",), ("game-1",), ("purchase-1",), ("gift-1",)]
    )

    event = gift_tick(cur, fixed_clock, random.Random(0))

    assert event == "gift-1"
    assert any("insert into gifts" in sql for sql, _ in cur.calls)
    assert not any("update gifts" in sql for sql, _ in cur.calls)


def test_gift_tick_redeems_when_open_gift_exists():
    class AlwaysRedeemRng:
        def random(self):
            return 0.0  # forces redeem branch (< GIFT_REDEEM_CHANCE)

    cur = FakeCursor(fetchone_values=[("open-gift-1",), ("gift-1", "recipient-1", "game-1")])

    event = gift_tick(cur, fixed_clock, AlwaysRedeemRng())

    assert event == "gift-1"
    assert any("update gifts" in sql for sql, _ in cur.calls)
    assert not any("insert into gifts" in sql for sql, _ in cur.calls)


def test_key_redemption_tick_produces_exactly_one_ownership_grant():
    user_id, game_id, key_redemption_id = "user-1", "game-1", "kr-1"
    cur = FakeCursor(fetchone_values=[(user_id,), (game_id,), (key_redemption_id,)])

    result = key_redemption_tick(cur, fixed_clock, random.Random(7))

    assert result == key_redemption_id
    kr_calls = [(sql, params) for sql, params in cur.calls if "insert into key_redemptions" in sql]
    assert len(kr_calls) == 1

    grant_calls = [(sql, params) for sql, params in cur.calls if "ownership_grants" in sql]
    assert len(grant_calls) == 1
    sql, params = grant_calls[0]
    assert "'key_redemption'" in sql
    assert params == (user_id, game_id, key_redemption_id, fixed_clock())


def test_refund_tick_sets_revoked_at_on_the_correct_existing_grant():
    grant_id, purchase_id, refund_id = "grant-1", "purchase-1", "refund-1"
    cur = FakeCursor(fetchone_values=[(grant_id, purchase_id), (refund_id,)])

    result = refund_tick(cur, fixed_clock, random.Random(7))

    assert result == refund_id
    refund_calls = [(sql, params) for sql, params in cur.calls if "insert into refunds" in sql]
    assert len(refund_calls) == 1
    assert refund_calls[0][1][0] == purchase_id

    update_calls = [(sql, params) for sql, params in cur.calls if sql.startswith("update ownership_grants")]
    assert update_calls == [
        ("update ownership_grants set revoked_at = %s where id = %s", (fixed_clock(), grant_id))
    ]
    # never delete/duplicate the grant row
    assert not any("delete" in sql.lower() for sql, _ in cur.calls)
    assert len([c for c in cur.calls if "insert into ownership_grants" in c[0]]) == 0


def test_refund_tick_is_a_noop_when_nothing_is_refundable():
    cur = FakeCursor(fetchone_values=[None])

    result = refund_tick(cur, fixed_clock, random.Random(7))

    assert result is None
    assert len(cur.calls) == 1
