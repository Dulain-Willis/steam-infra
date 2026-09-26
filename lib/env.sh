#!/usr/bin/env bash
# .env loading + fixed values + the tofu wrapper, shared by bring-up and
# teardown. Sourced by stage scripts — never run directly. Depends on
# lib/output.sh already being sourced (uses warn/note).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
ENV_FILE="$REPO_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

# .env.example's default is repo-relative (.secrets/snowflake_key.p8); every
# stage script is meant to be runnable standalone from any cwd, so resolve a
# relative path against REPO_ROOT rather than the caller's cwd.
if [[ -n "${SNOWFLAKE_PRIVATE_KEY_PATH:-}" && "$SNOWFLAKE_PRIVATE_KEY_PATH" != /* ]]; then
  SNOWFLAKE_PRIVATE_KEY_PATH="$REPO_ROOT/$SNOWFLAKE_PRIVATE_KEY_PATH"
fi
export SNOWFLAKE_PRIVATE_KEY_PATH

# Fixed values (#84 Implementation Decisions: not meant to be configurable
# per repo copy — AWS region, Snowflake database/role/warehouse/schema).
AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_CLUSTER_NAME="steam-infra"
RDS_INSTANCE_ID="steam-infra"
DB_NAME="steam"
DB_USER="steam_proj_admin"
REPLICATION_SLOT_NAME="debezium_steam"
SNOWFLAKE_DATABASE="STEAM_PROJECT"
SNOWFLAKE_SCHEMA="PUBLIC"
SNOWFLAKE_ROLE="ACCOUNTADMIN"
SNOWFLAKE_WAREHOUSE="COMPUTE_WH"
export AWS_REGION EKS_CLUSTER_NAME RDS_INSTANCE_ID DB_NAME DB_USER \
  REPLICATION_SLOT_NAME SNOWFLAKE_DATABASE SNOWFLAKE_SCHEMA SNOWFLAKE_ROLE \
  SNOWFLAKE_WAREHOUSE

tf() { tofu -chdir="$TF_DIR" "$@"; }

# Resources that survive a full teardown (the tfstate bucket has
# prevent_destroy = true). Shared by teardown Stage 5's destroy exclusions
# and bring-up Stage 1's leftover detection — both need "is anything left
# besides the bucket itself".
TFSTATE_RESOURCES=(
  aws_s3_bucket.tfstate
  aws_s3_bucket_versioning.tfstate
  aws_s3_bucket_server_side_encryption_configuration.tfstate
  aws_s3_bucket_public_access_block.tfstate
)

# tf_leftovers: prints tofu state entries beyond the tfstate bucket (empty if
# none). Requires `tf` (this file) and a prior `tf init`.
tf_leftovers() {
  tf state list 2>/dev/null | grep -v '^data\.' | grep -vFxf <(printf '%s\n' "${TFSTATE_RESOURCES[@]}") || true
}

# Values a person copying the repo must supply — see .env.example.
REQUIRED_ENV_VARS=(SNOWFLAKE_ACCOUNT SNOWFLAKE_USER SNOWFLAKE_PRIVATE_KEY_PATH AIRFLOW_ALERT_EMAIL)

# env_complete: reports every problem with .env, returns non-zero if any.
env_complete() {
  local missing=() var
  for var in "${REQUIRED_ENV_VARS[@]}"; do
    [[ -n "${!var:-}" ]] || missing+=("$var")
  done
  if (( ${#missing[@]} )); then
    warn "missing from .env: ${missing[*]}"
    note "copy .env.example to .env at the repo root and fill it in."
    return 1
  fi
  if [[ ! -f "$SNOWFLAKE_PRIVATE_KEY_PATH" ]]; then
    warn "SNOWFLAKE_PRIVATE_KEY_PATH does not exist: $SNOWFLAKE_PRIVATE_KEY_PATH"
    return 1
  fi
  return 0
}
