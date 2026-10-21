"""Fake cursor for scenario unit tests.

Same shape as generator/test_generator.py's FakeCursor (records
executed statements, returns canned fetchone()/fetchall() values in
order) but duplicated here rather than imported, so scenario code and
its tests never reach into the generator's tick path (#131 AC: no
scenario module imports from generator.py).
"""


class FakeCursor:
    """Stands in for psycopg2's cursor so scenario functions are testable
    without a live Postgres connection."""

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
