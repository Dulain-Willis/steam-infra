#!/usr/bin/env bash
# Stage 4/6: drop the Snowflake database — all schemas, including dbt's
# outputs — so no Snowflake storage bills between sessions.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/output.sh
source "$REPO_ROOT/lib/output.sh"
# shellcheck source=lib/env.sh
source "$REPO_ROOT/lib/env.sh"

stage 4 6 "Snowflake"

env_complete || fail ".env incomplete"

nstep 1 "checking whether $SNOWFLAKE_DATABASE exists..."
if ! uv run "$REPO_ROOT/lib/snowflake_db.py" database-exists >/dev/null 2>&1; then
  skip "$SNOWFLAKE_DATABASE does not exist"
fi

nstep 2 "dropping $SNOWFLAKE_DATABASE..."
run_step "drop database" uv run "$REPO_ROOT/lib/snowflake_db.py" drop-database

nstep 3 "verifying it's gone..."
if uv run "$REPO_ROOT/lib/snowflake_db.py" database-exists >/dev/null 2>&1; then
  fail "$SNOWFLAKE_DATABASE still exists after DROP DATABASE"
fi
ok "$SNOWFLAKE_DATABASE dropped"
