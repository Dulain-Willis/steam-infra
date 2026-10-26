import importlib
from datetime import datetime, timedelta, timezone

import pytest
from fake_cursor import FakeCursor

import deletion_execution
from deletion_execution import HARD_DELETE_TABLES, execute_deletion

USER_ID = "11111111-1111-1111-1111-111111111111"


def test_execute_deletion_raises_before_the_grace_period_has_elapsed():
    now = datetime(2026, 10, 21, tzinfo=timezone.utc)
    requested_at = now - timedelta(days=1)
    cur = FakeCursor(fetchone_values=[(USER_ID, requested_at, None, now)])

    with pytest.raises(ValueError, match="grace period"):
        execute_deletion(cur, "alice", grace_period_seconds=30 * 86400)

    # Nothing beyond the initial select is attempted once refused.
    assert len(cur.calls) == 1


def test_execute_deletion_raises_if_already_executed():
    # steam-infra#129 integration review, finding 9: deletion_executed_at
    # is the durable marker that execution already ran -- a second call
    # for the same user must refuse rather than re-tombstoning an
    # already-anonymized row (deletion_requested_at is never cleared here,
    # so that column alone can't distinguish "never erased" from "already
    # erased").
    now = datetime(2026, 10, 21, tzinfo=timezone.utc)
    requested_at = now - timedelta(days=31)
    executed_at = now - timedelta(days=1)
    cur = FakeCursor(fetchone_values=[(USER_ID, requested_at, executed_at, now)])

    with pytest.raises(ValueError, match="already erased"):
        execute_deletion(cur, "alice", grace_period_seconds=30 * 86400)

    assert len(cur.calls) == 1


def test_execute_deletion_hard_deletes_behavioural_rows_and_anonymizes_the_user():
    now = datetime(2026, 10, 21, tzinfo=timezone.utc)
    requested_at = now - timedelta(days=31)
    cur = FakeCursor(
        fetchone_values=[(USER_ID, requested_at, None, now), (USER_ID,)],
        # One fetchall() per HARD_DELETE_TABLES entry, in order.
        fetchall_values=[[(1,), (2,)], [(1,)], []],
    )

    result = execute_deletion(cur, "alice", grace_period_seconds=30 * 86400)

    assert result["username"] == "alice"
    assert result["user_id"] == USER_ID
    assert result["hard_deleted"] == {
        "client_events": 2,
        "playtime_sessions": 1,
        "wishlist_items": 0,
    }
    assert result["anonymized"] is True

    # Behavioural tables are hard-deleted by user_id, in the declared order.
    delete_calls = [c for c in cur.calls if c[0].strip().lower().startswith("delete")]
    assert len(delete_calls) == len(HARD_DELETE_TABLES)
    for table, (sql, params) in zip(HARD_DELETE_TABLES, delete_calls):
        assert f"delete from {table} where user_id" in sql
        assert params == (USER_ID,)

    # The user row is anonymized in place, not deleted -- foreign keys stay intact.
    update_calls = [c for c in cur.calls if "update users" in c[0].lower()]
    assert len(update_calls) == 1
    update_sql, update_params = update_calls[0]
    assert "where id = %s" in update_sql
    assert "deletion_executed_at" in update_sql
    tombstone_username, tombstone_email, executed_at, updated_user_id = update_params
    assert USER_ID in tombstone_username
    assert USER_ID in tombstone_email
    assert executed_at == now
    assert updated_user_id == USER_ID

    # The hard deletes and the anonymize both happen inside one explicit
    # transaction (the caller's connection runs autocommit -- see
    # scenarios/_run.py -- so without this a dropped connection partway
    # through could leave tier 1 done and tier 2 not).
    assert cur.calls[1][0].strip() == "begin;"
    assert cur.calls[-1][0].strip() == "commit;"


def test_execute_deletion_raises_if_no_pending_request():
    now = datetime(2026, 10, 21, tzinfo=timezone.utc)
    cur = FakeCursor(fetchone_values=[(USER_ID, None, None, now)])

    with pytest.raises(ValueError, match="no pending deletion request"):
        execute_deletion(cur, "alice", grace_period_seconds=30 * 86400)


def test_execute_deletion_raises_for_unknown_user():
    cur = FakeCursor(fetchone_values=[None])

    with pytest.raises(ValueError, match="no such user"):
        execute_deletion(cur, "ghost", grace_period_seconds=30 * 86400)


def test_grace_period_default_is_thirty_days_and_is_env_overridable(monkeypatch):
    monkeypatch.delenv("DELETION_GRACE_PERIOD_SECONDS", raising=False)
    importlib.reload(deletion_execution)
    assert deletion_execution.GRACE_PERIOD_SECONDS == 30 * 24 * 3600

    monkeypatch.setenv("DELETION_GRACE_PERIOD_SECONDS", "5")
    importlib.reload(deletion_execution)
    assert deletion_execution.GRACE_PERIOD_SECONDS == 5.0

    # Leave the module in its default state for any later test in this process.
    monkeypatch.delenv("DELETION_GRACE_PERIOD_SECONDS", raising=False)
    importlib.reload(deletion_execution)
