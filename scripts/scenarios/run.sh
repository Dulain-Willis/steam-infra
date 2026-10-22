#!/usr/bin/env bash
# Entrypoint for one-shot operational-fault scenarios (#131). Opens the
# same SSM tunnel to RDS that scripts/bringup/stages/04-database.sh uses
# (scripts/lib/tunnel.sh) -- the one connection mechanism the repo already
# has -- then runs the named scenario module's cursor-taking run(cur)
# against it. Each scenario's own fault logic lives in scenarios/<name>.py
# and is callable directly, without a live database, for unit tests.
#
# Usage: scripts/scenarios/run.sh <scenario_module>
# e.g.:  scripts/scenarios/run.sh noop_report
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/tunnel.sh
source "$REPO_ROOT/scripts/lib/tunnel.sh"
trap tunnel_cleanup EXIT

SCENARIO="${1:?usage: run.sh <scenario_module>}"

BASTION_ID=$(tf output -raw bastion_instance_id 2>/dev/null || true)
RDS_HOST=$(tf output -raw rds_endpoint 2>/dev/null || true)
DB_PASSWORD=$(tf output -raw db_password 2>/dev/null || true)
[[ -n "$BASTION_ID" && -n "$RDS_HOST" && -n "$DB_PASSWORD" ]] \
  || fail "missing bastion/rds outputs — did Stage 3 (AWS) run?"

note "scenario: $SCENARIO"

nstep 1 "opening SSM tunnel to RDS through the bastion..."
open_rds_tunnel "$BASTION_ID" "$RDS_HOST" || fail "tunnel never came up"

export DB_HOST=127.0.0.1 DB_PORT=15432 DB_PASSWORD

nstep 2 "running scenario..."
uv run --with-requirements "$REPO_ROOT/generator/requirements.txt" \
  "$REPO_ROOT/scenarios/_run.py" "$SCENARIO"

close_rds_tunnel
