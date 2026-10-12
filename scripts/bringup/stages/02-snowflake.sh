#!/usr/bin/env bash
# Stage 2: Snowflake. Applies terraform/snowflake — the root module that owns
# the pipeline's Snowflake objects, with its own state key in the same S3
# bucket as the AWS root (#113), so a Snowflake change can't block an AWS
# plan or the other way round.
#
# Runs before AWS because the Kafka Snowflake sink (Stage 5) starts writing
# as soon as it's deployed, and because it's the cheapest stage to fail in:
# no AWS resource exists yet when it does.
#
# `tofu apply` is idempotent, so there's no "already up" pre-check — but the
# verify step asks Snowflake itself rather than trusting the apply.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

stage 2 "Snowflake"

env_complete || fail ".env incomplete"

nstep 1 "applying terraform/snowflake..."
run_step "tofu init (snowflake)" tf_snowflake init -input=false
# --start-from 2 skips Stage 1's leftover detection by design, so this stage
# can be the first to meet a database that exists outside the module's state.
# The apply would fail with the provider's bare "already exists"; say what to
# do about it instead.
if [[ -z "$(sf_leftovers)" ]] && snowflake_database_exists; then
  fail "$SNOWFLAKE_DATABASE exists but terraform/snowflake's state is empty — import it (tofu -chdir=terraform/snowflake import snowflake_database.steam_project $SNOWFLAKE_DATABASE) and re-run, or drop it by hand"
fi
run_step "tofu apply (snowflake)" tf_snowflake apply -auto-approve -input=false

nstep 2 "verifying $SNOWFLAKE_DATABASE exists in Snowflake..."
if ! snowflake_database_exists; then
  fail "$SNOWFLAKE_DATABASE missing after tofu apply — check SHOW DATABASES and terraform/snowflake/databases.tf"
fi
ok "$SNOWFLAKE_DATABASE present"
