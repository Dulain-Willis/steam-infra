import importlib
from datetime import datetime, timedelta, timezone

import pytest
from fake_cursor import FakeCursor

import deletion_reversal
from deletion_reversal import reverse_deletion

USER_ID = "11111111-1111-1111-1111-111111111111"


def test_reverse_deletion_restores_the_user_within_the_grace_period():
    now = datetime(2026, 10, 21, tzinfo=timezone.utc)
    requested_at = now - timedelta(days=1)
    cur = FakeCursor(fetchone_values=[(USER_ID, requested_at, now)])

    result = reverse_deletion(cur, "alice", grace_period_seconds=30 * 86400)

    assert result == {"username": "alice", "user_id": USER_ID, "reversed": True}
    select_sql, select_params = cur.calls[0]
    assert select_params == ("alice",)
    update_sql, update_params = cur.calls[1]
    assert "update users set deletion_requested_at = null" in update_sql
    assert update_params == (USER_ID,)


def test_reverse_deletion_raises_once_the_grace_period_has_expired():
    now = datetime(2026, 10, 21, tzinfo=timezone.utc)
    requested_at = now - timedelta(days=31)
    cur = FakeCursor(fetchone_values=[(USER_ID, requested_at, now)])

    with pytest.raises(ValueError, match="grace period"):
        reverse_deletion(cur, "alice", grace_period_seconds=30 * 86400)

    # No update attempted once the window has passed.
    assert len(cur.calls) == 1


def test_reverse_deletion_raises_if_no_pending_request():
    now = datetime(2026, 10, 21, tzinfo=timezone.utc)
    cur = FakeCursor(fetchone_values=[(USER_ID, None, now)])

    with pytest.raises(ValueError, match="no pending deletion request"):
        reverse_deletion(cur, "alice", grace_period_seconds=30 * 86400)


def test_reverse_deletion_raises_for_unknown_user():
    cur = FakeCursor(fetchone_values=[None])

    with pytest.raises(ValueError, match="no such user"):
        reverse_deletion(cur, "ghost", grace_period_seconds=30 * 86400)


def test_grace_period_default_is_thirty_days_and_is_env_overridable(monkeypatch):
    monkeypatch.delenv("DELETION_GRACE_PERIOD_SECONDS", raising=False)
    importlib.reload(deletion_reversal)
    assert deletion_reversal.GRACE_PERIOD_SECONDS == 30 * 24 * 3600

    monkeypatch.setenv("DELETION_GRACE_PERIOD_SECONDS", "5")
    importlib.reload(deletion_reversal)
    assert deletion_reversal.GRACE_PERIOD_SECONDS == 5.0

    # Leave the module in its default state for any later test in this process.
    monkeypatch.delenv("DELETION_GRACE_PERIOD_SECONDS", raising=False)
    importlib.reload(deletion_reversal)
