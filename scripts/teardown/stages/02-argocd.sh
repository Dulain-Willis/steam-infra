#!/usr/bin/env bash
# Stage 2/6: delete the ArgoCD Applications so Kubernetes-created AWS
# resources (PVC-backed EBS volumes, any load balancers) are actually gone
# on the AWS side before Stage 5's `tofu destroy` — otherwise they're
# orphaned (nothing in Terraform state references them, and the cluster
# that would delete them is gone) and can block VPC deletion.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

stage 2 6 "ArgoCD Applications"

# Stop the background tunnel Stage 6 of bring-up (#109) started pointing at
# the admin ALB, before that ALB gets deleted below — nothing left running
# against a target that's about to disappear.
TUNNEL_PID_FILE="$LOG_DIR/admin-alb-tunnel.pid"
nstep 1 "stopping the admin ALB tunnel, if running..."
if [[ -f "$TUNNEL_PID_FILE" ]]; then
  kill "$(cat "$TUNNEL_PID_FILE")" 2>/dev/null || true
  rm -f "$TUNNEL_PID_FILE"
fi
pkill -f "localPortNumber.*8888" 2>/dev/null || true
ok "stopped (or wasn't running)"

# Cascade-managed: root's finalizer makes ArgoCD delete these Application
# objects as part of deleting root; each of *their* finalizers then makes
# ArgoCD tear down what they actually deployed (Helm releases, Kafka CRs,
# connectors). "argocd" is deliberately excluded — it manages ArgoCD's own
# Helm release (the controller doing this deleting), so giving it the
# finalizer too risks the controller killing itself mid-cascade before it
# finishes the others. Left unmanaged, its resources have no PVC/LB and die
# with the EKS cluster in Stage 5 regardless.
CASCADE_APPS=(root airflow connectors kafka-cluster kafka-connect strimzi-operator)

nstep 2 "checking whether the cluster still exists..."
if ! aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  skip "no EKS cluster '$EKS_CLUSTER_NAME' — nothing to delete"
fi

nstep 3 "pointing kubectl at the cluster..."
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

if ! kubectl get application root -n argocd >/dev/null 2>&1; then
  say "no root Application — already deleted; still verifying PVCs/load balancers are gone."
else
  nstep 4 "patching the cascade finalizer onto each Application..."
  for app in "${CASCADE_APPS[@]}"; do
    kubectl get application "$app" -n argocd >/dev/null 2>&1 || continue
    kubectl patch application "$app" -n argocd --type merge \
      -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}' >/dev/null
  done

  nstep 5 "deleting root (cascades to the rest)..."
  kubectl delete application root -n argocd --wait=false --ignore-not-found >/dev/null

  # Best-effort, not awaited: see the CASCADE_APPS comment above.
  kubectl patch application argocd -n argocd --type merge \
    -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}' >/dev/null 2>&1 || true
  kubectl delete application argocd -n argocd --wait=false --ignore-not-found >/dev/null 2>&1 || true
fi

# StatefulSet-managed PVCs (airflow's postgresql/redis charts use
# volumeClaimTemplates) are never part of what ArgoCD applied — they're
# created by the StatefulSet controller, so pruning the Application never
# deletes them. Delete them directly; the ebs-csi-default storage class has
# reclaimPolicy: Delete, so this is what actually removes the EBS volumes.
nstep 6 "deleting PVCs the cascade above doesn't own..."
mapfile -t leftover_pvcs < <(kubectl get pvc -A --no-headers 2>/dev/null | awk '{print $1, $2}')
for entry in "${leftover_pvcs[@]+"${leftover_pvcs[@]}"}"; do
  read -r ns name <<<"$entry"
  kubectl delete pvc "$name" -n "$ns" --wait=false >/dev/null
done

nstep 7 "waiting for Applications, PVCs, and load balancers to be gone..."
# The PVC object disappearing from the Kubernetes API only means deletion was
# requested — the ebs-csi driver's actual DeleteVolume call against AWS is
# async and can still be in flight. If Stage 5's tofu destroy kills the
# cluster (and the csi-controller pod with it) before that call lands, the
# EBS volume is orphaned forever with nothing left to delete it. So wait on
# the AWS side too, not just the PVC object being gone.
#
# The admin ALB (#107) isn't a Service type=LoadBalancer object — it's
# created by the AWS Load Balancer Controller from Ingress objects, so
# lbs_left above never catches it. Checked separately via describe-load-
# balancers directly (account-wide, like Stage 6/6's final $0 verify — this
# account is dedicated to the project), same deadline, same reasoning: once
# Stage 5 destroys the cluster (and alb-controller's pod with it), nothing
# is left to ever delete this ALB if it isn't gone by then.
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
  apps_left=0
  for app in "${CASCADE_APPS[@]}"; do
    kubectl get application "$app" -n argocd >/dev/null 2>&1 && apps_left=$((apps_left + 1))
  done
  pvcs_left=$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  lbs_left=$(kubectl get svc -A -o json 2>/dev/null | jq '[.items[] | select(.spec.type=="LoadBalancer")] | length')
  ebs_vols_left=$(aws ec2 describe-volumes --region "$AWS_REGION" \
    --filters "Name=tag:KubernetesCluster,Values=$EKS_CLUSTER_NAME" "Name=status,Values=available,creating,in-use,deleting" \
    --query 'length(Volumes)' --output text 2>/dev/null || echo 1)
  albs_left=$(aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 1)
  if (( apps_left == 0 && pvcs_left == 0 && lbs_left == 0 && ebs_vols_left == 0 && albs_left == 0 )); then
    ok "Applications, PVCs, load balancers, and EBS volumes all gone"
    exit 0
  fi
  sleep 10
done

warn "timed out after 10m waiting for cleanup. Remaining state:"
kubectl get applications -n argocd 2>&1 >&2 || true
kubectl get pvc -A 2>&1 >&2 || true
kubectl get svc -A 2>&1 >&2 || true
aws ec2 describe-volumes --region "$AWS_REGION" \
  --filters "Name=tag:KubernetesCluster,Values=$EKS_CLUSTER_NAME" "Name=status,Values=available,creating,in-use,deleting" \
  2>&1 >&2 || true
aws elbv2 describe-load-balancers --region "$AWS_REGION" 2>&1 >&2 || true
fail "ArgoCD cascade delete did not finish in time"
