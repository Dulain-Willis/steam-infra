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
from datetime import timedelta


def _env_float(name, default):
    """Reads NAME from the environment as a float, falling back to the
    given code default (a string, matching os.environ's own type) when
    unset. The one mechanism every injection knob in this module goes
    through."""
    return float(os.environ.get(name, default))


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

# Per-table duplicate rates: explicit configuration only, one env var per
# table that wants one. A table with no entry here has no rate and never
# duplicates -- there's no implicit default and no allowlist to bypass, which
# is why the old DUPLICATE_SKIP_LIST and its guard are gone (#130): a table
# can no longer be wired into duplication by accident, because wiring it in
# is the only way it gets a rate at all. Add a table by adding one line here.
DUPLICATE_RATES = {
    "wishlist_items": _env_float("DUPLICATE_RATE_WISHLIST_ITEMS", "0.02"),
    "playtime_sessions": _env_float("DUPLICATE_RATE_PLAYTIME_SESSIONS", "0.01"),
}


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
