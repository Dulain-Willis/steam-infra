"""Dirty-data injection: null rates, literal duplicate rows, and recorded_at
jitter, layered onto the event writers from #12/#13/#14 (issue #15).

Every injection knob reads from the environment with a code default -- the
same convention generator.py's TICK_MIN/MAX_SECONDS already uses -- so any
fault can be forced to appear at bring-up without rebuilding the image.
Adding a knob (#133/#136/#138/#139/#140) means one _env_float() (or a sibling
helper of the right type) here, read at its call site -- nothing structural
to touch.

Every roll takes the caller's rng, so injection stays seeded and forceable
from tests -- same discipline as tick()'s clock/rng injection.
"""

import os
from datetime import date, timedelta


def _env_float(name, default):
    """Reads NAME from the environment as a float, falling back to the
    given code default (a string, matching os.environ's own type) when
    unset. The one mechanism every injection knob in this module goes
    through."""
    return float(os.environ.get(name, default))


def _env_date(name, default):
    """Reads NAME from the environment as an ISO (YYYY-MM-DD) date, falling
    back to the given code default (a string, matching os.environ's own
    type) when unset. Sibling to _env_float for knobs that are a dated
    switch rather than a rate -- #139's onset date is the first of these."""
    return date.fromisoformat(os.environ.get(name, default))


REFUND_REASON_NULL_RATE = _env_float("REFUND_REASON_NULL_RATE", "0.15")

PURCHASE_RECORDED_AT_JITTER_MAX_SECONDS = _env_float(
    "PURCHASE_RECORDED_AT_JITTER_MAX_SECONDS", "30"
)
REVIEW_RECORDED_AT_JITTER_MAX_SECONDS = _env_float(
    "REVIEW_RECORDED_AT_JITTER_MAX_SECONDS", "60"
)
SNAPSHOT_RECORDED_AT_JITTER_MAX_SECONDS = _env_float(
    "SNAPSHOT_RECORDED_AT_JITTER_MAX_SECONDS", "240"  # "a few minutes"
)

# A new payment method starts appearing once purchased_at crosses this date
# -- a dated switch (like a product launch), not a probability roll. Default
# is far enough out that default generator output is unaffected; override to
# force the new value to appear at bring-up without rebuilding the image.
PAYMENT_METHOD_NEW_ONSET_DATE = _env_date(
    "PAYMENT_METHOD_NEW_ONSET_DATE", "2099-01-01"
)

# Per-table duplicate rates: explicit configuration only, one env var per
# table that wants one. A table with no entry here has no rate and never
# duplicates -- there's no implicit default and no allowlist to bypass, which
# is why the old DUPLICATE_SKIP_LIST and its guard are gone (#130): a table
# can no longer be wired into duplication by accident, because wiring it in
# is the only way it gets a rate at all. Add a table by adding one line here.
DUPLICATE_RATES = {
    "wishlist_items": _env_float("DUPLICATE_RATE_WISHLIST_ITEMS", "0.02"),
    "playtime_sessions": _env_float("DUPLICATE_RATE_PLAYTIME_SESSIONS", "0.01"),
    # purchases: the double-submitted-charge shape (#133) -- a retried
    # charge writes a second purchases row with an identical business key
    # (user/game/amount/purchased_at) but only the first ever gets an
    # ownership_grants row. reviews/game_prices/key_redemptions are left
    # out deliberately: each carries a unique constraint (db/schema.sql)
    # that makes a literal duplicate row physically impossible there.
    "purchases": _env_float("DUPLICATE_RATE_PURCHASES", "0.02"),
}


# client_events.user_id orphans (#140): the FK to users is gone, so two
# flavours of "parent not there yet" become possible. Two plain knobs, not a
# per-table dict -- orphaning only ever applies to this one table/column, so
# there's no shape to generalize (don't add a second DUPLICATE_RATES-style
# dict for this).
ORPHAN_NEVER_ARRIVES_RATE = _env_float("ORPHAN_NEVER_ARRIVES_RATE", "0.01")
ORPHAN_LATE_ARRIVAL_RATE = _env_float("ORPHAN_LATE_ARRIVAL_RATE", "0.03")
ORPHAN_LATE_ARRIVAL_DELAY_SECONDS = _env_float("ORPHAN_LATE_ARRIVAL_DELAY_SECONDS", "90")


# Late-arriving rows (#136): a distinct mechanism from jittered() above, not
# a widening of it. jittered() nudges recorded_at forward from an
# already-correct event time -- ordinary write latency, feeding the source
# freshness fact. This instead backdates the event-time column itself and
# leaves recorded_at at its database default (the real insert time) -- what
# an offline client upload looks like, with no simulated clock needed.
# Applies only to client_events.occurred_at and playtime_sessions.started_at
# -- the two columns with a physically plausible offline client. Default
# rate is low and the tail bound (#134's lookback window is double this) is
# 7 days, so the ordinary case stays same-second and the freshness signal
# stays undisturbed.
LATE_ARRIVAL_RATE = _env_float("LATE_ARRIVAL_RATE", "0.01")
LATE_ARRIVAL_MAX_DAYS = _env_float("LATE_ARRIVAL_MAX_DAYS", "7")


def late_arrival_offset(rng):
    """Rolls at LATE_ARRIVAL_RATE for a late-arriving row. On a hit, returns
    a timedelta backdating the event-time column by a uniform 0..
    LATE_ARRIVAL_MAX_DAYS interval -- never more than the configured tail
    bound. On a miss (the overwhelming majority at the default rate),
    returns None, meaning "insert at clock() as normal."
    """
    if rng.random() < LATE_ARRIVAL_RATE:
        return timedelta(days=rng.uniform(0, LATE_ARRIVAL_MAX_DAYS))
    return None


# A realistic playtime session length (#136 code review fix): the close
# branch of generator._open_close_tick derives ended_at from this, added to
# the row's own started_at, instead of stamping clock() -- stamping clock()
# against a started_at that late_arrival_offset() backdated by up to
# LATE_ARRIVAL_MAX_DAYS would manufacture a multi-day session instead of
# just delaying when it arrived. Applies uniformly (not just on a late-
# arrival hit) so one formula covers both cases -- the ordinary case was
# already a realistic length, so this doesn't change its character, just
# its source of truth.
PLAYTIME_SESSION_MIN_MINUTES = _env_float("PLAYTIME_SESSION_MIN_MINUTES", "1")
PLAYTIME_SESSION_MAX_MINUTES = _env_float("PLAYTIME_SESSION_MAX_MINUTES", "180")


def playtime_session_duration(rng):
    """A uniform PLAYTIME_SESSION_MIN_MINUTES..PLAYTIME_SESSION_MAX_MINUTES
    session length, as a timedelta."""
    return timedelta(
        minutes=rng.uniform(PLAYTIME_SESSION_MIN_MINUTES, PLAYTIME_SESSION_MAX_MINUTES)
    )


def orphan_flavor(rng):
    """Rolls once against a shared budget for client_events' two orphan
    parent flavours: ORPHAN_NEVER_ARRIVES_RATE (checked first) for a parent
    that never arrives, then ORPHAN_LATE_ARRIVAL_RATE for a parent that
    arrives ORPHAN_LATE_ARRIVAL_DELAY_SECONDS later. Returns "never", "late",
    or None for a normal, already-seeded parent."""
    roll = rng.random()
    if roll < ORPHAN_NEVER_ARRIVES_RATE:
        return "never"
    if roll < ORPHAN_NEVER_ARRIVES_RATE + ORPHAN_LATE_ARRIVAL_RATE:
        return "late"
    return None


def maybe_null(rng, rate, value):
    """Rolls to drop value to None at the given rate; otherwise passes it through."""
    return None if rng.random() < rate else value


def jittered(event_time, rng, max_seconds):
    """event_time plus a uniform 0..max_seconds offset, for a recorded_at
    that lands after (never before) the event it's recording."""
    return event_time + timedelta(seconds=rng.uniform(0, max_seconds))


def should_duplicate(rng, table):
    """Rolls for a literal duplicate insert at table's configured rate in
    DUPLICATE_RATES. A table absent from that dict has rate 0, so it never
    duplicates."""
    return rng.random() < DUPLICATE_RATES.get(table, 0.0)


def should_emit_new_payment_method(purchased_at):
    """True once purchased_at's date is on or after
    PAYMENT_METHOD_NEW_ONSET_DATE. A dated switch, not a roll -- no rng
    involved, so the same purchased_at always gets the same answer."""
    return purchased_at.date() >= PAYMENT_METHOD_NEW_ONSET_DATE


# Backdated restatement of a historical row (#138): a correction landing
# long after the original event, with the event-time column left untouched
# so the row reads as a restatement of an old period rather than a new
# event -- what a reversed/late-processed refund looks like in a source
# system. Wired in as an EVENT_WEIGHTS entry (generator.py) rather than a
# rng.random() roll inside an existing tick, so operators can crank it for
# a live demo the same way every other event's relative frequency is
# tuned, without touching any other tick's existing rng draw sequence.
RESTATEMENT_WEIGHT = _env_float("RESTATEMENT_WEIGHT", "0.2")
