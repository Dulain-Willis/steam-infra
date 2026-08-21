"""Dirty-data injection: null rates, literal duplicate rows, and recorded_at
jitter, layered onto the event writers from #12/#13/#14 (issue #15).

Every roll takes the caller's rng, so injection stays seeded and forceable
from tests — same discipline as tick()'s clock/rng injection.
"""

from datetime import timedelta

REFUND_REASON_NULL_RATE = 0.15

WISHLIST_ADD_DUPLICATE_RATE = 0.02
PLAYTIME_START_DUPLICATE_RATE = 0.01

# Tables that must never receive a literal duplicate row, even on a
# "should duplicate" roll — ownership/identity events where a second row
# would misrepresent state (double purchase, double refund, ...) rather
# than just add noise.
DUPLICATE_SKIP_LIST = {"purchases", "refunds", "key_redemptions", "gifts", "reviews"}

PURCHASE_RECORDED_AT_JITTER_MAX_SECONDS = 30
REVIEW_RECORDED_AT_JITTER_MAX_SECONDS = 60
SNAPSHOT_RECORDED_AT_JITTER_MAX_SECONDS = 240  # "a few minutes"


def maybe_null(rng, rate, value):
    """Rolls to drop value to None at the given rate; otherwise passes it through."""
    return None if rng.random() < rate else value


def jittered(event_time, rng, max_seconds):
    """event_time plus a uniform 0..max_seconds offset, for a recorded_at
    that lands after (never before) the event it's recording."""
    return event_time + timedelta(seconds=rng.uniform(0, max_seconds))


def should_duplicate(rng, rate, table):
    """Rolls for a literal duplicate insert. Tables on DUPLICATE_SKIP_LIST
    never duplicate, even on a roll that would otherwise hit — enforced here
    so duplication can't get wired onto an ownership table by a call site
    skipping the allowlist check.
    """
    if table in DUPLICATE_SKIP_LIST:
        return False
    return rng.random() < rate
