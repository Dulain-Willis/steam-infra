#!/usr/bin/env bash
# Stage 6: prove $0 — nothing billable left in AWS or Snowflake. This AWS
# account is dedicated to this project (see CLAUDE.md/CONTEXT.md), so an
# account-wide check in the project region is simpler than tag-matching and
# also catches anything Kubernetes created that Terraform never knew about
# (dynamically-provisioned EBS volumes, in particular).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

stage 6 "Verify \$0"

problems=()

# check_empty "label" "value" — records a problem if value is non-empty.
check_empty() {
  local label="$1" value="$2"
  if [[ -z "$value" ]]; then
    ok "none"
  else
    warn "still present: $value"
    problems+=("$label: $value")
  fi
}

nstep 1 "EKS clusters..."
clusters=$(aws eks list-clusters --region "$AWS_REGION" --query 'clusters' --output text)
check_empty "EKS clusters" "$clusters"

nstep 2 "RDS instances..."
instances=$(aws rds describe-db-instances --region "$AWS_REGION" \
  --query 'DBInstances[].DBInstanceIdentifier' --output text 2>/dev/null || true)
check_empty "RDS instances" "$instances"

nstep 3 "EC2 instances..."
ec2=$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)
check_empty "EC2 instances" "$ec2"

nstep 4 "EBS volumes..."
volumes=$(aws ec2 describe-volumes --region "$AWS_REGION" \
  --filters "Name=status,Values=creating,available,in-use" \
  --query 'Volumes[].VolumeId' --output text)
check_empty "EBS volumes" "$volumes"

nstep 5 "load balancers..."
albs=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
  --query 'LoadBalancers[].LoadBalancerArn' --output text 2>/dev/null || true)
clbs=$(aws elb describe-load-balancers --region "$AWS_REGION" \
  --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text 2>/dev/null || true)
if [[ -z "$albs" && -z "$clbs" ]]; then
  ok "none"
else
  warn "still present: ${albs} ${clbs}"
  problems+=("load balancers: ${albs} ${clbs}")
fi

# Asks Snowflake, not tofu state — so anything left behind outside the module
# (an older session, a hand-rolled CREATE) still counts as a problem. Databases
# bill for storage; roles and service users don't, but a service user whose key
# pair is gone with the session's state is a credential nobody can account for,
# so "$0" here means "no project objects", not just "no storage".
env_complete || fail ".env incomplete"

# Each query's status is checked separately from its output, because a failed
# query must not read as "nothing left" — that is how a $0 report would get
# made over a live account nobody could reach.
nstep 6 "Snowflake project databases..."
databases=$(snowflake_databases_present) \
  || fail "could not query Snowflake for the project databases — see the error above"
check_empty "Snowflake databases" "$databases"

nstep 7 "Snowflake project roles..."
# Listed by exact name rather than matched by pattern: LOADER and
# TRANSFORMER_PROD share no prefix. The list lives in lib/env.sh.
remaining_roles=""
for role in "${SNOWFLAKE_PROJECT_ROLES[@]}"; do
  rows=$(sf_query "SHOW ROLES LIKE '$role'") \
    || fail "could not query Snowflake for role $role — see the error above"
  [[ -z "$rows" ]] || remaining_roles+="${remaining_roles:+ }$role"
done
check_empty "Snowflake roles" "$remaining_roles"

nstep 8 "Snowflake project service users..."
# SHOW USERS leads with the user's name (SHOW DATABASES and SHOW ROLES lead
# with created_on) — verified against the account. The pattern deliberately
# does not match the operator's own user, which is not ours to remove.
rows=$(sf_query "SHOW USERS LIKE '$SNOWFLAKE_PROJECT_USER_PATTERN'") \
  || fail "could not query Snowflake for the project service users — see the error above"
check_empty "Snowflake service users" "$(cut -f1 <<<"$rows" | paste -sd' ' -)"

if (( ${#problems[@]} )); then
  fail "\$0 verification failed: ${#problems[@]} problem(s) — see above"
fi

ok "\$0 verified — nothing billable left in AWS or Snowflake"
