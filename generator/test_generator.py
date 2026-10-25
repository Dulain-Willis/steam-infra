import json
import random
from collections import Counter
from datetime import date, datetime, timedelta, timezone

import pytest

import dirty
import generator
from generator import (
    CLIENT_EVENT_REFERRERS,
    EVENT_HANDLERS,
    EVENT_WEIGHTS,
    FUNNEL_STEPS,
    PAYMENT_METHOD_NEW,
    PAYMENT_METHODS,
    REFUND_REASONS,
    _insert_purchase,
    client_events_tick,
    concurrent_player_snapshot_tick,
    family_share_tick,
    funnel_session,
    gift_redeem_tick,
    gift_send_tick,
    gift_tick,
    key_redemption_tick,
    pick_event_type,
    playtime_session_tick,
    price_change_tick,
    purchase_tick,
    refund_tick,
    restatement_tick,
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


@pytest.fixture(autouse=True)
def _reset_pending_late_users():
    # generator._pending_late_users is process-local state (#140); clear it
    # around every test so one test's scheduled late orphan can't leak into
    # another's assertions.
    generator._pending_late_users = []
    yield
    generator._pending_late_users = []


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


def _payment_method_from_insert(cur):
    sql, params = next(c for c in cur.calls if "insert into purchases" in c[0])
    return params[4]


def test_insert_purchase_never_emits_the_new_payment_method_before_onset_date():
    rng = random.Random(42)
    seen = set()
    for _ in range(200):
        # Two ids: _insert_purchase writes a second row on a
        # DUPLICATE_RATE_PURCHASES hit (#133), and these tests are about
        # the payment method, not duplication, so they must tolerate
        # either path rather than starving the cursor on a hit.
        cur = FakeCursor(fetchone_values=[("purchase-1",), ("purchase-1-dup",)])
        _insert_purchase(cur, fixed_clock, rng, "user-1", "game-1")
        seen.add(_payment_method_from_insert(cur))

    assert seen == set(PAYMENT_METHODS)
    assert PAYMENT_METHOD_NEW not in seen


def test_insert_purchase_emits_the_new_payment_method_on_and_after_onset_date(monkeypatch):
    monkeypatch.setattr(dirty, "PAYMENT_METHOD_NEW_ONSET_DATE", date(2020, 1, 1))

    rng = random.Random(42)
    seen = set()
    for _ in range(200):
        # Two ids: _insert_purchase writes a second row on a
        # DUPLICATE_RATE_PURCHASES hit (#133), and these tests are about
        # the payment method, not duplication, so they must tolerate
        # either path rather than starving the cursor on a hit.
        cur = FakeCursor(fetchone_values=[("purchase-1",), ("purchase-1-dup",)])
        _insert_purchase(cur, fixed_clock, rng, "user-1", "game-1")
        seen.add(_payment_method_from_insert(cur))

    assert seen == set(PAYMENT_METHODS) | {PAYMENT_METHOD_NEW}


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


def test_restatement_tick_reverses_a_historical_revocation(monkeypatch):
    # #138: a backdated correction. granted_at never enters this function
    # at all (the update statement doesn't even select it) -- proof that
    # it's untouched, not just unasserted.
    grant_id = "grant-1"
    cur = FakeCursor(fetchone_values=[(grant_id,)])

    result = restatement_tick(cur, fixed_clock, random.Random(7))

    assert result == grant_id
    select_calls = [c for c in cur.calls if c[0].startswith("select")]
    assert select_calls == [
        ("select id from ownership_grants where revoked_at is not null order by random() limit 1", None)
    ]
    update_calls = [c for c in cur.calls if c[0].startswith("update")]
    assert update_calls == [
        ("update ownership_grants set revoked_at = null, recorded_at = %s where id = %s",
         (fixed_clock(), grant_id))
    ]


def test_restatement_tick_is_a_noop_when_nothing_is_revoked():
    cur = FakeCursor(fetchone_values=[None])

    result = restatement_tick(cur, fixed_clock, random.Random(7))

    assert result is None
    assert len(cur.calls) == 1


def test_restatement_is_registered_as_a_rare_event_type():
    # Weight sourced from dirty.RESTATEMENT_WEIGHT (env-overridable, #130's
    # convention) and kept rarer than refund -- a correction should fire
    # less often than the original events it corrects.
    weights = dict(EVENT_WEIGHTS)
    assert weights["restatement"] == dirty.RESTATEMENT_WEIGHT
    assert weights["restatement"] < weights["refund"]


def test_tick_dispatches_to_restatement_on_a_seed_landing_there():
    # pick_event_type's `weights` default is bound to the EVENT_WEIGHTS
    # list object at def time, so an in-place mutation (not a monkeypatched
    # reassignment, which a bound default wouldn't see) is what actually
    # changes tick()'s draw here. Forcing restatement's weight
    # overwhelmingly high makes a fixed seed deterministically land on it
    # through the real weighted-choice dispatch -- the same fake-cursor/
    # forced-roll seam every other tick test uses, not a stubbed
    # pick_event_type.
    original_weights = list(generator.EVENT_WEIGHTS)
    generator.EVENT_WEIGHTS[:] = [("restatement", 1000.0), ("purchase", 1.0)]
    try:
        cur = FakeCursor(fetchone_values=[("grant-1",)])
        event_type = tick(cur, fixed_clock, random.Random(1))
    finally:
        generator.EVENT_WEIGHTS[:] = original_weights

    assert event_type == "restatement"
    assert any(c[0].startswith("update ownership_grants set revoked_at = null") for c in cur.calls)


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
    for (game_id, player_count, snapshot_at, recorded_at), expected_game_id in zip(
        (params for _, params in insert_calls), game_ids
    ):
        assert game_id == expected_game_id
        assert 0 <= player_count <= 60
        assert snapshot_at == fixed_clock()
        assert 0 <= (recorded_at - snapshot_at).total_seconds() <= 240


def test_tick_dispatches_to_the_selected_event_type():
    # seed 1 lands on "purchase" given today's EVENT_WEIGHTS.
    cur = FakeCursor(fetchone_values=[("u",), ("g",), ("p",)])
    event_type = tick(cur, fixed_clock, random.Random(1))

    assert event_type == "purchase"
    assert any("insert into purchases" in c[0] for c in cur.calls)


def test_playtime_session_tick_excludes_erased_users_from_the_start_branch():
    # steam-infra#129 integration review, finding 5: an anonymized user
    # row is still a live FK target, so the start branch's user pick must
    # exclude deletion_executed_at is not null rows or the generator keeps
    # writing fresh behavioural rows for an erased user.
    cur = FakeCursor(fetchone_values=[None, ("user-1",), ("game-1",), ("session-1",)])

    playtime_session_tick(cur, fixed_clock, random.Random(0))

    user_select = next(c for c in cur.calls if "from users" in c[0])
    assert "deletion_executed_at is null" in user_select[0]


def test_playtime_session_tick_starts_a_session_when_none_is_open():
    cur = FakeCursor(fetchone_values=[None, ("user-1",), ("game-1",), ("session-1",)])

    result = playtime_session_tick(cur, fixed_clock, random.Random(0))

    assert result == "session-1"
    sql, params = next(c for c in cur.calls if "insert into playtime_sessions" in c[0])
    assert "started_at" in sql
    assert params == ("user-1", "game-1", fixed_clock())
    assert not any("update playtime_sessions" in c[0] for c in cur.calls)


def test_playtime_session_tick_closes_an_open_session():
    # ended_at is derived from the row's own started_at (#136 code review
    # fix), not stamped at clock() -- see
    # test_playtime_session_tick_close_branch_duration_stays_bounded_after_late_arrival
    # for why.
    started_at = fixed_clock() - timedelta(minutes=5)
    cur = FakeCursor(fetchone_values=[("session-1", started_at)])
    rng = random.Random()
    rng.random = lambda: 0.0  # force the "close it" branch, and pin the duration roll to its floor

    result = playtime_session_tick(cur, fixed_clock, rng)

    assert result == "session-1"
    sql, params = next(c for c in cur.calls if "update playtime_sessions" in c[0])
    assert "ended_at" in sql
    ended_at, row_id = params
    assert row_id == "session-1"
    assert ended_at == started_at + timedelta(minutes=dirty.PLAYTIME_SESSION_MIN_MINUTES)
    assert not any("insert into playtime_sessions" in c[0] for c in cur.calls)


def test_wishlist_item_tick_open_close_pattern():
    # open branch: no open item -> insert with added_at
    cur = FakeCursor(fetchone_values=[None, ("user-1",), ("game-1",), ("item-1",)])
    result = wishlist_item_tick(cur, fixed_clock, random.Random(0))
    assert result == "item-1"
    sql, params = next(c for c in cur.calls if "insert into wishlist_items" in c[0])
    assert "added_at" in sql
    assert params == ("user-1", "game-1", fixed_clock())

    # close branch: open item found -> update removed_at. wishlist_items
    # has no late_arrival, so the close branch still stamps clock() --
    # the row's added_at is fetched (shared _open_close_tick query shape)
    # but ignored.
    cur2 = FakeCursor(fetchone_values=[("item-2", fixed_clock())])
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

    # close branch: open share found -> update ended_at. family_shares has
    # no late_arrival, so the close branch still stamps clock().
    cur2 = FakeCursor(fetchone_values=[("share-2", fixed_clock())])
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


class ForcedRoll(random.Random):
    """A real Random (so .choice()/.randint() etc. still work) whose
    .random() always returns a fixed value — used to force dirty-data rolls
    to hit or miss deterministically without derailing the tick's other
    rng draws."""

    def __init__(self, roll):
        super().__init__()
        self._roll = roll

    def random(self):
        return self._roll


def test_purchase_tick_jitters_recorded_at_after_purchased_at():
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), ("purchase-1",)])

    purchase_tick(cur, fixed_clock, random.Random(7))

    sql, params = next(c for c in cur.calls if "insert into purchases" in c[0])
    purchased_at, recorded_at = params[5], params[6]
    assert purchased_at == fixed_clock()
    assert 0 <= (recorded_at - purchased_at).total_seconds() <= 30


def test_review_tick_jitters_recorded_at_after_submitted_at():
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), None, ("review-1",)])

    review_tick(cur, fixed_clock, random.Random(3))

    _, params = next(c for c in cur.calls if "insert into reviews" in c[0])
    submitted_at, recorded_at = params[4], params[5]
    assert submitted_at == fixed_clock()
    assert 0 <= (recorded_at - submitted_at).total_seconds() <= 60


def test_refund_tick_nulls_reason_on_a_forced_roll():
    cur = FakeCursor(fetchone_values=[("grant-1", "purchase-1"), ("refund-1",)])

    refund_tick(cur, fixed_clock, ForcedRoll(0.0))

    refund_calls = [c for c in cur.calls if "insert into refunds" in c[0]]
    assert len(refund_calls) == 1
    assert refund_calls[0][1][1] is None  # reason


def test_refund_tick_keeps_reason_on_a_missed_roll():
    cur = FakeCursor(fetchone_values=[("grant-1", "purchase-1"), ("refund-1",)])

    refund_tick(cur, fixed_clock, ForcedRoll(0.99))

    _, params = next(c for c in cur.calls if "insert into refunds" in c[0])
    assert params[1] in REFUND_REASONS


def test_wishlist_item_tick_duplicates_the_add_on_a_forced_roll():
    cur = FakeCursor(fetchone_values=[None, ("user-1",), ("game-1",), ("item-1",), ("item-1",)])

    wishlist_item_tick(cur, fixed_clock, ForcedRoll(0.0))

    insert_calls = [c for c in cur.calls if "insert into wishlist_items" in c[0]]
    assert len(insert_calls) == 2
    assert insert_calls[0][1] == insert_calls[1][1]


def test_wishlist_item_tick_does_not_duplicate_on_a_missed_roll():
    cur = FakeCursor(fetchone_values=[None, ("user-1",), ("game-1",), ("item-1",)])

    wishlist_item_tick(cur, fixed_clock, ForcedRoll(0.99))

    insert_calls = [c for c in cur.calls if "insert into wishlist_items" in c[0]]
    assert len(insert_calls) == 1


def test_playtime_session_tick_duplicates_the_start_on_a_forced_roll():
    cur = FakeCursor(fetchone_values=[None, ("user-1",), ("game-1",), ("session-1",), ("session-1",)])

    playtime_session_tick(cur, fixed_clock, ForcedRoll(0.0))

    insert_calls = [c for c in cur.calls if "insert into playtime_sessions" in c[0]]
    assert len(insert_calls) == 2
    assert insert_calls[0][1] == insert_calls[1][1]


def test_purchase_tick_duplicates_the_purchase_on_a_forced_roll():
    cur = FakeCursor(
        fetchone_values=[("user-1",), ("game-1",), ("purchase-1",), ("purchase-1",)]
    )

    result = purchase_tick(cur, fixed_clock, ForcedRoll(0.0))

    assert result == "purchase-1"
    insert_calls = [c for c in cur.calls if "insert into purchases" in c[0]]
    assert len(insert_calls) == 2
    # distinct primary keys (per-row, generated by the DB -- not asserted
    # here), identical business key: the duplicate is a literal copy of
    # the same insert params.
    assert insert_calls[0][1] == insert_calls[1][1]

    # exactly one ownership grant, pointing at the first (and only
    # returned) purchase id -- revenue double-counts, ownership doesn't.
    grant_calls = [c for c in cur.calls if "ownership_grants" in c[0]]
    assert len(grant_calls) == 1
    assert grant_calls[0][1][2] == "purchase-1"


def test_purchase_tick_does_not_duplicate_on_a_missed_roll():
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), ("purchase-1",)])

    purchase_tick(cur, fixed_clock, ForcedRoll(0.99))

    assert len([c for c in cur.calls if "insert into purchases" in c[0]]) == 1


def test_key_redemption_tick_never_duplicates_even_on_a_forced_roll():
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), ("kr-1",)])

    key_redemption_tick(cur, fixed_clock, ForcedRoll(0.0))

    assert len([c for c in cur.calls if "insert into key_redemptions" in c[0]]) == 1


def test_gift_redeem_tick_never_duplicates_even_on_a_forced_roll():
    cur = FakeCursor(fetchone_values=[("gift-1", "recipient-1", "game-1")])

    gift_redeem_tick(cur, fixed_clock, ForcedRoll(0.0))

    assert len([c for c in cur.calls if "insert into ownership_grants" in c[0]]) == 1


def test_review_tick_never_duplicates_even_on_a_forced_roll():
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), None, ("review-1",)])

    review_tick(cur, fixed_clock, ForcedRoll(0.0))

    assert len([c for c in cur.calls if "insert into reviews" in c[0]]) == 1


def test_playtime_session_tick_does_not_duplicate_the_close_branch():
    # close branch also forces rng.random() == 0.0 (would hit duplicate_rate
    # too) — duplication must only ever be rolled on the start branch.
    cur = FakeCursor(fetchone_values=[("session-1", fixed_clock())])

    playtime_session_tick(cur, fixed_clock, ForcedRoll(0.0))

    insert_calls = [c for c in cur.calls if "insert into playtime_sessions" in c[0]]
    assert len(insert_calls) == 0
    assert any("update playtime_sessions" in c[0] for c in cur.calls)


def test_funnel_session_full_walk_when_every_advance_roll_passes():
    steps = funnel_session(ForcedRoll(0.0))
    assert steps == FUNNEL_STEPS


def test_funnel_session_stops_at_first_step_when_first_roll_drops():
    steps = funnel_session(ForcedRoll(0.99))
    assert steps == FUNNEL_STEPS[:1]


def test_funnel_session_always_returns_an_ordered_prefix_of_the_steps():
    rng = random.Random(7)
    for _ in range(500):
        steps = funnel_session(rng)
        assert 1 <= len(steps) <= len(FUNNEL_STEPS)
        assert steps == FUNNEL_STEPS[: len(steps)]


def test_funnel_session_produces_monotonic_drop_off():
    # Acceptance criterion (#12): ordered sequences with a realistic funnel
    # drop-off — each step reached by no more sessions than the one before.
    rng = random.Random(1)
    reached = Counter()
    for _ in range(20_000):
        for step in funnel_session(rng):
            reached[step] += 1
    counts = [reached[s] for s in FUNNEL_STEPS]
    assert counts == sorted(counts, reverse=True)
    assert counts[-1] > 0                      # some sessions complete the funnel
    assert counts[-1] < counts[0] // 2         # but far fewer than start it


def test_client_events_tick_excludes_erased_users_from_the_user_pick(monkeypatch):
    # steam-infra#129 integration review, finding 5: same guard as
    # playtime_session_tick's start branch -- an erased user's row is
    # anonymized, not gone, so the pick must filter it out explicitly.
    monkeypatch.setattr(dirty, "ORPHAN_NEVER_ARRIVES_RATE", 0.0)
    monkeypatch.setattr(dirty, "ORPHAN_LATE_ARRIVAL_RATE", 0.0)
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), ("campaign-1",)])

    client_events_tick(cur, fixed_clock, ForcedRoll(0.0))

    user_select = next(c for c in cur.calls if "from users" in c[0])
    assert "deletion_executed_at is null" in user_select[0]


def test_client_events_tick_writes_one_ordered_row_per_funnel_step(monkeypatch):
    # This test's concern is funnel/campaign behavior, not orphans -- pin
    # both orphan rates to 0 so ForcedRoll(0.0)'s all-hits forcing doesn't
    # also roll an orphan (see the dedicated orphan tests below).
    monkeypatch.setattr(dirty, "ORPHAN_NEVER_ARRIVES_RATE", 0.0)
    monkeypatch.setattr(dirty, "ORPHAN_LATE_ARRIVAL_RATE", 0.0)
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), ("campaign-1",)])

    session_id = client_events_tick(cur, fixed_clock, ForcedRoll(0.0))

    inserts = [(sql, params) for sql, params in cur.calls if "insert into client_events" in sql]
    assert len(inserts) == len(FUNNEL_STEPS)

    prev_at = None
    for i, (_, params) in enumerate(inserts):
        occurred_at, user_id, sid, game_id, event_name, props = params
        assert user_id == "user-1"
        assert sid == session_id
        assert event_name == FUNNEL_STEPS[i]
        # store_page_view is store-wide; every later step carries the game
        assert game_id == (None if event_name == "store_page_view" else "game-1")
        if prev_at is not None:
            assert occurred_at >= prev_at
        prev_at = occurred_at

    props = json.loads(inserts[0][1][5])
    assert props["referrer"] in CLIENT_EVENT_REFERRERS
    assert props["campaign_id"] == "campaign-1"   # 0.0 roll < CLIENT_EVENT_CAMPAIGN_CHANCE


def test_client_events_tick_omits_campaign_id_when_roll_misses():
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), ("campaign-1",)])

    client_events_tick(cur, fixed_clock, ForcedRoll(0.99))

    inserts = [p for sql, p in cur.calls if "insert into client_events" in sql]
    assert len(inserts) == 1                      # 0.99 roll drops the funnel immediately
    props = json.loads(inserts[0][5])
    assert props["campaign_id"] is None


def test_client_events_tick_handles_no_campaigns_seeded(monkeypatch):
    monkeypatch.setattr(dirty, "ORPHAN_NEVER_ARRIVES_RATE", 0.0)
    monkeypatch.setattr(dirty, "ORPHAN_LATE_ARRIVAL_RATE", 0.0)
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), None])

    client_events_tick(cur, fixed_clock, ForcedRoll(0.0))

    inserts = [p for sql, p in cur.calls if "insert into client_events" in sql]
    props = json.loads(inserts[0][5])
    assert props["campaign_id"] is None


def test_client_events_tick_emits_a_never_arriving_orphan_on_a_forced_roll(monkeypatch):
    monkeypatch.setattr(dirty, "ORPHAN_NEVER_ARRIVES_RATE", 1.0)
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), ("campaign-1",)])

    client_events_tick(cur, fixed_clock, ForcedRoll(0.0))

    inserts = [p for sql, p in cur.calls if "insert into client_events" in sql]
    user_ids = {p[1] for p in inserts}
    assert user_ids != {"user-1"}          # the seeded user was swapped out for an orphan id
    assert len(user_ids) == 1              # every row in the session shares the one orphan id
    assert not any("insert into users" in sql for sql, _ in cur.calls)
    assert generator._pending_late_users == []   # "never" schedules nothing


def test_client_events_tick_emits_a_late_arriving_orphan_on_a_forced_roll(monkeypatch):
    monkeypatch.setattr(dirty, "ORPHAN_NEVER_ARRIVES_RATE", 0.0)
    monkeypatch.setattr(dirty, "ORPHAN_LATE_ARRIVAL_RATE", 1.0)
    monkeypatch.setattr(dirty, "ORPHAN_LATE_ARRIVAL_DELAY_SECONDS", 90)
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), ("campaign-1",)])

    client_events_tick(cur, fixed_clock, ForcedRoll(0.0))

    inserts = [p for sql, p in cur.calls if "insert into client_events" in sql]
    user_ids = {p[1] for p in inserts}
    assert user_ids != {"user-1"}
    assert not any("insert into users" in sql for sql, _ in cur.calls)   # not yet -- it's scheduled

    [(orphan_user_id, due_at)] = generator._pending_late_users
    assert orphan_user_id in user_ids
    assert due_at == fixed_clock() + timedelta(seconds=90)


def test_emit_due_late_users_is_a_noop_before_the_delay_elapses():
    cur = FakeCursor()
    generator._pending_late_users = [("orphan-1", fixed_clock() + timedelta(seconds=90))]

    generator._emit_due_late_users(cur, fixed_clock())

    assert cur.calls == []
    assert generator._pending_late_users == [("orphan-1", fixed_clock() + timedelta(seconds=90))]


def test_emit_due_late_users_inserts_the_parent_once_due_and_drains_it():
    cur = FakeCursor()
    due_at = fixed_clock() + timedelta(seconds=90)
    generator._pending_late_users = [("orphan-1", due_at)]

    generator._emit_due_late_users(cur, due_at)

    inserts = [p for sql, p in cur.calls if "insert into users" in sql]
    assert len(inserts) == 1
    assert inserts[0][0] == "orphan-1"
    assert generator._pending_late_users == []   # drained, not re-inserted on a later tick


def test_tick_flushes_due_late_users_before_dispatching():
    due_at = fixed_clock()
    generator._pending_late_users = [("orphan-1", due_at)]
    cur = FakeCursor(fetchone_values=[("u",), ("g",), ("p",)])

    tick(cur, fixed_clock, random.Random(1))   # seed 1 lands on "purchase"

    assert any("insert into users" in sql for sql, _ in cur.calls)
    assert generator._pending_late_users == []


# -- #136: late-arriving events ---------------------------------------------


def test_playtime_session_tick_backdates_started_at_on_a_forced_late_roll(monkeypatch):
    monkeypatch.setattr(dirty, "LATE_ARRIVAL_RATE", 1.0)
    monkeypatch.setattr(dirty, "LATE_ARRIVAL_MAX_DAYS", 7)
    cur = FakeCursor(fetchone_values=[None, ("user-1",), ("game-1",), ("session-1",)])
    # should_duplicate's roll follows the late-arrival roll; pin its rate to
    # 0 so this test stays about late arrival, not duplication.
    monkeypatch.setitem(dirty.DUPLICATE_RATES, "playtime_sessions", 0.0)

    playtime_session_tick(cur, fixed_clock, random.Random(7))

    sql, params = next(c for c in cur.calls if "insert into playtime_sessions" in c[0])
    started_at = params[2]
    # backdated: strictly before clock(), but never beyond the tail bound
    assert started_at < fixed_clock()
    assert fixed_clock() - started_at <= timedelta(days=7)
    # recorded_at is never named in the insert -- it's left at its database
    # default (now()), the real insert time, untouched by the backdating.
    assert "recorded_at" not in sql


def test_playtime_session_tick_never_backdates_on_a_miss(monkeypatch):
    monkeypatch.setattr(dirty, "LATE_ARRIVAL_RATE", 0.0)
    cur = FakeCursor(fetchone_values=[None, ("user-1",), ("game-1",), ("session-1",)])

    playtime_session_tick(cur, fixed_clock, random.Random(7))

    sql, params = next(c for c in cur.calls if "insert into playtime_sessions" in c[0])
    assert params[2] == fixed_clock()


def test_playtime_session_tick_close_branch_duration_stays_bounded_after_late_arrival(monkeypatch):
    # #136 code review fix: a late-arriving session's close branch must not
    # manufacture a multi-day duration by stamping clock() against a
    # started_at backdated by up to LATE_ARRIVAL_MAX_DAYS. ended_at is
    # derived from the row's own started_at instead, so the resulting
    # duration always stays within dirty's realistic playtime-session
    # bound, not the (fixed_clock() - backdated started_at) gap.
    monkeypatch.setattr(dirty, "PLAYTIME_SESSION_MIN_MINUTES", 1)
    monkeypatch.setattr(dirty, "PLAYTIME_SESSION_MAX_MINUTES", 180)
    backdated_started_at = fixed_clock() - timedelta(days=7)
    cur = FakeCursor(fetchone_values=[("session-1", backdated_started_at)])
    rng = random.Random()
    rng.random = lambda: 0.0  # force the "close it" branch, and pin the duration roll to its floor

    playtime_session_tick(cur, fixed_clock, rng)

    sql, params = next(c for c in cur.calls if "update playtime_sessions" in c[0])
    ended_at, row_id = params
    assert row_id == "session-1"
    duration = ended_at - backdated_started_at
    assert timedelta(minutes=1) <= duration <= timedelta(minutes=180)
    # the bug this guards: stamping clock() here would have produced a
    # ~7-day duration instead.
    assert duration < timedelta(days=1)


def test_wishlist_item_tick_never_backdates_even_on_a_forced_late_roll(monkeypatch):
    # late arrival is wired only through playtime_session_tick's
    # late_arrival=True -- wishlist_items has no physically plausible
    # offline client and must stay on clock() unconditionally.
    monkeypatch.setattr(dirty, "LATE_ARRIVAL_RATE", 1.0)
    cur = FakeCursor(fetchone_values=[None, ("user-1",), ("game-1",), ("item-1",)])

    wishlist_item_tick(cur, fixed_clock, random.Random(0))

    sql, params = next(c for c in cur.calls if "insert into wishlist_items" in c[0])
    assert params == ("user-1", "game-1", fixed_clock())


def test_client_events_tick_backdates_occurred_at_on_a_forced_late_roll(monkeypatch):
    monkeypatch.setattr(dirty, "LATE_ARRIVAL_RATE", 1.0)
    monkeypatch.setattr(dirty, "LATE_ARRIVAL_MAX_DAYS", 7)
    monkeypatch.setattr(dirty, "ORPHAN_NEVER_ARRIVES_RATE", 0.0)
    monkeypatch.setattr(dirty, "ORPHAN_LATE_ARRIVAL_RATE", 0.0)
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), ("campaign-1",)])

    client_events_tick(cur, fixed_clock, random.Random(7))

    inserts = [(sql, p) for sql, p in cur.calls if "insert into client_events" in sql]
    assert inserts   # the funnel always emits at least store_page_view
    for sql, params in inserts:
        occurred_at = params[0]
        assert occurred_at < fixed_clock()
        assert fixed_clock() - occurred_at <= timedelta(days=7)
        assert "recorded_at" not in sql   # arrival timestamp stays at its db default


def test_client_events_tick_never_backdates_on_a_miss(monkeypatch):
    monkeypatch.setattr(dirty, "LATE_ARRIVAL_RATE", 0.0)
    monkeypatch.setattr(dirty, "ORPHAN_NEVER_ARRIVES_RATE", 0.0)
    monkeypatch.setattr(dirty, "ORPHAN_LATE_ARRIVAL_RATE", 0.0)
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), ("campaign-1",)])

    client_events_tick(cur, fixed_clock, random.Random(7))

    inserts = [p for sql, p in cur.calls if "insert into client_events" in sql]
    assert inserts[0][0] == fixed_clock()


def test_late_arrival_does_not_touch_the_existing_jitter_mechanism(monkeypatch):
    # AC: "the existing jitter mechanism is untouched." purchase/review/
    # snapshot still go through dirty.jittered() alone, never
    # dirty.late_arrival_offset() -- forcing late arrival to always hit must
    # not change a purchase_tick insert at all.
    monkeypatch.setattr(dirty, "LATE_ARRIVAL_RATE", 1.0)
    cur = FakeCursor(fetchone_values=[("user-1",), ("game-1",), ("purchase-1",)])

    purchase_tick(cur, fixed_clock, random.Random(7))

    sql, params = next(c for c in cur.calls if "insert into purchases" in c[0])
    purchased_at, recorded_at = params[5], params[6]
    assert purchased_at == fixed_clock()
    assert recorded_at >= purchased_at
    assert recorded_at - purchased_at <= timedelta(seconds=dirty.PURCHASE_RECORDED_AT_JITTER_MAX_SECONDS)
