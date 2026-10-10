#!/usr/bin/env bash
# Stage 3/6: database. One SSM tunnel to RDS (shared scripts/lib/tunnel.sh) →
# apply db/schema.sql only if absent (schema.sql uses bare `create table`,
# so re-applying it against an existing schema fails outright — the guard
# lives in scripts/lib/schema_guard.py) → seed only if empty → verify the Debezium
# prerequisites (logical replication, rds_replication grant, SELECT on every
# captured table) — the source of truth for those checks (#90 deleted the
# old scripts/check-rds-prereqs.sh this replaced).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/tunnel.sh
source "$REPO_ROOT/scripts/lib/tunnel.sh"
trap tunnel_cleanup EXIT

stage 3 6 "Database"

CAPTURED_TABLES=(
  users games game_prices marketing_campaigns purchases ownership_grants
  gifts key_redemptions refunds family_shares wishlist_items
  playtime_sessions reviews price_changes concurrent_player_snapshots
  client_events
)

BASTION_ID=$(tf output -raw bastion_instance_id 2>/dev/null || true)
RDS_HOST=$(tf output -raw rds_endpoint 2>/dev/null || true)
DB_PASSWORD=$(tf output -raw db_password 2>/dev/null || true)
[[ -n "$BASTION_ID" && -n "$RDS_HOST" && -n "$DB_PASSWORD" ]] \
  || fail "missing bastion/rds outputs — did Stage 2 (AWS) run?"

nstep 1 "opening SSM tunnel to RDS through the bastion..."
open_rds_tunnel "$BASTION_ID" "$RDS_HOST" || fail "tunnel never came up"

export DB_HOST=127.0.0.1 DB_PORT=15432 DB_PASSWORD
export PGPASSWORD="$DB_PASSWORD"
PSQL=(psql -h 127.0.0.1 -p 15432 -U "$DB_USER" -d "$DB_NAME" -tA)

nstep 2 "applying schema..."
if uv run "$REPO_ROOT/scripts/lib/schema_guard.py" schema-applied >/dev/null 2>&1; then
  ok "schema already applied"
else
  run_step "apply schema" uv run "$REPO_ROOT/scripts/lib/schema_guard.py" apply-schema
fi

nstep 3 "seeding..."
user_count=$("${PSQL[@]}" -c "select count(*) from users;")
if [[ "$user_count" != "0" ]]; then
  ok "users already seeded ($user_count rows)"
else
  run_step "seed database" uv run --with-requirements "$REPO_ROOT/generator/requirements.txt" "$REPO_ROOT/generator/seed.py"
fi

nstep 4 "verifying Debezium prerequisites..."
wal_level=$("${PSQL[@]}" -c "show wal_level;")
[[ "$wal_level" == "logical" ]] \
  || fail "wal_level=$wal_level, expected logical — rds.logical_replication parameter group not applied"
ok "wal_level=logical"

has_repl=$("${PSQL[@]}" -c "select 1 from pg_roles r join pg_auth_members m on m.roleid = r.oid join pg_roles u on u.oid = m.member where r.rolname = 'rds_replication' and u.rolname = '$DB_USER';")
[[ "$has_repl" == "1" ]] \
  || fail "$DB_USER missing rds_replication role — schema.sql should have granted it"
ok "$DB_USER has rds_replication"

missing=$("${PSQL[@]}" -c "
  select t.tablename from (values $(printf "('%s')," "${CAPTURED_TABLES[@]}" | sed 's/,$//')) as t(tablename)
  where not has_table_privilege('$DB_USER', 'public.' || t.tablename, 'SELECT');
")
[[ -z "$missing" ]] || fail "$DB_USER missing SELECT on: $missing"
ok "$DB_USER has SELECT on all ${#CAPTURED_TABLES[@]} captured tables"

close_rds_tunnel
