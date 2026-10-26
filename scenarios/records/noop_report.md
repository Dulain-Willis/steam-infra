# Fault record: no-op reference

- **Module**: `scenarios/noop_report.py`
- **Entrypoint**: `scripts/scenarios/run.sh noop_report`

## Fault

None. This is the reference/control scenario the harness (#131) was
proven against: it connects to the live database and reports a row
count per table in the public schema, injecting nothing.

## Blast radius

None. Read-only (`select count(*)` per table), no writes, no schema
changes. Nothing downstream — replication slot, Kafka, Snowflake, dbt —
is touched.

## Detection

Not applicable — no fault occurs. A broken harness surfaces as a
non-zero exit from `scripts/scenarios/run.sh` (tunnel never came up, a
table query failed) or as the logged per-table counts looking wrong.

## Handling

Not applicable. Its job is to prove the shape — a cursor-taking
`run(cur)` function, a fake-cursor unit-test seam, and a tunnel-reusing
entrypoint — works end to end before #142 (deletion request), #143
(erasure execution) and #144 (additive migration) write real faults
against the same shape.
