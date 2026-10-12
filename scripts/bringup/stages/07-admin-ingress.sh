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

# The Airflow chart names its api-server Ingress <release>-ingress. Looked up
# by name rather than `{.items[0]}`: #119 adds a second Airflow, and an
# order-dependent pick over every Ingress in the namespace would start
# reporting an arbitrary one of them without failing.
AIRFLOW_INGRESS="airflow-ingress"

nstep 1 "waiting for the ALB hostname to be assigned..."
ALB_HOST=""
deadline=$((SECONDS + 300))
until [[ -n "$ALB_HOST" ]]; do
  ALB_HOST=$(kubectl get ingress "$AIRFLOW_INGRESS" -n airflow -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "$ALB_HOST" ]] && break
  (( SECONDS < deadline )) || fail "ALB hostname never appeared on Ingress $AIRFLOW_INGRESS in namespace airflow"
  sleep 10
done
ok "ALB hostname: $ALB_HOST"

nstep 2 "starting the SSM tunnel in the background..."
open_alb_tunnel "$BASTION_ID" "$ALB_HOST" || fail "tunnel never came up"
disown "$_TUNNEL_PID" 2>/dev/null || true
echo "$_TUNNEL_PID" >"$TUNNEL_PID_FILE"
ok "tunnel running (pid $_TUNNEL_PID, $TUNNEL_PID_FILE)"

printf '\n     %s%shttp://localhost:8888/airflow%s\n' "$BOLD" "$GREEN" "$RESET"
printf '     %s%shttp://localhost:8888/argocd%s\n' "$BOLD" "$GREEN" "$RESET"
