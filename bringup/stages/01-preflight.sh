#!/usr/bin/env bash
# Stage 1/2: preflight. Fails fast on a missing tool, broken AWS
# credentials, or an incomplete .env — before any bring-up work starts.
# Then detects leftovers from a previous session (tofu state holds
# resources beyond the tfstate bucket, or the Snowflake database exists)
# and runs a full teardown first, so every normal bring-up starts from a
# clean slate. Finally creates the Snowflake database.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/output.sh
source "$REPO_ROOT/lib/output.sh"
# shellcheck source=lib/env.sh
source "$REPO_ROOT/lib/env.sh"

stage 1 3 "Preflight"

missing=()
for bin in tofu aws kubectl uv jq psql session-manager-plugin; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if (( ${#missing[@]} )); then
  fail "missing required tools: ${missing[*]}"
fi
ok "required tools present: tofu, aws, kubectl, uv, jq, psql, session-manager-plugin"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  fail "AWS credentials not working (aws sts get-caller-identity failed) — configure your AWS profile/SSO session."
fi
ok "AWS credentials OK"

env_complete || fail ".env incomplete"
ok ".env complete, key file present"

nstep 1 "checking for leftovers from a previous session..."
run_step "tofu init" tf init -input=false
tf_leftover_resources=$(tf_leftovers)
snowflake_db_exists=false
if uv run "$REPO_ROOT/lib/snowflake_db.py" database-exists >/dev/null 2>&1; then
  snowflake_db_exists=true
fi

if [[ -z "$tf_leftover_resources" && "$snowflake_db_exists" == false ]]; then
  ok "no leftovers — starting from nothing"
else
  [[ -n "$tf_leftover_resources" ]] && warn "tofu state holds resources beyond the tfstate bucket"
  [[ "$snowflake_db_exists" == true ]] && warn "$SNOWFLAKE_DATABASE already exists in Snowflake"
  nsub "running teardown first..."
  bash "$REPO_ROOT/teardown/teardown.sh"
  ok "leftovers cleared"
fi

nstep 2 "creating Snowflake database $SNOWFLAKE_DATABASE..."
if uv run "$REPO_ROOT/lib/snowflake_db.py" database-exists >/dev/null 2>&1; then
  skip_note="$SNOWFLAKE_DATABASE already exists"
  ok "$skip_note"
else
  run_step "create database" uv run "$REPO_ROOT/lib/snowflake_db.py" create-database
fi

if ! uv run "$REPO_ROOT/lib/snowflake_db.py" database-exists >/dev/null 2>&1; then
  fail "$SNOWFLAKE_DATABASE still missing after create-database"
fi
ok "$SNOWFLAKE_DATABASE present"
