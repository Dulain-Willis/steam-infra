#!/usr/bin/env bash
# Stage 4: destroy terraform/snowflake — the databases and all their schemas
# (dbt's outputs included), the roles and the service users — so no Snowflake
# storage bills between sessions and no identity outlives the session whose
# key pair it holds.
#
# Nothing in this root module survives a teardown (unlike the AWS root, which
# keeps the tfstate bucket), so this is a plain destroy with no exclusions.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

stage 4 "Snowflake"

env_complete || fail ".env incomplete"

nstep 1 "checking for Snowflake resources left to destroy..."
run_step "tofu init (snowflake)" tf_snowflake init -input=false
if [[ -z "$(sf_leftovers)" ]]; then
  # Nothing in state. The databases are only ever created by this module now,
  # so if one exists anyway something made it outside tofu — fail here with
  # the fix rather than at Stage 6's $0 verify with just the symptom.
  orphans=$(snowflake_databases_present) \
    || fail "could not query Snowflake for the project databases — see the error above"
  [[ -z "$orphans" ]] || fail "$orphans exist(s) but terraform/snowflake's state is empty — import them (tofu -chdir=terraform/snowflake import snowflake_database.raw $SNOWFLAKE_RAW_DATABASE) and re-run, or drop them by hand"
  skip "the Snowflake module's state is empty"
fi

nstep 2 "running tofu destroy (snowflake)..."
run_step "tofu destroy (snowflake)" tf_snowflake destroy -auto-approve -input=false

nstep 3 "verifying the project databases are gone..."
remaining=$(snowflake_databases_present) \
  || fail "could not query Snowflake for the project databases — see the error above"
[[ -z "$remaining" ]] || fail "still present after tofu destroy: $remaining"
if [[ -n "$(sf_leftovers)" ]]; then
  warn "resources still in the Snowflake module's state:"
  sf_leftovers >&2
  fail "tofu destroy left Snowflake resources behind"
fi
ok "${SNOWFLAKE_PROJECT_DATABASES[*]} dropped, Snowflake state empty"
