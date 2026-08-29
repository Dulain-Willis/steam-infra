#!/bin/bash
# Drop the Debezium replication slot on RDS before/during `tofu destroy`
# (#48, per docs/debezium-postgres-config.md). snapshot.mode: always means
# nothing ever resumes from this slot, so an orphaned slot left behind
# after teardown pins WAL on the RDS instance indefinitely. Run this before
# `tofu destroy` every session — safe/no-op if the slot doesn't exist.
set -euo pipefail

cd "$(dirname "$0")/../terraform"

SLOT_NAME="debezium_steam"

TUNNEL_LOG=$(mktemp)
TUNNEL_PID=""
cleanup() {
  [ -n "$TUNNEL_PID" ] && kill "$TUNNEL_PID" 2>/dev/null || true
  rm -f "$TUNNEL_LOG"
}
trap cleanup EXIT

BASTION_ID=$(tofu output -raw bastion_instance_id)
RDS_HOST=$(tofu output -raw rds_endpoint)
DB_PASSWORD=$(tofu output -raw db_password)

echo "==> opening SSM tunnel to RDS"
aws ssm start-session --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$RDS_HOST\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15432\"]}" \
  >"$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!

for _ in $(seq 1 30); do
  (exec 3<>/dev/tcp/localhost/15432) 2>/dev/null && exec 3<&- 3>&- && break
  sleep 1
done
(exec 3<>/dev/tcp/localhost/15432) 2>/dev/null && exec 3<&- 3>&- || {
  echo "tunnel never came up:" >&2
  cat "$TUNNEL_LOG" >&2
  exit 1
}

export PGPASSWORD="$DB_PASSWORD"
PSQL="psql -h localhost -p 15432 -U steam_proj_admin -d steam -tA"

echo "==> checking for replication slot: $SLOT_NAME"
EXISTS=$($PSQL -c "select 1 from pg_replication_slots where slot_name = '$SLOT_NAME';")
if [ "$EXISTS" != "1" ]; then
  echo "OK: no $SLOT_NAME slot present, nothing to drop"
  exit 0
fi

echo "==> dropping replication slot: $SLOT_NAME"
$PSQL -c "select pg_drop_replication_slot('$SLOT_NAME');" >/dev/null

REMAINING=$($PSQL -c "select 1 from pg_replication_slots where slot_name = '$SLOT_NAME';")
if [ "$REMAINING" = "1" ]; then
  echo "FAIL: $SLOT_NAME still present in pg_replication_slots after drop" >&2
  exit 1
fi
echo "OK: $SLOT_NAME dropped"
