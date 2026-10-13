#!/usr/bin/env bash
# Tests teardown Stages 2 and 5 against a fake cluster and a fake AWS. Run it
# directly:
#
#     bash scripts/lib/teardown_sweep_test.sh
#
# Why this exists: #122 was a *deletion ordering* defect that only appears once
# a second Airflow release exists, and it cost real money. A live teardown can
# only ever exercise the happy path — you cannot ask AWS for "an Ingress whose
# finalizer will never be released", and standing up EKS to prove a teardown
# fix is exactly the expense the fix is meant to avoid. So kubectl, aws and
# tofu are stubbed over a small model of the stack, and the real stage scripts
# are run against it. Every scenario below is one that actually happened, and
# every one of them fails against the pre-#122 stages.
#
# No framework on purpose, same as lib/grant_check_test.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

# --- the fake stack ---------------------------------------------------------
#
# State is a directory of flat files so the stubs (separate processes) share
# it. Each file is one record per line:
#
#   cluster      up | gone
#   controller   alive | dead        -- is alb-controller still running
#   ingresses    <ns> <name>
#   albs         <arn>               -- all tagged elbv2.k8s.aws/cluster=steam-infra
#   targetgroups <arn>
#   volumes      <id> <status> csi|legacy|none
#   sgs          <id> <name> <vpc> tagged|untagged
#   sgrules      <ruleid> <owner-sg> <egress> <referenced-sg>
#   apps         <name> none|cascade auto|frozen   -- auto = selfHeal: true
#   pvcs         <ns> <name> <volume-id> bound|deleting normal|stuck
#   pods         <ns> alive|gone
#   vpcs         <id> <name>
#   log          every stub invocation, in order
#   undeletable  ARNs delete-load-balancer refuses (models AWS saying no)

cat >"$BIN/fakelib.sh" <<'FAKELIB'
STATE="$FAKE_STATE"
log() { printf '%s\n' "$*" >>"$STATE/log"; }
argval() {
  local want="$1"; shift
  while (($#)); do
    [[ "$1" == "$want" ]] && { printf '%s' "${2:-}"; return 0; }
    [[ "$1" == "$want="* ]] && { printf '%s' "${1#*=}"; return 0; }
    shift
  done
  return 1
}
anyarg() {
  local re="$1" a; shift
  for a in "$@"; do [[ "$a" == *"$re"* ]] && return 0; done
  return 1
}
# drop_line FILE FIELD-INDEX VALUE
drop_line() {
  local f="$STATE/$1" idx="$2" val="$3"
  awk -v i="$idx" -v v="$val" '$i != v' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}
set_field() {  # set_field FILE KEY-VALUE FIELD-INDEX NEW
  local f="$STATE/$1" key="$2" idx="$3" new="$4"
  awk -v k="$key" -v i="$idx" -v n="$new" '$1 == k { $i = n } { print }' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}
pods_state() { awk -v n="$1" '$1 == n { print $2 }' "$STATE/pods"; }
app_sync() { awk -v n="$1" '$1 == n { print $3 }' "$STATE/apps"; }

# selfHeal: true is set on root and every child (argocd/root.yaml,
# argocd/apps/*.yaml), so ArgoCD puts back anything deleted out from under an
# Application whose automated sync is still on. Modelled on every stub call
# because the real controller reconciles continuously.
selfheal() {
  local ns name
  while read -r ns name; do
    [[ -n "${ns:-}" ]] || continue
    [[ "$(app_sync "$ns")" == auto ]] || continue
    [[ "$(pods_state "$ns")" == alive ]] || continue
    grep -qxF "$ns $name" "$STATE/ingresses" && continue
    printf '%s %s\n' "$ns" "$name" >>"$STATE/ingresses"
    cat "$STATE/albs.desired" >"$STATE/albs"
    cat "$STATE/targetgroups.desired" >"$STATE/targetgroups"
  done <"$STATE/ingresses.desired"
}

# Recompute what Kubernetes/AWS would do on their own after any mutation.
reconcile() {
  local ns name vol st fin out=""
  while read -r ns name vol st fin; do
    [[ -n "${ns:-}" ]] || continue
    if [[ "$st" == deleting && "$(pods_state "$ns")" == gone ]]; then
      if [[ "$fin" == normal ]]; then
        # ebs-csi-driver releases the claim and deletes the volume. It is a
        # Terraform EKS addon, not an ArgoCD Application, so it survives the
        # cascade and still gets to make this call.
        drop_line volumes 1 "$vol"
        continue
      fi
      # Finalizer stuck: the claim never goes, and the volume is detached but
      # never deleted. #122's second shape.
      set_field volumes "$vol" 2 available
    fi
    out+="$ns $name $vol $st $fin"$'\n'
  done <"$STATE/pvcs"
  printf '%s' "$out" >"$STATE/pvcs"
}
FAKELIB

cat >"$BIN/kubectl" <<'KUBECTL'
#!/usr/bin/env bash
source "$(dirname "$0")/fakelib.sh"
log "kubectl $*"
selfheal
verb="$1"; kind="${2:-}"; shift 2 2>/dev/null || true
ns="$(argval -n "$@" || true)"
name="${1:-}"
[[ "$name" == -* ]] && name=""
# `kubectl patch application.argoproj.io/root` -- the form `kubectl get -o name`
# emits and freeze_argocd_sync feeds straight back in.
if [[ "$kind" == */* ]]; then name="${kind#*/}"; kind="${kind%%.*}"; fi

case "$verb:$kind" in
  get:ingress)
    awk -v n="$ns" '$1 == n { print $1, $2 }' "$STATE/ingresses" ;;
  get:pvc|get:persistentvolumeclaim)
    awk '{ print $1, $2, "Bound" }' "$STATE/pvcs" ;;
  get:application|get:applications)
    if [[ -n "$name" ]]; then
      grep -qE "^$name " "$STATE/apps" || exit 1
      printf '%s\n' "$name"
    elif [[ "$(argval -o "$@" || true)" == name ]]; then
      awk '{ print "application.argoproj.io/" $1 }' "$STATE/apps"
    else
      cut -d' ' -f1 "$STATE/apps"
    fi ;;
  get:svc) printf '{"items":[]}\n' ;;

  delete:ingress)
    if [[ "$(cat "$STATE/controller")" == alive ]]; then
      # The controller sees the deletion, tears down the ALB and its target
      # groups, and only then releases ingress.k8s.aws/resources.
      drop_line ingresses 2 "$name"
      : >"$STATE/albs"; : >"$STATE/targetgroups"
    fi
    # Controller gone: the object stays, finalizer unreleased, ALB intact.
    ;;
  patch:ingress)
    anyarg '"finalizers":[]' "$@" && drop_line ingresses 2 "$name" ;;

  delete:pvc|delete:persistentvolumeclaim)
    set_field pvcs "$ns" 4 deleting
    awk -v n="$ns" -v p="$name" '$1 == n && $2 == p { $4 = "deleting" } { print }' \
      "$STATE/pvcs" >"$STATE/pvcs.tmp" && mv "$STATE/pvcs.tmp" "$STATE/pvcs"
    reconcile ;;
  patch:pvc|patch:persistentvolumeclaim)
    if anyarg '"finalizers":[]' "$@"; then
      awk -v n="$ns" -v p="$name" '!($1 == n && $2 == p)' "$STATE/pvcs" >"$STATE/pvcs.tmp" \
        && mv "$STATE/pvcs.tmp" "$STATE/pvcs"
      # The claim is gone but the volume is not: nothing called DeleteVolume.
    fi ;;

  patch:application)
    anyarg 'resources-finalizer' "$@" && set_field apps "$name" 2 cascade
    anyarg '"syncPolicy":null' "$@" && set_field apps "$name" 3 frozen ;;
  delete:application)
    if [[ "$name" == root ]]; then
      # Root's cascade prunes every child Application object. alb-controller
      # has no cascade finalizer of its own, but it goes with the cluster's
      # Helm release either way -- which is the exact window #122 fell into.
      printf 'dead\n' >"$STATE/controller"
      while read -r app fin _rest; do
        [[ -n "${app:-}" ]] || continue
        [[ "$fin" == cascade ]] && printf '%s gone\n' "$app" >>"$STATE/pods.new"
      done <"$STATE/apps"
      if [[ -f "$STATE/pods.new" ]]; then
        while read -r app _; do set_field pods "$app" 2 gone; done <"$STATE/pods.new"
        rm -f "$STATE/pods.new"
      fi
      : >"$STATE/apps"
    else
      drop_line apps 1 "$name"
    fi
    reconcile ;;
esac
exit 0
KUBECTL

cat >"$BIN/aws" <<'AWSSTUB'
#!/usr/bin/env bash
source "$(dirname "$0")/fakelib.sh"
log "aws $*"
selfheal
svc="$1"; op="$2"; shift 2

statuses_match() {  # statuses_match WANTED-CSV STATUS
  [[ ",$1," == *",$2,"* ]]
}

case "$svc:$op" in
  eks:describe-cluster) [[ "$(cat "$STATE/cluster")" == up ]] || exit 1 ;;
  eks:update-kubeconfig) : ;;

  elbv2:describe-load-balancers) wc -l <"$STATE/albs" | tr -d ' ' ;;
  elbv2:delete-load-balancer)
    arn="$(argval --load-balancer-arn "$@")"
    grep -qxF "$arn" "$STATE/undeletable" && exit 1
    drop_line albs 1 "$arn" ;;
  elbv2:delete-target-group)
    drop_line targetgroups 1 "$(argval --target-group-arn "$@")" ;;

  resourcegroupstaggingapi:get-resources)
    if anyarg 'elasticloadbalancing:loadbalancer' "$@"; then cat "$STATE/albs"
    else cat "$STATE/targetgroups"; fi ;;

  ec2:describe-volumes)
    want="$(argval "Name=status,Values" "$@" || true)"
    # The filters arrive as positional "Name=...,Values=..." strings.
    want=""; kind=""
    for a in "$@"; do
      [[ "$a" == Name=status,Values=* ]] && want="${a#*Values=}"
      [[ "$a" == Name=tag:KubernetesCluster,* ]] && kind=legacy
      [[ "$a" == Name=tag-key,Values=CSIVolumeName ]] && kind=csi
    done
    while read -r id st tag; do
      [[ -n "${id:-}" ]] || continue
      statuses_match "$want" "$st" || continue
      [[ "$tag" == "$kind" ]] || continue
      printf '%s\n' "$id"
    done <"$STATE/volumes" ;;
  ec2:delete-volume)
    id="$(argval --volume-id "$@")"
    # AWS refuses to delete an attached volume; the stub must too, or a test
    # could pass on behaviour the real API would reject.
    [[ "$(awk -v i="$id" '$1 == i { print $2 }' "$STATE/volumes")" == available ]] || exit 1
    drop_line volumes 1 "$id" ;;

  ec2:describe-vpcs) awk '{ print $1 }' "$STATE/vpcs" ;;
  ec2:delete-vpc)
    vpc="$(argval --vpc-id "$@")"
    if awk -v v="$vpc" '$3 == v && $2 ~ /^k8s-/' "$STATE/sgs" | grep -q .; then
      echo "An error occurred (DependencyViolation): The vpc '$vpc' has dependencies and cannot be deleted." >&2
      exit 1
    fi
    drop_line vpcs 1 "$vpc" ;;

  ec2:describe-security-groups)
    tag=""; vpc=""; prefix=""
    for a in "$@"; do
      [[ "$a" == Name=tag:elbv2.k8s.aws/cluster,* ]] && tag=tagged
      [[ "$a" == Name=vpc-id,Values=* ]] && vpc="${a#*Values=}"
      [[ "$a" == Name=group-name,Values=* ]] && prefix="${a#*Values=}"
    done
    while read -r id gname gvpc gtag; do
      [[ -n "${id:-}" ]] || continue
      if [[ -n "$tag" ]]; then
        [[ "$gtag" == tagged ]] && printf '%s\n' "$id"
      else
        [[ "$gvpc" == "$vpc" ]] || continue
        [[ "$gname" == ${prefix%\*}* ]] || continue
        printf '%s\n' "$id"
      fi
    done <"$STATE/sgs" ;;
  ec2:describe-security-group-rules)
    ref=""
    for a in "$@"; do [[ "$a" == Name=referenced-group-id,Values=* ]] && ref="${a#*Values=}"; done
    awk -v r="$ref" '$4 == r { print $2 "\t" $1 "\t" $3 }' "$STATE/sgrules" ;;
  ec2:revoke-security-group-ingress|ec2:revoke-security-group-egress)
    drop_line sgrules 1 "$(argval --security-group-rule-ids "$@")" ;;
  ec2:delete-security-group)
    sg="$(argval --group-id "$@")"
    if awk -v s="$sg" '$4 == s' "$STATE/sgrules" | grep -q .; then
      echo "An error occurred (DependencyViolation): resource $sg has a dependent object" >&2
      exit 1
    fi
    drop_line sgs 1 "$sg" ;;
esac
exit 0
AWSSTUB

cat >"$BIN/tofu" <<'TOFU'
#!/usr/bin/env bash
source "$(dirname "$0")/fakelib.sh"
log "tofu $*"
for a in "$@"; do
  case "$a" in
    state) op=state ;;
    destroy) op=destroy ;;
    init) op=init ;;
  esac
done
case "${op:-}" in
  init) ;;
  state)
    printf '%s\n' aws_s3_bucket.tfstate aws_s3_bucket_versioning.tfstate \
      aws_s3_bucket_server_side_encryption_configuration.tfstate \
      aws_s3_bucket_public_access_block.tfstate
    [[ -s "$STATE/vpcs" ]] && printf 'aws_vpc.main\n' ;;
  destroy)
    # Terminating the nodes is what detaches any volume still in use.
    awk '{ print $1, "gone" }' "$STATE/pods" >"$STATE/pods.tmp" && mv "$STATE/pods.tmp" "$STATE/pods"
    while read -r id st tag; do
      [[ "${st:-}" == in-use ]] && set_field volumes "$id" 2 available
    done <"$STATE/volumes"
    vpc="$(awk 'NR == 1 { print $1 }' "$STATE/vpcs")"
    if [[ -n "$vpc" ]]; then
      "$(dirname "$0")/aws" ec2 delete-vpc --vpc-id "$vpc" || exit 1
    fi ;;
esac
exit 0
TOFU

chmod +x "$BIN/kubectl" "$BIN/aws" "$BIN/tofu"

# --- scenario plumbing ------------------------------------------------------

failures=0
STATE=""

# new_state: a stack with both Airflow environments up, one shared admin ALB,
# four CSI gp3 volumes behind PVCs, and the controller's two security groups.
# This is the shape #122 was found on.
new_state() {
  STATE="$WORK/state.$RANDOM"
  mkdir -p "$STATE"
  printf 'up\n' >"$STATE/cluster"
  printf 'alive\n' >"$STATE/controller"
  cat >"$STATE/ingresses" <<'EOF'
airflow airflow-ingress
airflow-staging airflow-staging-ingress
argocd argocd-server
EOF
  printf 'arn:aws:elasticloadbalancing:::loadbalancer/app/k8s-steaminfraadmin/abc\n' >"$STATE/albs"
  printf 'arn:aws:elasticloadbalancing:::targetgroup/k8s-airflow/def\n' >"$STATE/targetgroups"
  cat >"$STATE/volumes" <<'EOF'
vol-airflow-logs in-use csi
vol-airflow-redis in-use csi
vol-staging-logs in-use csi
vol-staging-redis in-use csi
EOF
  cat >"$STATE/sgs" <<'EOF'
sg-frontend k8s-steaminfraadmin-1a2b vpc-steam tagged
sg-backend k8s-traffic-steaminfra-3c4d vpc-steam tagged
EOF
  # The controller's ingress rule on the node group pointing back at the ALB
  # group: the thing that makes DeleteSecurityGroup fail until it is revoked.
  printf 'sgr-1 sg-nodes False sg-frontend\n' >"$STATE/sgrules"
  cat >"$STATE/apps" <<'EOF'
root none auto
argocd none auto
alb-controller none auto
airflow-storageclass none auto
airflow none auto
airflow-staging none auto
connectors none auto
kafka-cluster none auto
kafka-connect none auto
strimzi-operator none auto
EOF
  cat >"$STATE/pvcs" <<'EOF'
airflow logs-airflow-worker-0 vol-airflow-logs bound normal
airflow redis-db-airflow-redis-0 vol-airflow-redis bound normal
airflow-staging logs-airflow-staging-worker-0 vol-staging-logs bound normal
airflow-staging redis-db-airflow-staging-redis-0 vol-staging-redis bound normal
EOF
  cat >"$STATE/pods" <<'EOF'
argocd alive
airflow alive
airflow-staging alive
connectors alive
kafka-cluster alive
kafka-connect alive
strimzi-operator alive
EOF
  cp "$STATE/ingresses" "$STATE/ingresses.desired"
  cp "$STATE/albs" "$STATE/albs.desired"
  cp "$STATE/targetgroups" "$STATE/targetgroups.desired"
  printf 'vpc-steam steam-infra\n' >"$STATE/vpcs"
  : >"$STATE/undeletable"
  : >"$STATE/log"
}

run_stage() {  # run_stage 02-argocd|05-tofu-destroy -> captures output, returns status
  local out status
  out=$(
    PATH="$BIN:$PATH" FAKE_STATE="$STATE" \
      TEARDOWN_DRAIN_TIMEOUT=1 TEARDOWN_CLEANUP_TIMEOUT=1 \
      TEARDOWN_ESCALATED_TIMEOUT=1 TEARDOWN_POLL_INTERVAL=1 \
      bash "$REPO_ROOT/scripts/teardown/stages/$1.sh" 2>&1
  )
  status=$?
  printf '%s' "$out" >"$STATE/out"
  return $status
}

check() {  # check "assertion name" expected actual
  if [[ "$2" == "$3" ]]; then
    printf '  ok    %s\n' "$1"
  else
    printf '  FAIL  %s — expected %q, got %q\n' "$1" "$2" "$3"
    printf '%s\n' "--- stage output ---" "$(cat "$STATE/out")" "---" | sed 's/^/        /'
    failures=$((failures + 1))
  fi
}

count() { wc -l <"$STATE/$1" | tr -d ' '; }
logged() { grep -qF -e "$1" "$STATE/log" && echo yes || echo no; }
# before A B: does the first line matching A come before the first matching B?
before() {
  local a b
  a=$(grep -nF -m1 -e "$1" "$STATE/log" | cut -d: -f1)
  b=$(grep -nF -m1 -e "$2" "$STATE/log" | cut -d: -f1)
  [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]] && echo yes || echo no
}
scenario() { printf '\n%s\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. The stack #122 was found on, torn down unattended.
# ---------------------------------------------------------------------------
scenario "1. both Airflow environments: teardown reaches zero with no escalation"
new_state
run_stage 02-argocd; check "stage 2 exits 0" 0 $?
check "no ALBs left" 0 "$(count albs)"
check "no EBS volumes left" 0 "$(count volumes)"
check "no alb-controller security groups left" 0 "$(count sgs)"
check "no PVCs left" 0 "$(count pvcs)"
# If this goes yes, the happy path is only working via the escalation, which
# would hide a regression in the ordering.
check "did not need to delete an ALB directly" no "$(logged 'elbv2 delete-load-balancer')"
check "did not need to clear any finalizer" no "$(logged '"finalizers":[]')"

# ---------------------------------------------------------------------------
# 2. The ordering invariant itself. This is the assertion #122 is about.
# ---------------------------------------------------------------------------
scenario "2. staging's Ingress is deleted before the cascade takes alb-controller"
new_state
run_stage 02-argocd; check "stage 2 exits 0" 0 $?
check "staging's Ingress deleted before root" yes \
  "$(before 'delete ingress airflow-staging-ingress' 'delete application root')"
check "prod's Ingress deleted before root" yes \
  "$(before 'delete ingress airflow-ingress' 'delete application root')"
check "argocd's own Ingress deleted before root" yes \
  "$(before 'delete ingress argocd-server' 'delete application root')"
check "the ALB was confirmed gone before root was deleted" yes \
  "$(before 'elbv2 describe-load-balancers' 'delete application root')"

# ---------------------------------------------------------------------------
# 3. The Ingress whose finalizer is never released, because the controller is
#    already gone. The literal #122 failure, and the one the dead-man's switch
#    could not recover from.
# ---------------------------------------------------------------------------
scenario "3. alb-controller already dead: finalizer never releases, must self-heal"
new_state
printf 'dead\n' >"$STATE/controller"
run_stage 02-argocd; check "stage 2 still exits 0" 0 $?
check "the ALB is gone" 0 "$(count albs)"
check "its target groups are gone" 0 "$(count targetgroups)"
check "escalated to deleting the ALB directly" yes "$(logged 'elbv2 delete-load-balancer')"
check "escalated to clearing the Ingress finalizer" yes \
  "$(logged 'patch ingress airflow-staging-ingress')"
check "no Ingresses left" 0 "$(count ingresses)"

# ---------------------------------------------------------------------------
# 4. A PVC holding its EBS volume in-use.
# ---------------------------------------------------------------------------
scenario "4. PVCs hold their EBS volumes in-use until the cascade releases them"
new_state
run_stage 02-argocd; check "stage 2 exits 0" 0 $?
check "all four CSI volumes are gone" 0 "$(count volumes)"
check "PVC deletion was requested before the cascade" yes \
  "$(before 'delete pvc logs-airflow-staging-worker-0' 'delete application root')"
check "no volume had to be deleted directly" no "$(logged 'ec2 delete-volume')"

scenario "5. a PVC whose finalizer never releases: volume detaches but survives"
new_state
# pvc-protection stuck on staging's worker-logs claim, exactly the pair named
# in #122 (logs-airflow-staging-worker-0, redis-db-airflow-staging-redis-0).
sed -i.bak 's/^airflow-staging logs-airflow-staging-worker-0 \(.*\) normal$/airflow-staging logs-airflow-staging-worker-0 \1 stuck/' "$STATE/pvcs"
run_stage 02-argocd; check "stage 2 still exits 0" 0 $?
check "the stranded volume was swept" 0 "$(count volumes)"
check "escalated to clearing the PVC finalizer" yes \
  "$(logged 'patch persistentvolumeclaim logs-airflow-staging-worker-0')"
check "and deleted the volume directly" yes "$(logged 'ec2 delete-volume')"

# ---------------------------------------------------------------------------
# 6. The out-of-state resources: CSI volumes and the controller's own SGs.
# ---------------------------------------------------------------------------
scenario "6. CSI gp3 volumes tofu destroy does not own are swept after it"
new_state
printf 'gone\n' >"$STATE/cluster"      # cluster already destroyed
: >"$STATE/ingresses"; : >"$STATE/albs"; : >"$STATE/targetgroups"; : >"$STATE/pvcs"; : >"$STATE/apps"
cat >"$STATE/volumes" <<'EOF'
vol-orphan-1 available csi
vol-orphan-2 available csi
vol-orphan-3 available csi
vol-orphan-4 available csi
EOF
run_stage 05-tofu-destroy; check "stage 5 exits 0" 0 $?
check "all four orphaned volumes deleted" 0 "$(count volumes)"
check "the VPC was deleted" 0 "$(count vpcs)"

scenario "7. DeleteVpc fails with DependencyViolation until the SGs are swept"
new_state
printf 'gone\n' >"$STATE/cluster"
: >"$STATE/ingresses"; : >"$STATE/albs"; : >"$STATE/targetgroups"; : >"$STATE/pvcs"; : >"$STATE/apps"; : >"$STATE/volumes"
run_stage 05-tofu-destroy; check "stage 5 exits 0" 0 $?
check "both controller security groups deleted" 0 "$(count sgs)"
check "the node-group rule referencing the ALB group was revoked first" yes \
  "$(before 'revoke-security-group-ingress' '--group-id sg-frontend')"
check "the VPC was deleted" 0 "$(count vpcs)"

# Scenario 7 is only worth anything if DeleteVpc genuinely fails while those
# security groups exist -- otherwise it would pass with no sweep at all. Assert
# the failure directly, so a stub that quietly stopped modelling
# DependencyViolation shows up here rather than as a false green above.
scenario "8. DeleteVpc really does fail while the controller's SGs exist"
new_state
out=$(PATH="$BIN:$PATH" FAKE_STATE="$STATE" aws ec2 delete-vpc --vpc-id vpc-steam 2>&1)
check "delete-vpc exits non-zero" 1 $?
check "with DependencyViolation" yes \
  "$(grep -q DependencyViolation <<<"$out" && echo yes || echo no)"
check "and the VPC is still there" 1 "$(count vpcs)"
# tofu destroy is the caller that fails on it, which is how #122 surfaced.
PATH="$BIN:$PATH" FAKE_STATE="$STATE" tofu -chdir=. destroy -auto-approve >/dev/null 2>&1
check "tofu destroy fails too" 1 $?

# ---------------------------------------------------------------------------
# 9. Blast radius.
# ---------------------------------------------------------------------------
scenario "9. nothing outside this project's stack is touched"
new_state
printf 'sg-elsewhere prod-web vpc-other untagged\n' >>"$STATE/sgs"
printf 'vol-someone-else available none\n' >>"$STATE/volumes"
printf 'sgr-9 sg-elsewhere False sg-elsewhere\n' >>"$STATE/sgrules"
run_stage 02-argocd; check "stage 2 exits 0" 0 $?
check "the unrelated security group survives" yes \
  "$(grep -qF sg-elsewhere "$STATE/sgs" && echo yes || echo no)"
check "the unrelated EBS volume survives" yes \
  "$(grep -qF vol-someone-else "$STATE/volumes" && echo yes || echo no)"
check "the unrelated SG's rule was not revoked" yes \
  "$(grep -qF sgr-9 "$STATE/sgrules" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 10. The timeout path, when escalation itself cannot finish. The guard must
#     still refuse to claim $0 -- #122's dead-man's switch was *right* to say
#     "may still be billing"; the defect was that it had nothing left to try.
# ---------------------------------------------------------------------------
scenario "10. escalation cannot delete the ALB: must fail honestly, never claim \$0"
new_state
printf 'dead\n' >"$STATE/controller"
cat "$STATE/albs" >"$STATE/undeletable"
run_stage 02-argocd
check "stage 2 exits 1" 1 $?
check "says the stack may still be billing" yes \
  "$(grep -qF 'MANUAL CHECK REQUIRED' "$STATE/out" && echo yes || echo no)"
check "and it did try the escalation first" yes "$(logged 'elbv2 delete-load-balancer')"

# ---------------------------------------------------------------------------
# 11. selfHeal. Not in #122's write-up, and the fix does not work without it:
#     every Application carries selfHeal: true, so a directly-deleted Ingress
#     is recreated and brings its ALB back, and no amount of waiting would
#     ever reach zero.
# ---------------------------------------------------------------------------
scenario "11. selfHeal puts a deleted Ingress (and its ALB) straight back"
new_state
# Hand-deleted with automated sync still on, which is what happens if the
# freeze step is dropped.
PATH="$BIN:$PATH" FAKE_STATE="$STATE" kubectl delete ingress airflow-staging-ingress -n airflow-staging
check "the Ingress was deleted" 0 \
  "$(grep -c airflow-staging-ingress "$STATE/ingresses")"
PATH="$BIN:$PATH" FAKE_STATE="$STATE" kubectl get ingress -n airflow-staging >/dev/null
check "ArgoCD recreated it" 1 "$(grep -c airflow-staging-ingress "$STATE/ingresses")"
check "and the ALB is back" 1 "$(count albs)"

scenario "12. the stage freezes automated sync before deleting anything"
new_state
run_stage 02-argocd; check "stage 2 exits 0" 0 $?
check "root's automated sync was disabled before any Ingress was deleted" yes \
  "$(before 'patch application.argoproj.io/root' 'delete ingress')"
for app in argocd alb-controller airflow airflow-staging connectors; do
  check "  $app was frozen too" yes "$(logged "patch application.argoproj.io/$app")"
done

if ((failures)); then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall assertions held\n'
