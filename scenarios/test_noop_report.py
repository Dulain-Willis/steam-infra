from fake_cursor import FakeCursor
from noop_report import run


def test_run_reports_row_count_per_table():
    cur = FakeCursor(
        fetchall_values=[[("games",), ("users",)]],
        fetchone_values=[(3,), (7,)],
    )

    counts = run(cur)

    assert counts == {"games": 3, "users": 7}
    # One query to discover tables, then one count(*) per table, in order.
    assert cur.calls[0][0].strip().lower().startswith("select tablename")
    assert cur.calls[1][0] == "select count(*) from games;"
    assert cur.calls[2][0] == "select count(*) from users;"


def test_run_reports_zero_tables_for_an_empty_schema():
    cur = FakeCursor(fetchall_values=[[]])

    counts = run(cur)

    assert counts == {}
    assert len(cur.calls) == 1
