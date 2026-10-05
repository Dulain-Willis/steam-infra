#!/usr/bin/env bash
# Stage 5/5: generator + end-to-end smoke test. `tofu apply` including the
# generator (held back from Stage 2 until the database is seeded) -> verify
# the instance is running and RDS row counts actually grow -> run the
# RDS -> Debezium -> Kafka -> Snowflake smoke test. No dbt/Airflow DAG
# trigger (#84 Out of Scope).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/output.sh
source "$REPO_ROOT/lib/output.sh"
# shellcheck source=lib/env.sh
source "$REPO_ROOT/lib/env.sh"
# shellcheck source=lib/tunnel.sh
source "$REPO_ROOT/lib/tunnel.sh"
trap tunnel_cleanup EXIT

stage 5 5 "Generator"

# Event tables the generator writes to on a tick (docs/generator-runbook.md's
# throughput query) - summed as one row-count proxy for "is it ticking".
EVENT_TABLES=(
  purchases gifts key_redemptions refunds price_changes
  concurrent_player_snapshots playtime_sessions family_shares
  wishlist_items reviews
)

nstep 1 "applying AWS infra (including the generator)..."
run_step "tofu apply" tf apply -auto-approve

INSTANCE_ID=$(tf output -raw generator_instance_id)

nstep 2 "verifying generator instance is running..."
run_step "wait for instance running" aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"
ok "generator instance running"

# "Running" is just the EC2 state -- user_data still has to install docker and
# build the image on first boot (docs/generator-runbook.md: "allow a minute
# or two"). Poll the container itself over SSM rather than guessing a sleep,
# so the row-growth check below never races the build.
ssm_run() {
  local command_id status
  command_id=$(aws ssm send-command --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript --parameters "commands=[\"$1\"]" \
    --query 'Command.CommandId' --output text 2>/dev/null) || return 1
  for _ in $(seq 1 30); do
    status=$(aws ssm get-command-invocation --command-id "$command_id" \
      --instance-id "$INSTANCE_ID" --query Status --output text 2>/dev/null) || true
    case "$status" in
      Success) aws ssm get-command-invocation --command-id "$command_id" \
          --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text; return 0 ;;
      Failed | Cancelled | TimedOut) return 1 ;;
    esac
    sleep 1
  done
  return 1
}
generator_ticking() {
  [[ "$(ssm_run "docker inspect -f '{{.State.Running}}' steam-generator 2>/dev/null")" == "true" ]]
}

nstep 3 "waiting for the generator container (first boot builds the image)..."
deadline=$((SECONDS + 300))
until generator_ticking; do
  (( SECONDS < deadline )) \
    || fail "generator container never started — check: aws ssm start-session --target $INSTANCE_ID, then docker logs steam-generator"
  sleep 10
done
ok "generator container running"

BASTION_ID=$(tf output -raw bastion_instance_id 2>/dev/null || true)
RDS_HOST=$(tf output -raw rds_endpoint 2>/dev/null || true)
DB_PASSWORD=$(tf output -raw db_password 2>/dev/null || true)
[[ -n "$BASTION_ID" && -n "$RDS_HOST" && -n "$DB_PASSWORD" ]] \
  || fail "missing bastion/rds outputs — did Stage 2 (AWS) run?"

nstep 4 "opening SSM tunnel to RDS through the bastion..."
open_rds_tunnel "$BASTION_ID" "$RDS_HOST" || fail "tunnel never came up"

export PGPASSWORD="$DB_PASSWORD"
PSQL=(psql -h 127.0.0.1 -p 15432 -U "$DB_USER" -d "$DB_NAME" -tA)

row_count_sql="select $(printf '(select count(*) from %s) + ' "${EVENT_TABLES[@]}" | sed 's/ + $//');"
row_count() { "${PSQL[@]}" -c "$row_count_sql"; }

nstep 5 "verifying RDS row counts are growing..."
before=$(row_count)
nsub "event-table rows: $before, waiting 30s..."
sleep 30
after=$(row_count)
(( after > before )) \
  || fail "event-table rows did not grow over 30s ($before -> $after) — check: aws ssm start-session --target $INSTANCE_ID, then docker logs -f steam-generator"
ok "event-table rows grew: $before -> $after"

nstep 6 "running end-to-end smoke test (RDS write -> Snowflake)..."
DB_HOST=127.0.0.1 DB_PORT=15432 DB_PASSWORD="$DB_PASSWORD" \
  SNOWFLAKE_KEY_FILE="$SNOWFLAKE_PRIVATE_KEY_PATH" \
  run_step "smoke test" uv run --with-requirements "$REPO_ROOT/scripts/requirements-smoke-test.txt" "$REPO_ROOT/scripts/smoke-test.py"

close_rds_tunnel
