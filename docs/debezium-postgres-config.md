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

**Action required on every teardown**: explicitly drop the replication slot before/during `tofu destroy`, don't rely on Debezium's defaults. This should get wired into whatever teardown process resolves the pipeline's build spec later — flagging here so it isn't lost between "we decided this" and "someone wires it into a script."
