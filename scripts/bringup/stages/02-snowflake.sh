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
# verify steps ask Snowflake itself rather than trusting the apply, and the
# last one asks it as each pipeline identity in turn (#114): a role that can
# write where it shouldn't, or a key pair that doesn't authenticate, fails
# here rather than at DAG-run time.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/grant_check.sh
source "$REPO_ROOT/scripts/lib/grant_check.sh"

stage 2 "Snowflake"

env_complete || fail ".env incomplete"

# Grant isolation, one case per line: "IDENTITY ROLE TARGET EXPECT".
#
#   IDENTITY  the tofu output prefix to authenticate as (<id>_user,
#             <id>_private_key)
#   ROLE      the role to run as
#   TARGET    the database.schema the role tries to create a table in
#   EXPECT    allow — the write must succeed; deny — Snowflake must refuse it
#
# Both halves matter: a permitted write proving the identity works at all, and
# a forbidden write proving the boundary is enforced by grants rather than by
# convention. Add a pair of rows per role as later tickets add them — #115
# DEVELOPER, #116 CI, #119 TRANSFORMER_STAGING — and nothing else changes.
#
# One invariant to preserve when adding rows: **every deny target is also some
# other identity's allow target.** Snowflake answers "you have no USAGE on this
# database" and "this schema does not exist" with the same error, so a deny case
# aimed at a schema that silently stopped existing would pass while asserting
# nothing. The allow case on the same target is what proves the target is really
# there — e.g. dropping STEAM_PROD's PUBLIC schema would fail case 3 loudly
# rather than quietly turning case 2 into a no-op.
GRANT_CASES=(
  "loader       LOADER           $SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA allow"
  "loader       LOADER           $SNOWFLAKE_PROD_DATABASE.PUBLIC                  deny"
  "prod_airflow TRANSFORMER_PROD $SNOWFLAKE_PROD_DATABASE.PUBLIC                  allow"
  "prod_airflow TRANSFORMER_PROD $SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA deny"
)

nstep 1 "applying terraform/snowflake..."
run_step "tofu init (snowflake)" tf_snowflake init -input=false
# --start-from 2 skips Stage 1's leftover detection by design, so this stage
# can be the first to meet databases that exist outside the module's state.
# The apply would fail with the provider's bare "already exists"; say what to
# do about it instead.
if [[ -z "$(sf_leftovers)" ]]; then
  orphans=$(snowflake_databases_present) \
    || fail "could not query Snowflake for the project databases — see the error above"
  [[ -z "$orphans" ]] || fail "$orphans exist(s) but terraform/snowflake's state is empty — import them (tofu -chdir=terraform/snowflake import snowflake_database.raw $SNOWFLAKE_RAW_DATABASE) and re-run, or drop them by hand"
fi
run_step "tofu apply (snowflake)" tf_snowflake apply -auto-approve -input=false

nstep 2 "verifying the databases and the landing schema exist..."
for db in "${SNOWFLAKE_PROJECT_DATABASES[@]}"; do
  snowflake_database_exists "$db" \
    || fail "$db missing after tofu apply — check SHOW DATABASES and terraform/snowflake/databases.tf"
done
# The sink creates its tables but never the schema, so this one is
# load-bearing. The query's status is checked separately from its output: a
# failed query must not read as "the schema is there".
schema_rows=$(sf_query "SHOW SCHEMAS LIKE '$SNOWFLAKE_SOURCE_SCHEMA' IN DATABASE $SNOWFLAKE_RAW_DATABASE") \
  || fail "could not query Snowflake for $SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA — see the error above"
[[ -n "$schema_rows" ]] \
  || fail "$SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA missing after tofu apply — the Kafka sink cannot create it itself"
ok "${SNOWFLAKE_PROJECT_DATABASES[*]} present, $SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA present"

nstep 3 "checking grant isolation as each pipeline identity..."
trap grant_check_cleanup EXIT
grant_isolation_check "${GRANT_CASES[@]}"

nstep 4 "checking the raw handoff: LOADER writes it, TRANSFORMER_PROD reads it..."
# A read *denial* is not probed: LOADER has no USAGE on STEAM_PROD at all,
# which its write-deny case above already proves, and a read probe would fail
# for the same reason without telling us anything new.
grant_handoff_check loader LOADER prod_airflow TRANSFORMER_PROD \
  "$SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA"
