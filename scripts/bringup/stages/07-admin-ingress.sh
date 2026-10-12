#!/usr/bin/env bash
# Stage 7: admin ingress. Waits for the AWS Load Balancer Controller
# (#107) to populate the shared ALB's hostname on the Airflow Ingress, then
# starts the SSM tunnel to it (#108) in the background and prints the
# clickable Airflow/Argo CD links. Deliberately does not `trap ... EXIT` or
# close the tunnel before this script exits — unlike Stage 4's RDS tunnel,
# this one is meant to keep running after bring-up finishes; Stage 2 of
# teardown (#110) is what stops it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/tunnel.sh
source "$REPO_ROOT/scripts/lib/tunnel.sh"

stage 7 "Admin ingress"

TUNNEL_PID_FILE="$LOG_DIR/admin-alb-tunnel.pid"

BASTION_ID=$(tf output -raw bastion_instance_id 2>/dev/null || true)
[[ -n "$BASTION_ID" ]] || fail "missing bastion_instance_id output — did Stage 3 (AWS) run?"

# Every Airflow environment's api-server Ingress, as "NAMESPACE PATH". The
# chart names the Ingress <release>-ingress and argocd/apps uses the release
# name as the namespace, so both are the environment's name.
#
# Looked up by name rather than `{.items[0]}`: there is more than one Airflow
# now, and an order-dependent pick over every Ingress in a namespace would
# start reporting an arbitrary one of them without failing.
#
# All of them are members of one IngressGroup and so share one ALB, but each
# is waited on separately: a member whose rule never made it onto the ALB —
# the failure mode of a wrong exclusive annotation or a bad path — leaves that
# environment with no hostname while the others look fine.
AIRFLOW_INGRESSES=(
  "airflow /airflow"
  "airflow-staging /airflow-staging"
)

nstep 1 "waiting for the ALB hostname on every Airflow Ingress..."
ALB_HOST=""
for entry in "${AIRFLOW_INGRESSES[@]}"; do
  read -r ns _path <<<"$entry"
  host=""
  deadline=$((SECONDS + 300))
  until [[ -n "$host" ]]; do
    host=$(kubectl get ingress "$ns-ingress" -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
    [[ -n "$host" ]] && break
    (( SECONDS < deadline )) || fail "ALB hostname never appeared on Ingress $ns-ingress in namespace $ns"
    sleep 10
  done
  # One shared ALB via group.name, so a second hostname means the group split
  # — which it does when a member disagrees on an exclusive annotation like
  # `scheme`. Two ALBs is also two bills and only one of them is tunnelled to.
  [[ -z "$ALB_HOST" || "$host" == "$ALB_HOST" ]] \
    || fail "Airflow Ingresses landed on different ALBs ($ALB_HOST vs $host) — they must share the steam-infra-admin IngressGroup; check the exclusive annotations in k8s/airflow/values.yaml"
  ALB_HOST="$host"
  nbullet "$ns-ingress: $host"
done
ok "ALB hostname: $ALB_HOST"

nstep 2 "starting the SSM tunnel in the background..."
open_alb_tunnel "$BASTION_ID" "$ALB_HOST" || fail "tunnel never came up"
disown "$_TUNNEL_PID" 2>/dev/null || true
echo "$_TUNNEL_PID" >"$TUNNEL_PID_FILE"
ok "tunnel running (pid $_TUNNEL_PID, $TUNNEL_PID_FILE)"

printf '\n'
for entry in "${AIRFLOW_INGRESSES[@]}"; do
  read -r _ns path <<<"$entry"
  printf '     %s%shttp://localhost:8888%s%s\n' "$BOLD" "$GREEN" "$path" "$RESET"
done
printf '     %s%shttp://localhost:8888/argocd%s\n' "$BOLD" "$GREEN" "$RESET"
