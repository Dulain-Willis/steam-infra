#!/usr/bin/env bash
# Stage 3/6: drop Debezium's replication slot. Safety net only — RDS is
# destroyed with skip_final_snapshot in Stage 5, so the slot dies with it;
# this only matters if the destroy dies partway and RDS survives, in which
# case an orphaned slot pins WAL on the instance indefinitely.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/output.sh
source "$REPO_ROOT/lib/output.sh"
# shellcheck source=lib/env.sh
source "$REPO_ROOT/lib/env.sh"
# shellcheck source=lib/tunnel.sh
source "$REPO_ROOT/lib/tunnel.sh"
trap tunnel_cleanup EXIT

stage 3 6 "Replication slot"

nstep 1 "checking whether RDS still exists..."
if ! aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" >/dev/null 2>&1; then
  skip "no RDS instance '$RDS_INSTANCE_ID' — nothing to drop"
fi

BASTION_ID=$(tf output -raw bastion_instance_id 2>/dev/null || true)
RDS_HOST=$(tf output -raw rds_endpoint 2>/dev/null || true)
DB_PASSWORD=$(tf output -raw db_password 2>/dev/null || true)
if [[ -z "$BASTION_ID" || -z "$RDS_HOST" || -z "$DB_PASSWORD" ]]; then
  skip "RDS exists but the bastion/outputs are gone — can't reach it, nothing to do"
fi

nstep 2 "opening SSM tunnel to RDS through the bastion..."
open_rds_tunnel "$BASTION_ID" "$RDS_HOST" || fail "tunnel never came up"

export PGPASSWORD="$DB_PASSWORD"
PSQL=(psql -h 127.0.0.1 -p 15432 -U "$DB_USER" -d "$DB_NAME" -tA)

nstep 3 "checking for replication slot: $REPLICATION_SLOT_NAME"
# A storage-full instance (exactly the failure mode an orphaned slot causes,
# by pinning WAL until disk fills) can refuse or drop every connection before
# the query even runs. Genuinely unattended here means not hanging or hard-
# failing the whole teardown on that: Stage 5 destroys RDS outright regardless
# of slot state, so this stage's only job (the safety net) is moot anyway —
# warn clearly and move on rather than block $0 on an instance already headed
# for deletion.
psql_err=$(mktemp)
if ! exists=$("${PSQL[@]}" -c "select 1 from pg_replication_slots where slot_name = '$REPLICATION_SLOT_NAME';" 2>"$psql_err"); then
  close_rds_tunnel
  warn "could not query RDS — it may be storage-full (check: aws rds describe-db-instances --db-instance-identifier $RDS_INSTANCE_ID):"
  cat "$psql_err" >&2
  rm -f "$psql_err"
  warn "continuing — Stage 5's tofu destroy removes RDS regardless of slot state"
  exit 0
fi
rm -f "$psql_err"
if [[ "$exists" != "1" ]]; then
  close_rds_tunnel
  skip "no $REPLICATION_SLOT_NAME slot present"
fi

# The Debezium connector is usually still connected at this point (this runs
# before Stage 5's destroy, not after), which leaves the slot "active" —
# pg_drop_replication_slot refuses to drop an active slot. Kill the walsender
# backend holding it first so the drop always succeeds.
active_pid=$("${PSQL[@]}" -c "select active_pid from pg_replication_slots where slot_name = '$REPLICATION_SLOT_NAME' and active;")
if [[ -n "$active_pid" ]]; then
  nsub "slot is active (pid $active_pid), terminating backend"
  "${PSQL[@]}" -c "select pg_terminate_backend($active_pid);" >/dev/null
fi

nstep 4 "dropping replication slot..."
"${PSQL[@]}" -c "select pg_drop_replication_slot('$REPLICATION_SLOT_NAME');" >/dev/null

remaining=$("${PSQL[@]}" -c "select 1 from pg_replication_slots where slot_name = '$REPLICATION_SLOT_NAME';")
close_rds_tunnel
[[ "$remaining" != "1" ]] || fail "$REPLICATION_SLOT_NAME still present after drop"
ok "$REPLICATION_SLOT_NAME dropped"
