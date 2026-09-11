# Debezium Postgres connector config decisions

Decisions made resolving [#32](https://github.com/Dulain-Willis/steam-infra/issues/32), part of map [#27](https://github.com/Dulain-Willis/steam-infra/issues/27). Revisit this doc if the "fresh snapshot every session, no persisted state" design ([#27 decisions](https://github.com/Dulain-Willis/steam-infra/issues/27)) ever changes.

## Logical decoding plugin: `pgoutput`

Use `plugin.name: pgoutput` on the connector config. RDS Postgres only supports `pgoutput` — the alternative (`decoderbufs`) is a Debezium-maintained native extension that requires superuser/filesystem access RDS doesn't grant. `pgoutput` ships built into Postgres 10+, no extra install needed.

## RDS setup required before the connector can run

- Custom (non-default) DB parameter group with `rds.logical_replication = 1`. This is what turns on `wal_level=logical` on RDS — you can't set `wal_level` directly like on a self-hosted box. **Changing this requires an instance reboot.**
- Grant the connecting Postgres user replication access: `GRANT rds_replication TO <user>;` (RDS's substitute for the superuser-only `REPLICATION` privilege), plus normal `SELECT` on the captured tables.

## Snapshot mode: `always`

Set `snapshot.mode: always`. This project's design ([#27](https://github.com/Dulain-Willis/steam-infra/issues/27)) accepts losing Kafka/Debezium state every time the EKS cluster is torn down between sessions — there's no persisted offset to resume from. `always` makes Debezium re-snapshot the full table set every time it starts, matching that design instead of silently doing nothing under an incremental-resume mode with no prior offset.

**If this changes** (e.g. persistent storage gets added later so state survives teardown), this needs to move to `snapshot.mode: initial` and the slot-cleanup step below needs to stop running on every teardown, not just on a real decommission.

## Replication slot cleanup on teardown

Debezium creates a named replication slot on the RDS instance to track its read position, and does **not** delete it when the connector goes away. Because a fresh snapshot is taken every session, an old slot left behind after `tofu destroy` pins WAL on the RDS instance indefinitely — storage grows silently with nothing consuming it.

**Action required on every teardown**: explicitly drop the replication slot before/during `tofu destroy`, don't rely on Debezium's defaults. Run `scripts/teardown-replication-slot.sh` before `tofu destroy` (#48) — see `docs/kafka-connect-runbook.md`'s Teardown section.

## Flattened landing tables: ExtractNewRecordState + Snowflake schematization

Resolving `steam-analytics#28` (a sub-issue of `steam-analytics#9`, executed against this repo — see that issue for why: `steam-analytics#9`'s Staging phase needs typed columns to build `dbt` models on, not the raw two-VARIANT Debezium envelope this pipeline landed until now).

The Debezium source connector (`k8s/kafka/debezium-connector.yaml`) adds the `ExtractNewRecordState` (ENRS) single message transform:

- `transforms.unwrap.type=io.debezium.transforms.ExtractNewRecordState` unwraps `payload.after` to the top level of the message, discarding the envelope's `before`/`op`/`ts_ms` wrapper.
- `transforms.unwrap.add.fields=op,source.ts_ms,source.lsn,source.snapshot,source.table` re-adds those as flat `__op`, `__source_ts_ms`, `__source_lsn`, `__source_snapshot`, `__source_table` fields, since ENRS would otherwise drop them along with the envelope. (`source.txId` is deliberately left out — it's only useful for reconstructing cross-table transaction boundaries, which needs Debezium's transaction metadata topic too; not wired up here, so the column would sit unused.)
- `transforms.unwrap.delete.tombstone.handling.mode=rewrite` — a streaming delete has no `after` value, so plain ENRS emits a same-key null-value Kafka tombstone. `rewrite` instead emits a real row with `__deleted=true`, since a null value can't be schematized by the Snowflake sink.
- `transforms.unwrap.replace.null.with.default=false` — leave a column genuinely null when the source column is null, rather than substituting the connector's type default (e.g. `0` for a numeric column), which would be indistinguishable from a real zero downstream.

On dropping `before`: ENRS discards it entirely. This costs nothing here — all 16 tables use the default (not `FULL`) `REPLICA IDENTITY`, so `before` already carried only the primary key, nothing dbt could use for a proper diff. Revisiting `REPLICA IDENTITY FULL` for real before/after deletes is a separate enhancement, not part of this change.

Both connectors also set `value.converter.schemas.enable=true` (`value.converter: org.apache.kafka.connect.json.JsonConverter` — unchanged from before, just now schema-carrying). Schematization needs a Connect schema traveling with each message; the JSON converter carries it inline in the message rather than needing a separate Schema Registry service.

The Snowflake sink (`k8s/kafka/snowflake-connector.yaml`) sets `snowflake.enable.schematization=true`, so it evolves each landing table's columns to match the incoming schema instead of writing everything into two `RECORD_CONTENT`/`RECORD_METADATA` VARIANT columns. One typed column lands per source column (`uuid`/`text` → `VARCHAR`, `bigint` → `NUMBER`, `boolean` → `BOOLEAN`, `timestamptz` → `VARCHAR` since Debezium emits `ZonedTimestamp` as ISO-8601 text — downstream `dbt` casts it — `text[]` → `ARRAY`, `jsonb` → `VARCHAR`, parsed downstream with `PARSE_JSON`), plus the `__`-prefixed CDC metadata columns above. `RECORD_METADATA` (Kafka `offset`/`partition`/`topic`) is still written by the sink independently of schematization and stays available downstream for dedupe; `RECORD_CONTENT` goes away since there's no longer a single JSON blob to hold.

**Applying this to an existing environment**: schematization only evolves a table going forward — it does not retroactively reshape rows or columns already landed the old (unschematized) way. Drop the existing `STEAM_PROJECT.PUBLIC.*` landing tables before restarting the connectors so the sink recreates them schematized from scratch; combined with `snapshot.mode: always` (above), the next connector start re-snapshots all 16 source tables into the new shape.

**Cold-start gotcha (all 16 tables genuinely missing):** the sink's shared Snowpipe Streaming client checks pipe info for every `snowflake.topic2table.map`-mapped table while it's still bootstrapping, before its own per-table auto-create logic ever runs. If even one target table doesn't exist yet, that check throws (`SFException ... get_pipe_info ... ERR_TABLE_DOES_NOT_EXIST_NOT_AUTHORIZED`) and the task fails outright — despite Snowflake's own docs describing missing tables as auto-created (`snowflake.autocreate.table.type` defaults to `snowflake`, which should auto-create). This isn't documented anywhere we could find; it may be a real gap/quirk in the connector's multi-table shared-client bootstrap in this version (4.1.0).

If you hit this, pre-create the tables yourself, but do it with schema evolution turned on explicitly — a plain `CREATE TABLE <name> (RECORD_METADATA VARIANT)` is *not* equivalent to what the connector's own auto-create does:

```sql
CREATE TABLE IF NOT EXISTS <name> (RECORD_METADATA VARIANT) ENABLE_SCHEMA_EVOLUTION = TRUE;
```

Without `ENABLE_SCHEMA_EVOLUTION`, the connector doesn't error and doesn't add columns — it silently drops every field it can't match to an existing column, so rows land with `RECORD_METADATA` only and it looks exactly like schematization is disabled even though `snowflake.enable.schematization=true` is set. (This repo's own tables persist across `tofu destroy`/`tofu apply` — only Kafka gets torn down each session — so this cold-start case is one-time/rare, not something every session hits.)
