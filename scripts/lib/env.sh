#!/usr/bin/env bash
# .env loading + fixed values + the two tofu wrappers (one per root module)
# + the Snowflake query helpers, shared by bring-up and teardown. Sourced by
# stage scripts — never run directly. Depends on scripts/lib/output.sh
# already being sourced (uses warn/note).

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TF_DIR="$REPO_ROOT/terraform"
TF_SNOWFLAKE_DIR="$REPO_ROOT/terraform/snowflake"
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

# The Snowflake root module (own state, own key in the same bucket), so a
# Snowflake change can't block an AWS plan or the other way round.
tf_snowflake() { tofu -chdir="$TF_SNOWFLAKE_DIR" "$@"; }

# Inputs for terraform/snowflake. The v2 provider wants the account
# identifier split into organization_name + account_name; .env keeps the
# combined <ORG>-<ACCOUNT> SNOWFLAKE_ACCOUNT too, because the Python
# connector, the Kafka sink and dbt all want that form.
export TF_VAR_organization_name="${SNOWFLAKE_ORGANIZATION_NAME:-}"
export TF_VAR_account_name="${SNOWFLAKE_ACCOUNT_NAME:-}"
export TF_VAR_user="${SNOWFLAKE_USER:-}"
export TF_VAR_private_key_path="${SNOWFLAKE_PRIVATE_KEY_PATH:-}"

# sf_query "SQL" [--role R] — one statement, rows on stdout (tab-separated),
# non-zero exit if Snowflake rejects it. The only Snowflake access path left
# in the scripts; creating and dropping is terraform/snowflake's job.
sf_query() { uv run "$REPO_ROOT/scripts/lib/snowflake_query.py" "$@"; }

# snowflake_database_exists [NAME] — asks Snowflake, rather than trusting a
# tofu apply or destroy. Used by bring-up's and teardown's verify steps.
snowflake_database_exists() {
  local name="${1:-$SNOWFLAKE_DATABASE}"
  [[ -n "$(sf_query "SHOW DATABASES LIKE '$name'")" ]]
}

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

# sf_leftovers: same idea for the Snowflake root module. Nothing in it
# survives a teardown, so anything at all in state is a leftover. Requires a
# prior `tf_snowflake init`.
sf_leftovers() {
  tf_snowflake state list 2>/dev/null | grep -v '^data\.' || true
}

# Values a person copying the repo must supply — see .env.example.
REQUIRED_ENV_VARS=(
  SNOWFLAKE_ACCOUNT
  SNOWFLAKE_ORGANIZATION_NAME
  SNOWFLAKE_ACCOUNT_NAME
  SNOWFLAKE_USER
  SNOWFLAKE_PRIVATE_KEY_PATH
  AIRFLOW_ALERT_EMAIL
)

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
  # The split form (tofu) and the combined form (Python connector, Kafka
  # sink, dbt) must name the same account, or tofu and the verify step would
  # silently talk to two different Snowflake accounts.
  if [[ "$SNOWFLAKE_ACCOUNT" != "$SNOWFLAKE_ORGANIZATION_NAME-$SNOWFLAKE_ACCOUNT_NAME" ]]; then
    warn "SNOWFLAKE_ACCOUNT ($SNOWFLAKE_ACCOUNT) is not SNOWFLAKE_ORGANIZATION_NAME-SNOWFLAKE_ACCOUNT_NAME ($SNOWFLAKE_ORGANIZATION_NAME-$SNOWFLAKE_ACCOUNT_NAME)"
    return 1
  fi
  return 0
}
