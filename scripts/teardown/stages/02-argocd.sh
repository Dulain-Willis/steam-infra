#!/usr/bin/env bash
# Stage 2: delete the ArgoCD Applications so Kubernetes-created AWS
# resources (PVC-backed EBS volumes, the admin ALB and the security groups
# the ALB controller made for it) are actually gone on the AWS side before
# Stage 5's `tofu destroy` — otherwise they're orphaned (nothing in Terraform
# state references them) and the security groups block DeleteVpc outright.
#
# Order is the whole point of this stage, and getting it wrong is #122:
# anything whose finalizer only a controller can release must be deleted, and
# *waited out*, while that controller is still running. So Ingresses go first
# and their ALB has to be gone before the cascade is allowed to take
# alb-controller with it. Everything destructive here lives in
# lib/teardown_sweep.sh, which says what bounds each action and is covered by
# lib/teardown_sweep_test.sh without a cluster.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/teardown_sweep.sh
source "$REPO_ROOT/scripts/lib/teardown_sweep.sh"

stage 2 "ArgoCD Applications"

# Stop the background tunnel Stage 7 of bring-up (#109) started pointing at
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
# finishes the others. Its PVC-free resources still die with the EKS
# cluster in Stage 5 regardless -- except its own Ingress (#107), which is
# deleted by drain_albs below along with Airflow's.
#
# The Airflow environments come from lib/env.sh's AIRFLOW_ENVIRONMENTS rather
# than being spelled out: an environment missing from this list gets no
# cascade finalizer, so root's delete removes its Application object without
# ArgoCD tearing down the Helm release underneath it.
CASCADE_APPS=(root "${AIRFLOW_ENVIRONMENTS[@]}" connectors kafka-cluster kafka-connect strimzi-operator)

nstep 2 "checking whether the cluster still exists..."
if aws eks describe-cluster --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  CLUSTER_UP=true
  ok "cluster '$EKS_CLUSTER_NAME' is up"
else
  CLUSTER_UP=false
  # Not a `skip`: the sweeps at the end of this stage are pure AWS calls and
  # are exactly what is still needed when the cluster is already gone but its
  # ALB security groups and CSI volumes are not (#122's recovery path).
  warn "no EKS cluster '$EKS_CLUSTER_NAME' — skipping the Kubernetes steps, still sweeping AWS"
fi

if [[ "$CLUSTER_UP" == true ]]; then
  nstep 3 "pointing kubectl at the cluster..."
  aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

  # Must come before anything is deleted: every Application has
  # selfHeal: true, so ArgoCD would recreate a deleted Ingress within seconds
  # and the ALB with it.
  nstep 4 "disabling automated sync so deletions aren't self-healed..."
  freeze_argocd_sync

  # #122. The ingress.k8s.aws/resources finalizer on an Ingress can only be
  # removed by alb-controller, and alb-controller goes away with the cascade
  # below. Delete the Ingresses and get their ALB gone first, while the
  # controller is still there to do it.
  nstep 5 "deleting Ingresses and draining their ALB (alb-controller still running)..."
  drain_albs

  # Requested before the cascade, satisfied by it: the pods have to release
  # the volumes before the CSI driver can delete them.
  nstep 6 "requesting deletion of every PVC (StatefulSet volumes ArgoCD never owned)..."
  request_pvc_deletion
  ok "deletion requested"

  if ! kubectl get application root -n argocd >/dev/null 2>&1; then
    say "no root Application — already deleted; still verifying the rest is gone."
  else
    nstep 7 "patching the cascade finalizer onto each Application..."
    for app in "${CASCADE_APPS[@]}"; do
      kubectl get application "$app" -n argocd >/dev/null 2>&1 || continue
      kubectl patch application "$app" -n argocd --type merge \
        -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}' >/dev/null
    done
    ok "finalizer patched onto the cascade"

    nstep 8 "deleting root (cascades to the rest)..."
    kubectl delete application root -n argocd --wait=false --ignore-not-found >/dev/null

    # Best-effort, not awaited: see the CASCADE_APPS comment above.
    kubectl patch application argocd -n argocd --type merge \
      -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}' >/dev/null 2>&1 || true
    kubectl delete application argocd -n argocd --wait=false --ignore-not-found >/dev/null 2>&1 || true
    ok "root deleted"
  fi

  nstep 9 "waiting for Applications, PVCs and their EBS volumes to be gone..."
  # The PVC object disappearing from the Kubernetes API only means deletion was
  # requested — the ebs-csi driver's actual DeleteVolume call against AWS is
  # async and can still be in flight. If Stage 5's tofu destroy kills the
  # cluster (and the csi-controller pod with it) before that call lands, the
  # EBS volume is orphaned with nothing left to delete it, so wait on the AWS
  # side too, not just the PVC object being gone.
  cleanup_remaining() {
    local apps_left=0 app
    for app in "${CASCADE_APPS[@]}"; do
      kubectl get application "$app" -n argocd >/dev/null 2>&1 && apps_left=$((apps_left + 1))
    done
    # A listing that *failed* must count as 1, not 0: "could not tell" reading
    # as "clean" is how this loop would exit successfully over a live stack.
    local pvcs_left lbs_left out
    out=$(kubectl get pvc -A --no-headers --ignore-not-found) \
      && pvcs_left=$(grep -c . <<<"$out" || true) || pvcs_left=1
    out=$(kubectl get svc -A -o json) \
      && lbs_left=$(jq '[.items[] | select(.spec.type=="LoadBalancer")] | length' <<<"$out" 2>/dev/null || echo 1) \
      || lbs_left=1
    echo $(( apps_left + pvcs_left + lbs_left + $(cluster_volumes_count) + $(albs_present) ))
  }

  if wait_until "$TEARDOWN_CLEANUP_TIMEOUT" cleanup_remaining; then
    ok "Applications, PVCs, load balancers and EBS volumes all gone"
  else
    # #122's expensive lesson: the dead-man's switch fired, called teardown.sh,
    # hit this timeout, reported honestly, and could not fix it. A timeout now
    # escalates — delete the AWS side directly (tag-bounded), then release the
    # finalizers that are holding the Kubernetes objects open — and only fails
    # if that does not reach zero either.
    warn "timed out after ${TEARDOWN_CLEANUP_TIMEOUT}s — escalating (see #122). Remaining state:"
    kubectl get applications -n argocd >&2 2>&1 || true
    kubectl get pvc -A >&2 2>&1 || true

    delete_project_load_balancers

    while read -r ns name; do
      [[ -n "$name" ]] || continue
      clear_finalizers persistentvolumeclaim "$name" "$ns"
      kubectl delete pvc "$name" -n "$ns" --wait=false >/dev/null 2>&1 || true
    done < <(kubectl get pvc -A --no-headers --ignore-not-found | awk '{print $1, $2}')

    for app in "${CASCADE_APPS[@]}"; do
      kubectl get application "$app" -n argocd >/dev/null 2>&1 || continue
      clear_finalizers application "$app" argocd
      kubectl delete application "$app" -n argocd --wait=false --ignore-not-found >/dev/null 2>&1 || true
    done

    # After the finalizers, not before: releasing a stuck pvc-protection is
    # what detaches the volume, and only a detached one is `available` and so
    # deletable.
    sweep_orphan_volumes

    wait_until "$TEARDOWN_ESCALATED_TIMEOUT" cleanup_remaining \
      || fail "cleanup did not finish even after clearing finalizers — MANUAL CHECK REQUIRED, the stack may still be billing"
    ok "cleanup finished after escalating"
  fi
fi

# Neither of these is in tofu state, so `tofu destroy` leaves both behind
# (#122). The security groups are the blocking one: DeleteVpc fails with
# DependencyViolation while they exist. Volumes are swept again in Stage 5
# after the destroy, because a volume still attached to a node now becomes
# `available` only once that node is terminated.
nstep 10 "sweeping the alb-controller security groups (they block DeleteVpc)..."
sweep_alb_controller_security_groups

nstep 11 "sweeping CSI-provisioned EBS volumes tofu destroy does not own..."
sweep_orphan_volumes
