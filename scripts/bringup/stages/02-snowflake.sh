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
# convention. Add a pair of rows per role as later tickets add them, and
# nothing else changes: grant_isolation_check reads the table, so the number of
# identities in it is not baked into anything.
#
# The `developer` identity is the operator's STEAM_DEV_<NAME> user; its key is
# the operator's own from .env rather than a tofu output, because
# terraform/snowflake registers their existing public key on it and so never
# holds the private half (grant_check_local_key, below).
#
# One invariant to preserve when adding rows: **every deny target is also some
# other identity's allow target.** Snowflake answers "you have no USAGE on this
# database" and "this schema does not exist" with the same error, so a deny case
# aimed at a schema that silently stopped existing would pass while asserting
# nothing. The allow case on the same target is what proves the target is really
# there — e.g. dropping STEAM_PROD's PUBLIC schema would fail TRANSFORMER_PROD's
# allow row loudly rather than quietly turning everyone else's deny row on it
# into a no-op.
#
# The two transformers are each other's mirror: every build database is one
# identity's allow target and the other identities' deny target, so "staging
# cannot damage prod" and "prod is not reachable from dev" are both read off
# the same table.
GRANT_CASES=(
  "loader          LOADER              $SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA allow"
  "loader          LOADER              $SNOWFLAKE_PROD_DATABASE.PUBLIC                  deny"
  "staging_airflow TRANSFORMER_STAGING $SNOWFLAKE_STAGING_DATABASE.PUBLIC               allow"
  "staging_airflow TRANSFORMER_STAGING $SNOWFLAKE_PROD_DATABASE.PUBLIC                  deny"
  "staging_airflow TRANSFORMER_STAGING $SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA deny"
  "prod_airflow    TRANSFORMER_PROD    $SNOWFLAKE_PROD_DATABASE.PUBLIC                  allow"
  "prod_airflow    TRANSFORMER_PROD    $SNOWFLAKE_STAGING_DATABASE.PUBLIC               deny"
  "prod_airflow    TRANSFORMER_PROD    $SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA deny"
  "developer       DEVELOPER           $SNOWFLAKE_DEV_DATABASE.PUBLIC                   allow"
  "developer       DEVELOPER           $SNOWFLAKE_STAGING_DATABASE.PUBLIC               deny"
  "developer       DEVELOPER           $SNOWFLAKE_PROD_DATABASE.PUBLIC                  deny"
  "developer       DEVELOPER           $SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA deny"
  "ci              CI                  $SNOWFLAKE_DEV_DATABASE.PUBLIC                   allow"
  "ci              CI                  $SNOWFLAKE_STAGING_DATABASE.PUBLIC               deny"
  "ci              CI                  $SNOWFLAKE_PROD_DATABASE.PUBLIC                  deny"
  "ci              CI                  $SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA deny"
)
# CI's prod row is a *write* deny even though CI is the one identity that must
# read STEAM_PROD (#112's Q1 — slim-CI deferral resolves unselected refs to
# prod's relations). The table only ever probes writes, so the two are not in
# tension: the deny row above and the handoff check in step 4 assert opposite
# halves of the same grant set, and dropping either would leave one unproven.

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
grant_check_local_key developer "$(sf_output operator_developer_user)" \
  "$SNOWFLAKE_PRIVATE_KEY_PATH"
grant_isolation_check "${GRANT_CASES[@]}"

nstep 4 "checking the raw handoff: LOADER writes it, the readers read it..."
# A read *denial* is not probed: LOADER has no USAGE on STEAM_PROD at all,
# which its write-deny case above already proves, and a read probe would fail
# for the same reason without telling us anything new.
#
# DEVELOPER's read is checked the same way as prod's, and for the same reason:
# every dev build's stg layer selects from the landing tables, and the case
# table above only probes writes — where DEVELOPER on the raw database must be
# denied.
grant_handoff_check loader LOADER staging_airflow TRANSFORMER_STAGING \
  "$SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA"
grant_handoff_check loader LOADER prod_airflow TRANSFORMER_PROD \
  "$SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA"
grant_handoff_check loader LOADER developer DEVELOPER \
  "$SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA"
# CI reads the landing tables too: only *unselected* refs defer in a slim
# build, and a source is never a ref, so every CI build's stg layer still
# selects from here.
grant_handoff_check loader LOADER ci CI \
  "$SNOWFLAKE_RAW_DATABASE.$SNOWFLAKE_SOURCE_SCHEMA"
# The other handoff, and the only one that is not about the raw database:
# TRANSFORMER_PROD writes STEAM_PROD, CI reads it. This is the grant slim-CI
# deferral stands on, and nothing else in this stage can see it — CI's prod row
# in the table above is a write deny, which passes whether or not the read
# exists. Without this check, "CI can defer to prod state" is unproven until
# the first slim CI run after a cold bring-up.
#
# TABLE *and* VIEW: deferral resolves to whichever layer an unselected model
# lives in, and the stg and int layers are views while the marts are tables.
# SELECT on views is a separate grant, so a tables-only probe would pass with
# the views half missing and slim CI would then fail on anything upstream of a
# mart — read as a dbt bug, not a grant.
grant_handoff_check prod_airflow TRANSFORMER_PROD ci CI \
  "$SNOWFLAKE_PROD_DATABASE.PUBLIC" TABLE VIEW

nstep 5 "checking the roles with no grant at all cannot even read..."
# identities.tf claims five times that a role has *no grant of any kind* on a
# database, and until now nothing checked it: GRANT_CASES only issues writes,
# so a stray SELECT or USAGE grant on one of those databases is invisible to
# every other check in this stage. These are the claims, one line each.
#
# CI is why this exists — it is the first identity that reads a build database
# it must not write, so "CI reads prod" and "CI cannot touch staging" sit one
# token apart in near-identical grant blocks — but the same hole covered
# DEVELOPER and the two transformers, so all four are asserted.
grant_read_deny_check staging_airflow TRANSFORMER_STAGING ci CI \
  "$SNOWFLAKE_STAGING_DATABASE.PUBLIC"
grant_read_deny_check prod_airflow TRANSFORMER_PROD developer DEVELOPER \
  "$SNOWFLAKE_PROD_DATABASE.PUBLIC"
grant_read_deny_check staging_airflow TRANSFORMER_STAGING developer DEVELOPER \
  "$SNOWFLAKE_STAGING_DATABASE.PUBLIC"
grant_read_deny_check prod_airflow TRANSFORMER_PROD staging_airflow TRANSFORMER_STAGING \
  "$SNOWFLAKE_PROD_DATABASE.PUBLIC"
grant_read_deny_check staging_airflow TRANSFORMER_STAGING prod_airflow TRANSFORMER_PROD \
  "$SNOWFLAKE_STAGING_DATABASE.PUBLIC"

nstep 6 "publishing the CI identity to steam-analytics' GitHub secrets..."
# The CI service user's key pair is regenerated by every apply above, so this
# has to run on every bring-up or all three steam-analytics workflows
# authenticate with a key the account no longer has (#116).
#
# Three secrets, and deliberately not the role, database or warehouse: those
# are literals in the workflows. A secret that has gone stale is invisible —
# #114 renamed STEAM_PROJECT and the SNOWFLAKE_DATABASE secret went on naming
# it, which is what broke ci.yml's dbt-run job — while a wrong literal is in
# the diff. Fewer rotating values, fewer ways for the cold-start run to fail.
#
# Not read through run_step: it hides stdout, and sf_output's value is the
# whole point. The key is piped rather than passed as an argument so it never
# appears in a process listing.
ci_user=$(sf_output ci_user)
ci_key=$(sf_output ci_private_key)

# Same assertion as 05-cluster.sh makes on the Airflow keys, for the same
# reason: `private_key_pem_pkcs8` is what outputs.tf uses, but `private_key_pem`
# is PKCS#1 and one character away in the .tf — and it would read fine here,
# then fail in ci.yml with a PEM error nobody would trace back to this stage.
grep -q '^-----BEGIN PRIVATE KEY-----' <<<"$ci_key" \
  || fail "ci_private_key is not PKCS#8 PEM — dbt-snowflake rejects PKCS#1 ('BEGIN RSA PRIVATE KEY') and headerless keys; check terraform/snowflake/outputs.tf uses private_key_pem_pkcs8"

command -v gh >/dev/null 2>&1 \
  || fail "gh is required to push the CI identity to $ANALYTICS_REPO's secrets — install it and re-run this stage (scripts/bringup/bringup.sh --start-from 2 --stop-after 2)"

# gh reads the value from stdin when given no --body, which keeps the private
# key out of this process's argv.
gh_secret_set() {
  local name="$1"
  printf '%s' "$2" | gh secret set "$name" --repo "$ANALYTICS_REPO" >/dev/null \
    || fail "could not set the $name secret on $ANALYTICS_REPO — gh needs a token with repo scope on it (gh auth status)"
}
gh_secret_set SNOWFLAKE_ACCOUNT "$SNOWFLAKE_ACCOUNT"
gh_secret_set SNOWFLAKE_USER "$ci_user"
gh_secret_set SNOWFLAKE_PRIVATE_KEY "$ci_key"
ok "$ANALYTICS_REPO: SNOWFLAKE_ACCOUNT, SNOWFLAKE_USER ($ci_user), SNOWFLAKE_PRIVATE_KEY (PKCS#8 PEM)"
