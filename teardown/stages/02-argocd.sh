#!/usr/bin/env bash
# Stage 2/6: delete the ArgoCD Applications so Kubernetes-created AWS
# resources (PVC-backed EBS volumes, any load balancers) are gone before
# Stage 5's `tofu destroy` — otherwise they're orphaned (nothing in
# Terraform state references them) and can block VPC deletion.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/output.sh
source "$REPO_ROOT/lib/output.sh"
# shellcheck source=lib/env.sh
source "$REPO_ROOT/lib/env.sh"

stage 2 6 "ArgoCD Applications"

# Cascade-managed: root's finalizer makes ArgoCD delete these Application
# objects as part of deleting root; each of *their* finalizers then makes
# ArgoCD tear down what they actually deployed (Helm releases, Kafka CRs,
# connectors). "argocd" is deliberately excluded — it manages ArgoCD's own
# Helm release (the controller doing this deleting), so giving it the
# finalizer too risks the controller killing itself mid-cascade before it
# finishes the others. Left unmanaged, its resources have no PVC/LB and die
# with the EKS cluster in Stage 5 regardless.
CASCADE_APPS=(root airflow connectors kafka-cluster kafka-connect strimzi-operator)

nstep 1 "checking whether the cluster still exists..."
if ! aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  skip "no EKS cluster '$EKS_CLUSTER_NAME' — nothing to delete"
fi

nstep 2 "pointing kubectl at the cluster..."
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

if ! kubectl get application root -n argocd >/dev/null 2>&1; then
  say "no root Application — already deleted; still verifying PVCs/load balancers are gone."
else
  nstep 3 "patching the cascade finalizer onto each Application..."
  for app in "${CASCADE_APPS[@]}"; do
    kubectl get application "$app" -n argocd >/dev/null 2>&1 || continue
    kubectl patch application "$app" -n argocd --type merge \
      -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}' >/dev/null
  done

  nstep 4 "deleting root (cascades to the rest)..."
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
nstep 5 "deleting PVCs the cascade above doesn't own..."
mapfile -t leftover_pvcs < <(kubectl get pvc -A --no-headers 2>/dev/null | awk '{print $1, $2}')
for entry in "${leftover_pvcs[@]+"${leftover_pvcs[@]}"}"; do
  read -r ns name <<<"$entry"
  kubectl delete pvc "$name" -n "$ns" --wait=false >/dev/null
done

nstep 6 "waiting for Applications, PVCs, and load balancers to be gone..."
deadline=$((SECONDS + 600))
while (( SECONDS < deadline )); do
  apps_left=0
  for app in "${CASCADE_APPS[@]}"; do
    kubectl get application "$app" -n argocd >/dev/null 2>&1 && apps_left=$((apps_left + 1))
  done
  pvcs_left=$(kubectl get pvc -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
  lbs_left=$(kubectl get svc -A -o json 2>/dev/null | jq '[.items[] | select(.spec.type=="LoadBalancer")] | length')
  if (( apps_left == 0 && pvcs_left == 0 && lbs_left == 0 )); then
    ok "Applications, PVCs, and load balancers all gone"
    exit 0
  fi
  sleep 10
done

warn "timed out after 10m waiting for cleanup. Remaining state:"
kubectl get applications -n argocd 2>&1 >&2 || true
kubectl get pvc -A 2>&1 >&2 || true
kubectl get svc -A 2>&1 >&2 || true
fail "ArgoCD cascade delete did not finish in time"
