import os

from fake_cursor import FakeCursor
from games_add_column import run


def test_run_adds_the_new_nullable_column_by_default(monkeypatch):
    monkeypatch.delenv("GAMES_ADD_COLUMN_REVERSE", raising=False)
    cur = FakeCursor()

    run(cur)

    assert len(cur.calls) == 1
    sql, params = cur.calls[0]
    assert sql.strip().lower() == "alter table games add column if not exists early_access boolean;"
    assert params is None


def test_run_drops_the_column_when_reverse_is_set(monkeypatch):
    monkeypatch.setenv("GAMES_ADD_COLUMN_REVERSE", "true")
    cur = FakeCursor()

    run(cur)

    assert len(cur.calls) == 1
    sql, params = cur.calls[0]
    assert sql.strip().lower() == "alter table games drop column if exists early_access;"
    assert params is None
