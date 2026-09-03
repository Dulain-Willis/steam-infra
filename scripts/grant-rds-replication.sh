#!/bin/bash
# One-off: apply `grant rds_replication to steam_proj_admin` to the running
# RDS instance through an SSM tunnel. schema.sql now carries this GRANT for
# fresh bootstraps; this script is for an already-bootstrapped DB that
# predates that line. Safe to re-run (GRANT is idempotent).
set -euo pipefail
cd "$(dirname "$0")/../terraform"

BID=$(tofu output -raw bastion_instance_id)
RDS=$(tofu output -raw rds_endpoint)
PW=$(tofu output -raw db_password)

TUNNEL_LOG=$(mktemp)
aws ssm start-session --target "$BID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$RDS\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15432\"]}" \
  >"$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!
trap 'kill "$TUNNEL_PID" 2>/dev/null || true; rm -f "$TUNNEL_LOG"' EXIT

for _ in $(seq 1 30); do
  (echo > /dev/tcp/localhost/15432) 2>/dev/null && break
  sleep 1
done

PGPASSWORD="$PW" psql -h localhost -p 15432 -U steam_proj_admin -d steam \
  -c 'grant rds_replication to steam_proj_admin;' \
  -c "select 1 as has_role from pg_roles r join pg_auth_members m on m.roleid=r.oid join pg_roles u on u.oid=m.member where r.rolname='rds_replication' and u.rolname='steam_proj_admin';"
