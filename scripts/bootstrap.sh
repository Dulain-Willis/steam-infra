#!/bin/bash
# Bring the steam-infra environment up from a clean `tofu destroy` state:
# RDS + bastion, schema, seed data, then the generator — in that order, so
# the generator never boots against an empty database (see docs/generator-runbook.md).
set -euo pipefail

cd "$(dirname "$0")/../terraform"

TUNNEL_LOG=$(mktemp)          # SSM tunnel's stdout/stderr, polled below for readiness
VENV=/tmp/steam-infra-venv    # local venv to run schema/seed against the tunnel (not on EC2)
TUNNEL_PID=""                 # set once the tunnel is backgrounded; empty means "nothing to kill"

# Always kill the tunnel on exit (success, error, or Ctrl-C) so it never
# leaks a background `aws ssm` process after the script ends.
cleanup() {
  if [ -n "$TUNNEL_PID" ]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
  fi
  rm -f "$TUNNEL_LOG"
}
trap cleanup EXIT

echo "==> tofu init"
tofu init -input=false

# Phase 1: everything except the generator. `-target=aws_instance.bastion
# -target=aws_db_instance.main` looked equivalent but isn't: -target only
# pulls in resources those two *depend on* via a referenced attribute, and
# silently drops siblings nothing points at by ARN/ID — bit twice by this
# (aws_iam_role_policy_attachment.bastion_ssm, then aws_internet_gateway.gw
# + its route table) before switching to -exclude, which applies
# everything in the config *except* the generator instead of walking a
# dependency subset that keeps turning out incomplete.
echo "==> phase 1: RDS + bastion (generator held back until seed data exists)"
tofu apply -auto-approve -exclude=aws_instance.generator

BASTION_ID=$(tofu output -raw bastion_instance_id)
RDS_HOST=$(tofu output -raw rds_endpoint)
DB_PASSWORD=$(tofu output -raw db_password)

# EC2 "running" only means the instance booted, not that the SSM agent has
# registered with the service yet — that registration lags boot by up to a
# couple minutes on a fresh instance. Starting a session before it's
# "Online" fails with TargetNotConnected, so poll for it explicitly instead
# of racing it.
echo "==> waiting for bastion SSM agent to register"
for _ in $(seq 1 40); do
  PING_STATUS=$(aws ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$BASTION_ID" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
  [ "$PING_STATUS" = "Online" ] && break
  sleep 5
done
if [ "$PING_STATUS" != "Online" ]; then
  echo "bastion SSM agent never came online" >&2
  exit 1
fi

# RDS has no public IP; the bastion is the only thing inside the VPC we
# can reach over SSM, so this forwards localhost:15432 -> RDS:5432 through it.
echo "==> opening SSM tunnel to RDS"
aws ssm start-session --target "$BASTION_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$RDS_HOST\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15432\"]}" \
  >"$TUNNEL_LOG" 2>&1 &
TUNNEL_PID=$!

# The SSM CLI prints this line once the local listener is actually ready;
# polling the log (rather than just sleeping a fixed amount) is what makes
# this reliable instead of flaky.
echo "==> waiting for tunnel"
for _ in $(seq 1 30); do
  grep -q "Waiting for connections" "$TUNNEL_LOG" && break
  sleep 1
done
grep -q "Waiting for connections" "$TUNNEL_LOG" || {
  echo "tunnel never came up:" >&2
  cat "$TUNNEL_LOG" >&2
  exit 1
}

# schema.sql/seed.py run from this machine (through the tunnel), not on
# the bastion or an EC2 box, so they need psycopg2/Faker available locally.
echo "==> local venv for schema/seed (psycopg2 + Faker)"
if [ ! -d "$VENV" ]; then
  python3 -m venv "$VENV"
fi
"$VENV/bin/pip" install -q -r ../generator/requirements.txt

# Same DB_* env vars the generator container and seed.py already read —
# pointed at the local tunnel endpoint instead of the in-VPC RDS address.
export DB_HOST=localhost
export DB_PORT=15432
export DB_NAME=steam
export DB_USER=steam_proj_admin
export DB_PASSWORD

# db/schema.sql is plain DDL (no psql meta-commands), so psycopg2 can run
# the whole file in one execute() without needing the psql binary installed.
echo "==> applying schema"
"$VENV/bin/python" -c '
import os, psycopg2
conn = psycopg2.connect(
    host=os.environ["DB_HOST"], port=os.environ["DB_PORT"],
    dbname=os.environ["DB_NAME"], user=os.environ["DB_USER"],
    password=os.environ["DB_PASSWORD"],
)
with conn, conn.cursor() as cur:
    cur.execute(open("../db/schema.sql").read())
conn.close()
print("schema applied")
'

# Populates users/games/game_prices. Must happen before the generator boots —
# purchase/gift/etc ticks select a random existing user+game and crash-loop
# on an empty table otherwise.
echo "==> seeding data"
"$VENV/bin/python" ../generator/seed.py

# Done with the tunnel — close it explicitly (not just relying on the exit
# trap) so it's not still open in the background during phase 2.
echo "==> closing tunnel"
kill "$TUNNEL_PID" 2>/dev/null || true
TUNNEL_PID=""

# Phase 2: full apply now creates aws_instance.generator. Its user_data
# builds+starts the Docker container on first boot, and by this point
# users/games/game_prices are already populated, so the very first tick
# has real rows to pick from instead of crashing on an empty table.
echo "==> phase 2: generator (only now that seed data exists)"
tofu apply -auto-approve

echo "==> done"
tofu output
