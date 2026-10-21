# Fault record: <scenario name>

- **Module**: `scenarios/<module>.py`
- **Entrypoint**: `scripts/scenarios/run.sh <module>`

## Fault

What this scenario injects, in one or two sentences. If it injects
nothing (a reference/control scenario), say so plainly.

## Blast radius

Which tables/rows are touched, directly and downstream (replication slot,
Kafka, Snowflake, dbt models) — how far the effect spreads if nothing
catches it.

## Detection

How a human or an automated check would notice this happened: a query, a
dbt test, a monitor, a log line.

## Handling

What's expected to catch or repair it: existing code, a follow-up ticket,
or "nothing yet" if the scenario exists to prove a gap.
