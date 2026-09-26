#!/usr/bin/env bash
# Stage 2/2: AWS infrastructure. One `tofu apply` of everything except the
# generator (held back until the database is seeded — a later stage), then
# verifies EKS nodes Ready (both node groups), RDS available, and the
# bastion's SSM agent Online, so a stage 3 failure doesn't waste a 20-minute
# EKS rebuild and later stages never run against infra that exists but
# isn't usable yet.
#
# No separate "already up" pre-check: `tofu apply` is itself idempotent
# (0 changes when the state already matches), so re-running this stage
# against healthy infra is already fast — a hand-rolled skip added a
# flaky extra check (AWS eventual-consistency right after a prior apply)
# for no real savings.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/output.sh
source "$REPO_ROOT/lib/output.sh"
# shellcheck source=lib/env.sh
source "$REPO_ROOT/lib/env.sh"

stage 2 3 "AWS"

bastion_online() {
  local bastion_id
  bastion_id=$(tf output -raw bastion_instance_id 2>/dev/null || true)
  [[ -n "$bastion_id" ]] || return 1
  [[ "$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$bastion_id" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)" == "Online" ]]
}

eks_nodes_ready() {
  aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || return 1
  aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || return 1
  local nodes_json total ready groups
  nodes_json=$(kubectl get nodes -o json 2>/dev/null) || return 1
  total=$(jq '.items | length' <<<"$nodes_json")
  (( total > 0 )) || return 1
  ready=$(jq '[.items[] | select(.status.conditions[]? | select(.type=="Ready" and .status=="True"))] | length' <<<"$nodes_json")
  (( ready == total )) || return 1
  groups=$(jq -r '.items[].metadata.labels["eks.amazonaws.com/nodegroup"] // empty' <<<"$nodes_json")
  grep -q "system" <<<"$groups" || return 1
  grep -q "kafka" <<<"$groups" || return 1
  return 0
}

run_step "tofu init" tf init -input=false

nstep 1 "applying AWS infra (excluding the generator) — EKS node groups are the slow part, budget 15-20 min..."
nsub "bringing up:"
nbullet "core network resources (VPC, subnets, routes, IGW)"
nbullet "rds instance (postgres)"
nbullet "bastion EC2 instance"
nbullet "EKS nodes (system + kafka node groups)"
nbullet "empty ECR repo for the Kafka Connect image"
run_step "tofu apply" tf apply -auto-approve -exclude=aws_instance.generator

nstep 2 "verifying EKS nodes Ready (both node groups)..."
deadline=$((SECONDS + 1200))
until eks_nodes_ready; do
  (( SECONDS < deadline )) || fail "EKS nodes never became Ready (both node groups) in time"
  sleep 15
done
ok "EKS nodes Ready (system + kafka node groups)"

nstep 3 "verifying RDS available..."
run_step "wait for RDS available" aws rds wait db-instance-available --db-instance-identifier "$RDS_INSTANCE_ID"
ok "RDS available"

nstep 4 "verifying bastion SSM agent Online..."
deadline=$((SECONDS + 200))
until bastion_online; do
  (( SECONDS < deadline )) || fail "bastion SSM agent never came online"
  sleep 5
done
ok "bastion SSM agent Online"
