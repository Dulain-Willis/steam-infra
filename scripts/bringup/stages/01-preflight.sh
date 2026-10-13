#!/usr/bin/env bash
# Stage 1: preflight. Fails fast on a missing tool, broken AWS
# credentials, or an incomplete .env — before any bring-up work starts.
# Then detects leftovers from a previous session (either tofu state holding
# resources beyond the tfstate bucket, or the Snowflake root module's state
# holding anything, or a project Snowflake database existing outside that state)
# and runs a full teardown first, so every normal bring-up starts from a
# clean slate.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

stage 1 "Preflight"

missing=()
for bin in tofu aws kubectl helm uv jq psql session-manager-plugin gh; do
  command -v "$bin" >/dev/null 2>&1 || missing+=("$bin")
done
if (( ${#missing[@]} )); then
  fail "missing required tools: ${missing[*]}"
fi
# gh is Stage 2's, for pushing the CI identity to steam-analytics' secrets
# (#116). Checked here rather than there so a missing tool fails in preflight
# rather than after a tofu apply.
ok "required tools present: tofu, aws, kubectl, helm, uv, jq, psql, session-manager-plugin, gh"

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  fail "AWS credentials not working (aws sts get-caller-identity failed) — configure your AWS profile/SSO session."
fi
ok "AWS credentials OK"

env_complete || fail ".env incomplete"
ok ".env complete, key file present"

nstep 1 "checking for leftovers from a previous session..."
run_step "tofu init" tf init -input=false
run_step "tofu init (snowflake)" tf_snowflake init -input=false
tf_leftover_resources=$(tf_leftovers)
sf_leftover_resources=$(sf_leftovers)
snowflake_databases=$(snowflake_databases_present) \
  || fail "could not query Snowflake for the project databases — see the error above"

if [[ -z "$tf_leftover_resources" && -z "$sf_leftover_resources" && -z "$snowflake_databases" ]]; then
  ok "no leftovers — starting from nothing"
else
  [[ -n "$tf_leftover_resources" ]] && warn "tofu state holds resources beyond the tfstate bucket"
  [[ -n "$sf_leftover_resources" ]] && warn "the Snowflake module's state holds resources"
  [[ -n "$snowflake_databases" ]] && warn "already exist(s) in Snowflake: $snowflake_databases"
  nsub "running teardown first..."
  bash "$REPO_ROOT/scripts/teardown/teardown.sh"
  ok "leftovers cleared"
fi
