#!/usr/bin/env bash
# Stage 6/6: prove $0 — nothing billable left in AWS or Snowflake. This AWS
# account is dedicated to this project (see CLAUDE.md/CONTEXT.md), so an
# account-wide check in the project region is simpler than tag-matching and
# also catches anything Kubernetes created that Terraform never knew about
# (dynamically-provisioned EBS volumes, in particular).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/output.sh
source "$REPO_ROOT/lib/output.sh"
# shellcheck source=lib/env.sh
source "$REPO_ROOT/lib/env.sh"

stage 6 6 "Verify \$0"

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

nstep 6 "Snowflake database $SNOWFLAKE_DATABASE..."
env_complete || fail ".env incomplete"
if uv run "$REPO_ROOT/lib/snowflake_db.py" database-exists >/dev/null 2>&1; then
  warn "$SNOWFLAKE_DATABASE still exists"
  problems+=("Snowflake database: $SNOWFLAKE_DATABASE")
else
  ok "absent"
fi

if (( ${#problems[@]} )); then
  fail "\$0 verification failed: ${#problems[@]} problem(s) — see above"
fi

ok "\$0 verified — nothing billable left in AWS or Snowflake"
