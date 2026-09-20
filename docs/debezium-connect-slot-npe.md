# Debezium connector stuck `Degraded`: Kafka Connect NPE on an existing replication slot

Incident: 2026-09-19/20, tracked in #75 across two agent sessions.

## Symptom

`debezium-postgres-source`'s ArgoCD Application reports `Degraded` (or the
`KafkaConnector` CR reports `NotReady`) even though the connector and task
are actually `RUNNING` underneath. Kafka Connect worker log shows:

```
java.lang.NullPointerException: Cannot invoke "ConfigValueInfo.errors()"
because the return value of "ConfigInfo.configValue()" is null
	at org.apache.kafka.connect.runtime.AbstractHerder.maybeAddConfigErrors(AbstractHerder.java:1077)
```

This is a Kafka Connect **framework** bug during connector config
validation — not a Debezium config problem. It throws on every `POST
/connectors` and `PUT /connectors/{name}/config` for the affected connector
name, so the CR can go permanently `NotReady`/`Degraded` and, if you delete
the CR to try to fix it, the connector won't come back at all (the create
itself 500s).

## What the first session (comments on #75) established

- The underlying connector/task were actually `RUNNING` the whole time —
  confirmed via `GET /connectors/{name}/status` on the Connect REST API
  directly. The `Degraded` status is cosmetic, driven by Strimzi's
  `KafkaConnector` CR reading that same broken validate response.
- Rolling Kafka Connect back a version (4.3.1 → 4.3.0) does **not** fix it.
  A fresh throwaway connector — same 16-table config, same transforms, same
  converter as the real one — creates and updates cleanly on both versions.
  Only the real `debezium-postgres-source` connector hits the NPE. This
  ruled out a Kafka Connect version regression.
- Untested theory left at the end of that session: delete and recreate
  `debezium-postgres-source` clean, accepting a full re-snapshot, since a
  fresh connector never hits the bug.

## What this session found

Blindly following that theory (delete the `KafkaConnector` CR) made things
**worse**, not better: the recreate hit the *same* NPE on `POST
/connectors`, so the connector didn't come back at all — a real outage,
not just a cosmetic status. ArgoCD's `selfHeal`+`automated` sync on the
`connectors` Application kept retrying the create every ~2 min and kept
failing the same way.

Root-caused by reading the Connect internal `connect-cluster-configs` topic
directly (`kafka-console-consumer.sh --topic connect-cluster-configs
--from-beginning --property print.key=true`). It showed the *previous*
session had already run this exact experiment (`diag-full-test`, identical
16-table config/transforms/converter to the real connector) under a
different `slot.name`/`publication.name` — and it created and committed
clean. **The connector name and config content are not the differentiator
— the specific `slot.name: debezium_steam` is.**

Queried Postgres directly from the bastion (`aws ssm send-command` +
`psql`, see below) and found `debezium_steam` sitting at `wal_status:
extended` (not `active`) — a state Postgres reports when a slot has fallen
behind and is being retained past its normal budget, left over from the
prior incident's repeated pause/resume/delete/recreate cycles. Working
theory: Debezium's `PostgresConnector.validate()` takes an extra
warning/advisory code path for a pre-existing slot in that state, and this
Kafka Connect version's framework code can't merge that extra output
without NPEing. A slot that doesn't exist yet (fresh name) skips that path
entirely, which is why every "fresh name" experiment always worked.

**This was not fully confirmed** — by the time a second recreate was tried
under the *original* name/slot (after temporarily renaming to `-v2` and
back), it succeeded with no NPE and no manual slot drop. `wal_status:
extended` appears to be transient (WAL retention pressure that eases with
time/checkpoints), not a permanent mark on the slot. So the NPE is real and
reproducible, but exactly which slot states trigger it, and whether it's
guaranteed to clear on its own, is still open.

## Fix applied

1. Renamed the connector + slot + publication to `debezium-postgres-source-v2` /
   `debezium_steam_v2` in `k8s/kafka/connectors/debezium-connector.yaml`,
   committed to `main` — ArgoCD (`connectors` app, auto-sync+selfHeal) picked
   it up and it came up `RUNNING` clean immediately.
2. Once that confirmed the connector itself was healthy, reverted the
   manifest back to the original `debezium-postgres-source` /
   `debezium_steam` and pushed again. ArgoCD pruned `-v2` and recreated the
   original — this time it also came up clean with no manual slot drop.
3. Net result: same connector name/slot as before the incident, no lasting
   rename, no data wiped. The unused `debezium_steam_v2` slot/publication
   was left behind on Postgres (harmless, inactive) — drop it if it bothers
   you (`SELECT pg_drop_replication_slot('debezium_steam_v2');` once
   `active = f`, then `DROP PUBLICATION debezium_steam_v2;`).

## If this happens again

1. **Check whether it's cosmetic first.** Hit the Connect REST API directly
   (`kubectl exec -n kafka steam-infra-connect-0 -- curl -s
   localhost:8083/connectors/<name>/status`) before touching anything. If
   the connector/task are `RUNNING`, the pipeline is fine — don't delete the
   CR "to fix the status," that's what caused the real outage this time.
2. **Don't delete-and-recreate under the same name as a first move.** If the
   connector is genuinely down (not cosmetic), check the real Kafka Connect
   worker log first (`kubectl logs -n kafka steam-infra-connect-0`, grep for
   `NullPointerException`/`AbstractHerder`) to confirm it's this same bug
   before acting.
3. **Rename to a scratch name to unstick it fast**, same pattern as this
   fix — new `metadata.name` + new `slot.name`/`publication.name` in
   `k8s/kafka/connectors/debezium-connector.yaml`, commit+push to `main`.
   `topic.prefix` can stay `steam` (topics are shared); only the slot/
   connector identity needs to change.
4. **Then try reverting back to the original name/slot** once the scratch
   connector is confirmed healthy — it may well just work now, per this
   session's experience, without needing to manually drop the old slot.
5. If the revert also NPEs, the slot itself needs dropping before Connect
   will accept that name again. Check its state first (needs bastion +
   RDS master creds from `tofu output -raw db_password`, since this sandbox
   blocks embedding DB passwords in commands — a human has to run this):
   ```sql
   select slot_name, active, active_pid, wal_status, restart_lsn, confirmed_flush_lsn
   from pg_replication_slots;
   ```
   If `active = f`, it's safe to drop
   (`SELECT pg_drop_replication_slot('debezium_steam');`) and let Connect
   recreate it fresh on the next reconcile.

## Gotcha this also re-triggers: stale Snowflake sink offsets

Every source recreate above does a full `snapshot.mode: always` re-snapshot
into the *same* topics (`topic.prefix: steam` never changed). The
Snowflake sink's Snowpipe Streaming channel offset tokens live in
Snowflake, not Kafka, and don't reset with the source — so the sink will
silently skip the re-snapshotted rows (`PartitionOffsetTracker: skipping
current record - expected offset X but received Y`) unless you also drop
the 16 `STEAM_PROJECT.PUBLIC.*` landing tables or redeploy `snowflake-sink`
under a new connector name. See the `snowflake-sink-stale-offsets` memory /
`CONTEXT.md` for the full mechanism. Not handled as part of this fix (out
of scope, tracked separately) — the tables currently still reflect
pre-incident offsets layered with however many of tonight's re-snapshots
landed before being skipped.
