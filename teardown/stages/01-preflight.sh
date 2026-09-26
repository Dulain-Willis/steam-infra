#!/usr/bin/env bash
# Stage 1/6: preflight. Fails fast on a missing tool, broken AWS
# credentials, or an incomplete .env — before any teardown work starts.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/output.sh
source "$REPO_ROOT/lib/output.sh"
# shellcheck source=lib/env.sh
source "$REPO_ROOT/lib/env.sh"

stage 1 6 "Preflight"

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
ok ".env complete"
