#!/usr/bin/env bash
# Stage 4: destroy terraform/snowflake — the database and all its schemas,
# including dbt's outputs — so no Snowflake storage bills between sessions.
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
  # Nothing in state. A database created outside this module (an older
  # session, a hand-rolled CREATE) is still caught by Stage 6's $0 verify.
  skip "the Snowflake module's state is empty"
fi

nstep 2 "running tofu destroy (snowflake)..."
run_step "tofu destroy (snowflake)" tf_snowflake destroy -auto-approve -input=false

nstep 3 "verifying $SNOWFLAKE_DATABASE is gone..."
if snowflake_database_exists; then
  fail "$SNOWFLAKE_DATABASE still exists after tofu destroy"
fi
if [[ -n "$(sf_leftovers)" ]]; then
  warn "resources still in the Snowflake module's state:"
  sf_leftovers >&2
  fail "tofu destroy left Snowflake resources behind"
fi
ok "$SNOWFLAKE_DATABASE dropped, Snowflake state empty"
