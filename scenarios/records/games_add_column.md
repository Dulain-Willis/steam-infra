# Fault record: additive upstream migration

- **Module**: `scenarios/games_add_column.py`
- **Entrypoint**: `scripts/scenarios/run.sh games_add_column`
  (reverse: `GAMES_ADD_COLUMN_REVERSE=true scripts/scenarios/run.sh games_add_column`)

## Fault

An upstream team adds a new nullable column (`games.early_access
boolean`) directly against the source database, without telling anyone
and without a coordinated release. This models the overwhelming majority
of real-world upstream migrations: additive, backwards-compatible, no
warning. Type widening/narrowing and renames are deliberate follow-ups,
out of scope here — this scenario is additive only.

The `alter table` is idempotent in both directions (`add column if not
exists` / `drop column if exists`), so running it twice, or running the
reverse before the forward ever ran, is a no-op rather than an error.

## Blast radius

- **Source (`games` table)**: one new nullable column. Every existing
  row gets `NULL` for it; no existing row or query is affected, since
  nothing in the generator or any other scenario reads or writes it.
- **Debezium / landing table**: Snowflake's schema-evolution
  (`snowflake.enable.schematization=true`, ADR 0001) adds the matching
  column to the `games` landing table automatically on the connector's
  next change event for that table — no connector config edit, no
  restart, no manual DDL on the Snowflake side.
- **dbt models**: none, by design. Every `stg_steam__*` model lists its
  output columns explicitly (`select id as game_id, name, ...`), not
  `select *` in its final projection — only the intermediate `source`
  CTE uses `select *`, and that's scoped to the offset-dedupe `qualify`,
  not the model's output. An extra column arriving in the landing table
  is simply never selected, so `stg_steam__games`, `dim_games`, and every
  downstream model keep building, unchanged, with no code edit required.
  This is the mechanism by which "an additive upstream change needs no
  coordinated release" — nothing breaks, and nothing has to notice.
- **Published mart contracts** (steam-analytics): unaffected for the
  same reason — a contract only constrains a model's *declared* output
  columns, and `early_access` was never declared or selected by any mart.
  A contract only bites when someone tries to reshape a column a
  contract *does* declare (see the contract-violation demonstration in
  that repo's companion change for #144).

## Detection

- A human running `\d games` (or `select * from games limit 0`) against
  the source sees the new column immediately.
- `select column_name from STEAM_RAW.STEAM_RDS.information_schema.columns
  where table_name = 'GAMES';` on the Snowflake side, before vs. after,
  shows the new column appear with no connector change.
- Nothing fails: no dbt test, no contract, no connector health check
  fires, because nothing downstream was coordinated to expect or reject
  this column. That absence of alarm is itself the point being
  demonstrated — additive change is silent by design, in contrast to a
  breaking change against a *declared* contract column, which is loud by
  design (see the contract half of #144).

## Handling

Nothing needs to actively handle this fault — that's the scenario's
thesis. The source schema changed; the landing table absorbed it via
Snowflake's own schema evolution; every dbt model kept building because
none of them declare "the full set of columns on `games`" as part of
their contract, only the columns they actually select. If a future
ticket wants `early_access` surfaced in `dim_games`, that's an ordinary
code change (add it to the `stg`/`dim_games` select lists) — not a fix
for anything broken by this scenario.

## Why `db/schema.sql` does NOT get this column

`db/schema.sql` is the from-scratch bring-up script. It's applied in one
shot by `scripts/lib/schema_guard.py`'s `cmd_apply_schema`, gated by
`schema_applied()` (`schema_guard.py:39-42`), which checks only
`to_regclass('public.users') is not null` — the presence of `public.users`
stands in for "has this database already had `schema.sql` applied," since
`schema.sql` runs as one unsplittable `create table ...; create table
...;` script with no per-table idempotency (`schema_guard.py:9-11`).
Adding `early_access` to the `games` table in `schema.sql` would mean
every *fresh* bring-up starts with the column already present,
coordinated through source control like any other schema change — which
defeats the entire premise of this scenario. The fault being modelled is specifically an upstream change
*the warehouse never heard about*: one that lands via a live `alter
table` against a running database, not through a reviewed schema file.
If `schema.sql` also carried the column, a teardown + fresh bring-up
would silently absorb it as if it had always been there, and the
scenario's own reversal (`GAMES_ADD_COLUMN_REVERSE=true`) would leave a
bring-up in a state inconsistent with what source control says the
schema is — exactly the kind of drift a migration tool is supposed to
surface, not hide.

The consequence (deliberate): a scenario-applied column does not survive
a teardown and fresh bring-up. That's consistent with every other
scenario in this harness — `scripts/scenarios/` models one-shot
*operational* events against a live, already-running stack, not
permanent additions to the declared schema. A real additive migration
that a team actually wants to keep would, in practice, get its own PR
against `db/schema.sql` afterward; this scenario stops at proving the
live, uncoordinated case.
