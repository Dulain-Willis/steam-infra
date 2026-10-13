#!/usr/bin/env bash
# Teardown's deletion ordering and its sweep for AWS resources nothing else
# owns. Sourced by teardown/stages/02-argocd.sh and 05-tofu-destroy.sh —
# never run directly. Depends on lib/output.sh and lib/env.sh already being
# sourced (uses nbullet/ok/warn/fail, AWS_REGION, EKS_CLUSTER_NAME,
# AIRFLOW_ENVIRONMENTS).
#
# Why this is a library rather than inline stage code: there is no way to
# exercise a teardown's failure paths on a live stack — you cannot ask AWS for
# "an Ingress whose finalizer will never be released" — and those paths are
# exactly where #122 cost money. scripts/lib/teardown_sweep_test.sh stubs
# kubectl, aws and sleep and drives all of them, including a whole run of
# Stage 2 against a fake cluster that models the defect.
#
# #122 in one line: the alb-controller Application was pruned before
# airflow-staging's Ingress, so the ingress.k8s.aws/resources finalizer — which
# only that controller can remove — was never released, the ALB never drained,
# and the stage spun to its 10-minute timeout and gave up with the stack still
# billing.

# Overridable so the test suite does not sleep for real; the defaults are the
# live ones.
: "${TEARDOWN_DRAIN_TIMEOUT:=600}"
: "${TEARDOWN_CLEANUP_TIMEOUT:=600}"
: "${TEARDOWN_ESCALATED_TIMEOUT:=180}"
: "${TEARDOWN_POLL_INTERVAL:=10}"

# ---------------------------------------------------------------------------
# What this teardown owns
# ---------------------------------------------------------------------------

# teardown_namespaces: the namespaces whose Ingresses this teardown deletes and
# whose finalizers it may clear. Driven off AIRFLOW_ENVIRONMENTS (lib/env.sh)
# rather than spelled out, for the reason #119 consolidated the other copy of
# that list: an environment missing from it is an Ingress nobody deletes, and
# that is #122. Plus argocd, whose own Ingress (#107) the cascade never prunes
# because the argocd Application deliberately carries no cascade finalizer.
teardown_namespaces() { printf '%s\n' "${AIRFLOW_ENVIRONMENTS[@]}" argocd; }

# project_ingresses: "<namespace> <name>" per line, only within
# teardown_namespaces. This is the bound on every Ingress deletion and every
# finalizer clear below.
project_ingresses() {
  local ns
  while read -r ns; do
    kubectl get ingress -n "$ns" --no-headers \
      -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name 2>/dev/null
  done < <(teardown_namespaces)
}

# ---------------------------------------------------------------------------
# Read-only counts and listings
# ---------------------------------------------------------------------------

# albs_present: ALBs in the project region, account-wide — the same reasoning
# as Stage 6's $0 verify, this AWS account is dedicated to the project
# (CLAUDE.md/CONTEXT.md). Account-wide is deliberate for the *check*: it
# cannot miss an ALB whose tags came out wrong. Deleting is tag-scoped, see
# project_elb_arns. A failed call counts as 1, never 0, so an unreachable API
# can never read as "drained".
albs_present() {
  aws elbv2 describe-load-balancers --region "$AWS_REGION" \
    --query 'length(LoadBalancers)' --output text 2>/dev/null || echo 1
}

# project_elb_arns loadbalancer|targetgroup — tag-scoped to the ALBs and target
# groups the AWS Load Balancer Controller created for *this* cluster. This is
# the bound on deleting load balancers directly.
project_elb_arns() {
  aws resourcegroupstaggingapi get-resources --region "$AWS_REGION" \
    --tag-filters "Key=elbv2.k8s.aws/cluster,Values=$EKS_CLUSTER_NAME" \
    --resource-type-filters "elasticloadbalancing:$1" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null \
    | _words
}

# _words: whitespace-separated AWS CLI text output to one token per line, with
# the empty result and the literal "None" dropped.
_words() { tr -s '[:space:]' '\n' | sed '/^$/d; /^None$/d'; }

# cluster_volumes STATUSES — the EBS volumes this cluster's CSI driver
# provisioned, in any of STATUSES (a comma-separated describe-volumes filter
# value).
#
# Two filters, unioned, because one of them does not actually match:
# `KubernetesCluster` is the *in-tree* provisioner's tag and the
# aws-ebs-csi-driver EKS addon does not set it unless --k8s-tag-cluster-id is
# configured, which it is not here. That is why the pre-#122 EBS check in Stage
# 2 could pass over the four gp3 volumes that then survived `tofu destroy`.
# `CSIVolumeName` is set by the driver on every volume it creates, so it is the
# filter that actually finds them; the legacy tag is kept because a volume from
# an older session would carry it.
cluster_volumes() {
  local statuses="$1"
  {
    aws ec2 describe-volumes --region "$AWS_REGION" \
      --filters "Name=tag:KubernetesCluster,Values=$EKS_CLUSTER_NAME" \
      "Name=status,Values=$statuses" \
      --query 'Volumes[].VolumeId' --output text 2>/dev/null
    aws ec2 describe-volumes --region "$AWS_REGION" \
      --filters "Name=tag-key,Values=CSIVolumeName" \
      "Name=status,Values=$statuses" \
      --query 'Volumes[].VolumeId' --output text 2>/dev/null
  } | _words | sort -u
}

cluster_volumes_count() { cluster_volumes creating,available,in-use,deleting | wc -l | tr -d ' '; }

# project_vpc_id: this project's VPC (terraform/network.tf tags it
# Name=steam-infra). Used only to bound the security-group sweep, and only
# while the VPC still exists.
project_vpc_id() {
  aws ec2 describe-vpcs --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=$EKS_CLUSTER_NAME" \
    --query 'Vpcs[].VpcId' --output text 2>/dev/null | _words | head -n 1
}

# alb_controller_security_groups: the security groups the AWS Load Balancer
# Controller creates for the admin ALB (k8s-steaminfraadmin-*,
# k8s-traffic-steaminfra-*). They are not in tofu state, so `tofu destroy`
# never touches them, and they hold the VPC open — DeleteVpc fails with
# DependencyViolation while they exist (#122).
#
# Bounded two ways, and nothing outside this project's stack can match either:
#   - the controller's own `elbv2.k8s.aws/cluster=steam-infra` tag; or
#   - the `k8s-*` name prefix *inside this project's VPC*.
# Terraform's own security groups match neither (eks-cluster-sg-steam-infra-*,
# steam-infra-*), and the VPC's `default` group does not match the k8s- prefix.
alb_controller_security_groups() {
  local vpc
  aws ec2 describe-security-groups --region "$AWS_REGION" \
    --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$EKS_CLUSTER_NAME" \
    --query 'SecurityGroups[].GroupId' --output text 2>/dev/null | _words
  vpc=$(project_vpc_id)
  if [[ -n "$vpc" ]]; then
    aws ec2 describe-security-groups --region "$AWS_REGION" \
      --filters "Name=vpc-id,Values=$vpc" "Name=group-name,Values=k8s-*" \
      --query 'SecurityGroups[].GroupId' --output text 2>/dev/null | _words
  fi
}

# ---------------------------------------------------------------------------
# Waiting
# ---------------------------------------------------------------------------

# wait_until TIMEOUT COUNT_FN... — polls COUNT_FN until it prints 0. Returns 0
# when it does, 1 on timeout. SECONDS-based so the test can stub `sleep` to
# advance the clock instead of waiting.
wait_until() {
  local deadline=$((SECONDS + $1)); shift
  while :; do
    [[ "$("$@")" == 0 ]] && return 0
    (( SECONDS >= deadline )) && return 1
    sleep "$TEARDOWN_POLL_INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# Destructive steps
# ---------------------------------------------------------------------------

# clear_finalizers KIND NAME NAMESPACE — the last resort, and the reason an
# unattended teardown can now recover instead of reporting "may still be
# billing" and stopping (#122's dead-man's switch).
#
# Bounded: only ever called below on an object this teardown already deleted
# and already waited out, in a namespace teardown_namespaces names (or
# Applications in argocd), and only *after* the AWS resource the finalizer
# exists to clean up has been deleted directly. Clearing a finalizer whose AWS
# side is still there would strand a billing resource, which is the one
# outcome worse than failing.
clear_finalizers() {
  nbullet "clearing finalizers on $1/$2 in $3"
  kubectl patch "$1" "$2" -n "$3" --type merge \
    -p '{"metadata":{"finalizers":[]}}' >/dev/null 2>&1 \
    || warn "could not clear finalizers on $1/$2 in $3"
}

# delete_project_load_balancers: delete the controller's ALBs and target groups
# directly, by tag. Only reached from an escalation path — while the controller
# is alive, deleting the Ingress is what should remove them.
delete_project_load_balancers() {
  local arn
  for arn in $(project_elb_arns loadbalancer); do
    nbullet "deleting load balancer $arn"
    aws elbv2 delete-load-balancer --region "$AWS_REGION" --load-balancer-arn "$arn" \
      >/dev/null 2>&1 || warn "could not delete $arn"
  done
  # Target groups go after the load balancer; while it exists they are still
  # attached to its listener and DeleteTargetGroup is refused.
  for arn in $(project_elb_arns targetgroup); do
    nbullet "deleting target group $arn"
    aws elbv2 delete-target-group --region "$AWS_REGION" --target-group-arn "$arn" \
      >/dev/null 2>&1 || warn "could not delete $arn"
  done
}

# freeze_argocd_sync: turn off automated sync on every Application before
# anything is deleted out from under ArgoCD.
#
# Not optional, and not a nicety: `selfHeal: true` is set on root and on every
# child (argocd/root.yaml, argocd/apps/*.yaml), so a directly-deleted Ingress
# is recreated within seconds, the ALB comes straight back, and drain_albs
# below could never reach zero no matter how long it waited. Patching only the
# children would not help either — root's own selfHeal would put their
# syncPolicy back.
#
# Bounded: Applications in this cluster's argocd namespace, and the patch
# changes only spec.syncPolicy. Nothing is deleted here, and the cascade
# finalizer is unaffected (deletion propagation is the finalizer's job, not
# syncPolicy's).
freeze_argocd_sync() {
  local app frozen=0
  for app in $(kubectl get applications -n argocd -o name 2>/dev/null); do
    kubectl patch "$app" -n argocd --type merge -p '{"spec":{"syncPolicy":null}}' >/dev/null 2>&1 \
      || warn "could not disable automated sync on $app"
    frozen=$((frozen + 1))
  done
  ok "automated sync disabled on $frozen Application(s)"
}

# drain_albs: delete the Ingresses and wait for the ALB to drain *while
# alb-controller is still running*. This is #122's fix: it must run before the
# root Application is deleted, because the ingress.k8s.aws/resources finalizer
# can only be removed by that controller.
#
# On timeout it escalates rather than failing: delete the ALBs and target
# groups directly by tag, then release the stuck finalizers, then re-check.
# Only if that also fails to reach zero does it fail — and then the stack
# really does need a human.
drain_albs() {
  local ns name found=0
  while read -r ns name; do
    [[ -n "$name" ]] || continue
    found=1
    nbullet "deleting ingress $name in $ns"
    kubectl delete ingress "$name" -n "$ns" --wait=false --ignore-not-found >/dev/null 2>&1 || true
  done < <(project_ingresses)
  (( found )) || nsub "no Ingresses in ${AIRFLOW_ENVIRONMENTS[*]} argocd"

  if wait_until "$TEARDOWN_DRAIN_TIMEOUT" albs_present; then
    ok "load balancers drained by alb-controller"
    return 0
  fi

  warn "load balancers still present after ${TEARDOWN_DRAIN_TIMEOUT}s — escalating (see #122)"
  # Q7.4: the wait above is account-wide, deliberately — a mis-tagged ALB of
  # ours is the expensive thing to miss. The cost is that an ALB belonging to
  # something *else* in this region stalls it forever, and the escalation
  # cannot delete that one (it is tag-bounded, and must stay that way). Say so
  # by name rather than failing as if the fix had not worked.
  if [[ -z "$(project_elb_arns loadbalancer)" ]]; then
    fail "load balancers remain in $AWS_REGION but none are tagged elbv2.k8s.aws/cluster=$EKS_CLUSTER_NAME, so they are not this stack's and teardown will not delete them — MANUAL CHECK REQUIRED"
  fi
  delete_project_load_balancers
  while read -r ns name; do
    [[ -n "$name" ]] || continue
    clear_finalizers ingress "$name" "$ns"
    kubectl delete ingress "$name" -n "$ns" --wait=false --ignore-not-found >/dev/null 2>&1 || true
  done < <(project_ingresses)

  wait_until "$TEARDOWN_ESCALATED_TIMEOUT" albs_present \
    || fail "load balancers still present after deleting them directly — MANUAL CHECK REQUIRED, the stack may still be billing"
  ok "load balancers drained after escalating"
}

# request_pvc_deletion: mark every PVC for deletion. StatefulSet
# volumeClaimTemplates (airflow's postgresql/redis charts) are created by the
# StatefulSet controller, so they are never part of what ArgoCD applied and
# pruning the Application never deletes them.
#
# Namespace-agnostic on purpose: every PVC on this cluster belongs to this
# stack, and the cluster itself is about to be destroyed. The volumes do not
# actually go until the pods release them, which is what the cascade below
# does — the ebs-csi-driver is a Terraform EKS addon, not an ArgoCD
# Application, so it survives the cascade and gets to run its DeleteVolume
# calls.
request_pvc_deletion() {
  local entry ns name pvcs=()
  mapfile -t pvcs < <(kubectl get pvc -A --no-headers 2>/dev/null | awk '{print $1, $2}')
  for entry in "${pvcs[@]+"${pvcs[@]}"}"; do
    read -r ns name <<<"$entry"
    [[ -n "$name" ]] || continue
    kubectl delete pvc "$name" -n "$ns" --wait=false >/dev/null 2>&1 || true
  done
}

# sweep_orphan_volumes: delete the CSI-provisioned gp3 volumes nothing else
# will. They are not in tofu state, so `tofu destroy` leaves them behind and
# they keep billing (#122: four of them, deleted by hand).
#
# Bounded to volumes this cluster's CSI driver provisioned (cluster_volumes)
# *and* in state `available`. The status bound is what makes this safe: an
# attached volume is never touched, so this can never pull a disk out from
# under something still running.
sweep_orphan_volumes() {
  local vol swept=0
  for vol in $(cluster_volumes available); do
    nbullet "deleting orphaned volume $vol"
    aws ec2 delete-volume --region "$AWS_REGION" --volume-id "$vol" >/dev/null 2>&1 \
      || warn "could not delete $vol"
    swept=$((swept + 1))
  done
  if (( swept )); then
    ok "swept $swept CSI-provisioned volume(s) tofu destroy does not own"
  else
    ok "no orphaned CSI volumes"
  fi
}

# sweep_alb_controller_security_groups: delete the controller's own security
# groups. Not optional — while they exist, DeleteVpc fails with
# DependencyViolation and `tofu destroy` cannot finish (#122).
#
# Bounded by alb_controller_security_groups (tag, or k8s-* inside this
# project's VPC). The rule revocations are bounded tighter still: only rules
# whose *referenced* group is one of those security groups, which is the
# ingress rule the controller adds to the node group pointing back at the ALB
# group — the thing that makes DeleteSecurityGroup fail.
sweep_alb_controller_security_groups() {
  local sg owner rule egress swept=0
  for sg in $(alb_controller_security_groups | sort -u); do
    while read -r owner rule egress; do
      [[ -n "$rule" ]] || continue
      local verb=revoke-security-group-ingress
      [[ "$egress" == "True" || "$egress" == "true" ]] && verb=revoke-security-group-egress
      nbullet "revoking rule $rule in $owner (references $sg)"
      aws ec2 "$verb" --region "$AWS_REGION" --group-id "$owner" \
        --security-group-rule-ids "$rule" >/dev/null 2>&1 \
        || warn "could not revoke $rule in $owner"
    done < <(aws ec2 describe-security-group-rules --region "$AWS_REGION" \
      --filters "Name=referenced-group-id,Values=$sg" \
      --query 'SecurityGroupRules[].[GroupId,SecurityGroupRuleId,IsEgress]' \
      --output text 2>/dev/null)

    nbullet "deleting security group $sg"
    aws ec2 delete-security-group --region "$AWS_REGION" --group-id "$sg" >/dev/null 2>&1 \
      || warn "could not delete $sg — it may still be referenced"
    swept=$((swept + 1))
  done
  if (( swept )); then
    ok "swept $swept alb-controller security group(s) — DeleteVpc is no longer blocked"
  else
    ok "no alb-controller security groups left"
  fi
}
