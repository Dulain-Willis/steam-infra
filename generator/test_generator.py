import random
from collections import Counter
from datetime import datetime, timezone

from generator import (
    EVENT_HANDLERS,
    EVENT_WEIGHTS,
    concurrent_player_snapshot_tick,
    family_share_tick,
    gift_redeem_tick,
    gift_send_tick,
    gift_tick,
    key_redemption_tick,
    pick_event_type,
    playtime_session_tick,
    price_change_tick,
    purchase_tick,
    refund_tick,
    review_tick,
    tick,
    wishlist_item_tick,
)


class FakeCursor:
    """Records executed statements/params; returns canned fetchone()/
    fetchall() values in order. Stands in for psycopg2's cursor so tick
    logic is testable without a live Postgres connection.
    """

    def __init__(self, fetchone_values=(), fetchall_values=()):
        self.calls = []
        self._fetchone_values = list(fetchone_values)
        self._fetchall_values = list(fetchall_values)

    def execute(self, sql, params=None):
        self.calls.append((sql, params))

    def fetchone(self):
        return self._fetchone_values.pop(0)

    def fetchall(self):
        return self._fetchall_values.pop(0)


def fixed_clock():
    return datetime(2026, 1, 1, tzinfo=timezone.utc)


def test_pick_event_type_covers_all_registered_event_types():
    rng = random.Random(42)
    picks = [pick_event_type(rng) for _ in range(2000)]
    # Exercised through the weighted selector (not a shortcut), so adding or
    # reweighting an event type changes this test's expectations rather than
    # silently passing. Every weighted type must have a matching handler.
    assert set(picks) == set(EVENT_HANDLERS.keys())
    assert {name for name, _ in EVENT_WEIGHTS} == set(EVENT_HANDLERS.keys())


def test_playtime_session_weighted_highest_relative_to_ownership_events():
    weights = dict(EVENT_WEIGHTS)
    assert weights["playtime_session"] > weights["purchase"]


def test_refund_weighted_lowest_among_the_ownership_event_types():
    # Acceptance criterion (#12): event weights reflect relative rarity,
    # refunds rarest among purchase/gift/key_redemption/refund (the event
    # types #12 introduces/shares the ownership_grants fan-in with).
    # Checked against the weight table directly rather than sampled counts,
    # since a tie in weight can flip which type a given sample draws fewer
    # of. Other, unrelated event types (e.g. family_share, from a sibling
    # ticket) may be weighted even rarer without violating this criterion.
    weights = dict(EVENT_WEIGHTS)
    ownership_event_weights = {
        name: w for name, w in weights.items() if name in ("purchase", "gift", "key_redemption", "refund")
    }
    assert ownership_event_weights["refund"] == min(ownership_event_weights.values())


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


def test_price_change_tick_captures_old_and_new_price_cents():
    price_id = "price-1"
    game_id = "game-1"
    cur = FakeCursor(
        fetchone_values=[(price_id, game_id, "US", "USD", 1999)]
    )

    # Same seed drives the same rng.uniform(-0.2, 0.2) draw price_change_tick
    # makes, so the expected delta is reproducible rather than asserted as
    # "just not equal" (which a 0 delta could pass by accident).
    expected_delta = int(1999 * random.Random(3).uniform(-0.2, 0.2))
    expected_new_price_cents = max(99, 1999 + expected_delta)

    result = price_change_tick(cur, fixed_clock, random.Random(3))

    assert result == price_id

    insert_calls = [
        (sql, params) for sql, params in cur.calls if "insert into price_changes" in sql
    ]
    assert len(insert_calls) == 1
    _, params = insert_calls[0]
    inserted_game_id, region, currency, old_price_cents, new_price_cents, changed_at = params
    assert inserted_game_id == game_id
    assert region == "US"
    assert currency == "USD"
    assert old_price_cents == 1999
    assert new_price_cents == expected_new_price_cents
    assert changed_at == fixed_clock()

    update_calls = [
        (sql, params) for sql, params in cur.calls if "update game_prices" in sql
    ]
    assert len(update_calls) == 1
    _, update_params = update_calls[0]
    assert update_params == (new_price_cents, fixed_clock(), price_id)


def test_price_change_tick_floors_new_price_at_99_cents():
    cur = FakeCursor(fetchone_values=[("price-1", "game-1", "US", "USD", 100)])

    # Worst-case rng.uniform draw (-0.2) would take 100 cents negative
    # without the floor; a fixed seed doesn't guarantee that draw, so
    # exercise the floor directly against a low starting price instead.
    price_change_tick(cur, fixed_clock, random.Random(9))

    insert_sql, insert_params = next(
        (sql, params) for sql, params in cur.calls if "insert into price_changes" in sql
    )
    new_price_cents = insert_params[4]
    assert new_price_cents >= 99


def test_concurrent_player_snapshot_tick_writes_one_row_per_sampled_game():
    from generator import SNAPSHOT_SAMPLE_SIZE

    game_ids = [f"game-{i}" for i in range(SNAPSHOT_SAMPLE_SIZE)]
    cur = FakeCursor(fetchall_values=[[(gid,) for gid in game_ids]])

    result = concurrent_player_snapshot_tick(cur, fixed_clock, random.Random(5))

    assert result == game_ids

    insert_calls = [
        (sql, params)
        for sql, params in cur.calls
        if "insert into concurrent_player_snapshots" in sql
    ]
    assert len(insert_calls) == SNAPSHOT_SAMPLE_SIZE
    for (game_id, player_count, snapshot_at), expected_game_id in zip(
        (params for _, params in insert_calls), game_ids
    ):
        assert game_id == expected_game_id
        assert 0 <= player_count <= 60
        assert snapshot_at == fixed_clock()


def test_tick_dispatches_to_the_selected_event_type():
    # seed 1 lands on "purchase" given today's EVENT_WEIGHTS.
    cur = FakeCursor(fetchone_values=[("u",), ("g",), ("p",)])
    event_type = tick(cur, fixed_clock, random.Random(1))

    assert event_type == "purchase"
    assert any("insert into purchases" in c[0] for c in cur.calls)


def test_playtime_session_tick_starts_a_session_when_none_is_open():
    cur = FakeCursor(fetchone_values=[None, ("user-1",), ("game-1",), ("session-1",)])

    result = playtime_session_tick(cur, fixed_clock, random.Random(0))

    assert result == "session-1"
    sql, params = next(c for c in cur.calls if "insert into playtime_sessions" in c[0])
    assert "started_at" in sql
    assert params == ("user-1", "game-1", fixed_clock())
    assert not any("update playtime_sessions" in c[0] for c in cur.calls)


def test_playtime_session_tick_closes_an_open_session():
    cur = FakeCursor(fetchone_values=[("session-1",)])
    rng = random.Random()
    rng.random = lambda: 0.0  # force the "close it" branch

    result = playtime_session_tick(cur, fixed_clock, rng)

    assert result == "session-1"
    sql, params = next(c for c in cur.calls if "update playtime_sessions" in c[0])
    assert "ended_at" in sql
    assert params == (fixed_clock(), "session-1")
    assert not any("insert into playtime_sessions" in c[0] for c in cur.calls)


def test_wishlist_item_tick_open_close_pattern():
    # open branch: no open item -> insert with added_at
    cur = FakeCursor(fetchone_values=[None, ("user-1",), ("game-1",), ("item-1",)])
    result = wishlist_item_tick(cur, fixed_clock, random.Random(0))
    assert result == "item-1"
    sql, params = next(c for c in cur.calls if "insert into wishlist_items" in c[0])
    assert "added_at" in sql
    assert params == ("user-1", "game-1", fixed_clock())

    # close branch: open item found -> update removed_at
    cur2 = FakeCursor(fetchone_values=[("item-2",)])
    rng2 = random.Random()
    rng2.random = lambda: 0.0
    result2 = wishlist_item_tick(cur2, fixed_clock, rng2)
    assert result2 == "item-2"
    sql2, params2 = next(c for c in cur2.calls if "update wishlist_items" in c[0])
    assert "removed_at" in sql2
    assert params2 == (fixed_clock(), "item-2")


def test_family_share_tick_open_close_pattern():
    # open branch: no open share -> insert with started_at, distinct owner/borrower
    cur = FakeCursor(fetchone_values=[None, ("user-1",), ("user-2",), ("share-1",)])
    result = family_share_tick(cur, fixed_clock, random.Random(0))
    assert result == "share-1"
    sql, params = next(c for c in cur.calls if "insert into family_shares" in c[0])
    assert "started_at" in sql
    assert params == ("user-1", "user-2", fixed_clock())

    # close branch: open share found -> update ended_at
    cur2 = FakeCursor(fetchone_values=[("share-2",)])
    rng2 = random.Random()
    rng2.random = lambda: 0.0
    result2 = family_share_tick(cur2, fixed_clock, rng2)
    assert result2 == "share-2"
    sql2, params2 = next(c for c in cur2.calls if "update family_shares" in c[0])
    assert "ended_at" in sql2
    assert params2 == (fixed_clock(), "share-2")


def test_review_tick_writes_a_review_for_a_fresh_pair():
    cur = FakeCursor(
        fetchone_values=[("user-1",), ("game-1",), None, ("review-1",)]
    )

    result = review_tick(cur, fixed_clock, random.Random(3))

    assert result == "review-1"
    insert_calls = [c for c in cur.calls if "insert into reviews" in c[0]]
    assert len(insert_calls) == 1
    _, params = insert_calls[0]
    assert params[0] == "user-1"
    assert params[1] == "game-1"
    assert params[4] == fixed_clock()


def test_review_tick_rejects_a_duplicate_user_game_pair():
    # the uniqueness pre-check finds an existing review for the pair, so the
    # tick must not attempt a second insert (no stored duplicate row).
    cur = FakeCursor(
        fetchone_values=[("user-1",), ("game-1",), ("existing-review-id",)]
    )

    result = review_tick(cur, fixed_clock, random.Random(3))

    assert result is None
    assert not any("insert into reviews" in c[0] for c in cur.calls)
