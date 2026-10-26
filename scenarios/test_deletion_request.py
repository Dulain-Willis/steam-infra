import pytest
from fake_cursor import FakeCursor

from deletion_request import request_deletion


def test_request_deletion_marks_the_named_user():
    user_id = "11111111-1111-1111-1111-111111111111"
    requested_at = "2026-10-21T00:00:00+00:00"
    cur = FakeCursor(
        fetchone_values=[(user_id, None), (requested_at,)],
    )

    result = request_deletion(cur, "alice")

    assert result == {
        "username": "alice",
        "user_id": user_id,
        "deletion_requested_at": requested_at,
    }
    select_sql, select_params = cur.calls[0]
    assert "where username = %s" in select_sql
    assert select_params == ("alice",)
    update_sql, update_params = cur.calls[1]
    assert "update users set deletion_requested_at = now()" in update_sql
    assert update_params == (user_id,)


def test_request_deletion_raises_for_unknown_user():
    cur = FakeCursor(fetchone_values=[None])

    with pytest.raises(ValueError, match="no such user"):
        request_deletion(cur, "ghost")


def test_request_deletion_raises_if_already_pending():
    user_id = "11111111-1111-1111-1111-111111111111"
    cur = FakeCursor(fetchone_values=[(user_id, "2026-09-01T00:00:00+00:00")])

    with pytest.raises(ValueError, match="already has a pending deletion request"):
        request_deletion(cur, "alice")

    # No update should have been attempted.
    assert len(cur.calls) == 1
