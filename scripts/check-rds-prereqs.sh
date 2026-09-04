#!/bin/bash
# Verify the RDS prerequisites the Debezium Postgres connector needs (#44,
# #31): logical replication turned on, and the connecting user granted
# rds_replication + SELECT on the captured tables. These are set up by
# terraform/rds.tf (rds.logical_replication param) and db/schema.sql
# (the rds_replication GRANT; SELECT comes from table ownership) — this
# only checks, it creates nothing.
# Run before applying k8s/kafka/debezium-connector.yaml so a missing
# prerequisite fails clearly here instead of showing up as an opaque
# connector-startup error.
set -euo pipefail

cd "$(dirname "$0")/../terraform"

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

echo "==> checking rds.logical_replication"
WAL_LEVEL=$($PSQL -c "show wal_level;")
if [ "$WAL_LEVEL" != "logical" ]; then
  echo "FAIL: wal_level=$WAL_LEVEL, expected logical — rds.logical_replication parameter group not applied/rebooted (#31)" >&2
  exit 1
fi
echo "OK: wal_level=logical"

echo "==> checking steam_proj_admin has rds_replication"
HAS_REPL=$($PSQL -c "select 1 from pg_roles r join pg_auth_members m on m.roleid = r.oid join pg_roles u on u.oid = m.member where r.rolname = 'rds_replication' and u.rolname = 'steam_proj_admin';")
if [ "$HAS_REPL" != "1" ]; then
  echo "FAIL: steam_proj_admin missing rds_replication role — run: GRANT rds_replication TO steam_proj_admin;" >&2
  exit 1
fi
echo "OK: steam_proj_admin has rds_replication"

echo "==> checking SELECT on captured tables"
MISSING=$($PSQL -c "
  select t.tablename from (values
    ('users'),('games'),('game_prices'),('purchases'),('ownership_grants'),
    ('gifts'),('key_redemptions'),('refunds'),('family_shares'),
    ('wishlist_items'),('playtime_sessions'),('reviews'),('price_changes'),
    ('concurrent_player_snapshots'),('marketing_campaigns')
  ) as t(tablename)
  where not has_table_privilege('steam_proj_admin', 'public.' || t.tablename, 'SELECT');
")
if [ -n "$MISSING" ]; then
  echo "FAIL: steam_proj_admin missing SELECT on: $MISSING" >&2
  exit 1
fi
echo "OK: steam_proj_admin has SELECT on all 15 tables"

echo "==> all prerequisites met"
