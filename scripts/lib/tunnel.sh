#!/usr/bin/env bash
# The one SSM tunnel implementation — RDS and the internal admin ALB (#108)
# both have no public IP/DNS reachable off-VPC, so every script that needs
# either reaches it through the bastion the same way. Sourced by stage
# scripts — never run directly. Depends on lib/output.sh (warn) already
# being sourced.
#
# Callers: `trap tunnel_cleanup EXIT` right after sourcing this, then
# open_rds_tunnel "$BASTION_ID" "$RDS_HOST" / open_alb_tunnel "$BASTION_ID"
# "$ALB_HOST" ... close_rds_tunnel / close_alb_tunnel (or just let the trap
# fire on exit).

_TUNNEL_PID=""
_TUNNEL_LOG=""
_TUNNEL_LOCAL_PORT=""

tunnel_cleanup() {
  [[ -n "$_TUNNEL_PID" ]] && kill "$_TUNNEL_PID" 2>/dev/null || true
  # aws spawns session-manager-plugin as a child that outlives the `aws` pid
  # and keeps localPortNumber bound, breaking the next tunnel. Kill it by port.
  [[ -n "$_TUNNEL_LOCAL_PORT" ]] && pkill -f "localPortNumber.*$_TUNNEL_LOCAL_PORT" 2>/dev/null || true
  [[ -n "$_TUNNEL_LOG" ]] && rm -f "$_TUNNEL_LOG"
  # Always return 0: this runs as an EXIT trap, so its own exit status would
  # otherwise silently replace the script's real one (e.g. a call site that
  # already cleared _TUNNEL_LOG before `exit 0` would flip that 0 to 1).
  return 0
}

# open_tunnel BASTION_ID REMOTE_HOST REMOTE_PORT LOCAL_PORT forwards
# localhost:LOCAL_PORT -> REMOTE_HOST:REMOTE_PORT through the bastion over
# SSM. Polls the SSM CLI's own "Waiting for connections" line rather than
# sleeping a fixed amount — the SSM data-channel handshake routinely takes
# 30-40s on a fresh session — and retries a few times before giving up.
open_tunnel() {
  local bastion_id="$1" remote_host="$2" remote_port="$3" local_port="$4" attempt
  _TUNNEL_LOCAL_PORT="$local_port"
  for attempt in 1 2 3; do
    pkill -f "localPortNumber.*$local_port" 2>/dev/null || true
    _TUNNEL_LOG=$(mktemp)
    aws ssm start-session --target "$bastion_id" \
      --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters "{\"host\":[\"$remote_host\"],\"portNumber\":[\"$remote_port\"],\"localPortNumber\":[\"$local_port\"]}" \
      >"$_TUNNEL_LOG" 2>&1 &
    _TUNNEL_PID=$!
    for _ in $(seq 1 90); do
      grep -q "Waiting for connections" "$_TUNNEL_LOG" && return 0
      kill -0 "$_TUNNEL_PID" 2>/dev/null || break
      sleep 1
    done
    kill "$_TUNNEL_PID" 2>/dev/null || true
    warn "tunnel attempt $attempt/3 did not come up:"
    cat "$_TUNNEL_LOG" >&2
    rm -f "$_TUNNEL_LOG"
    sleep 5
  done
  warn "tunnel never came up after 3 attempts"
  return 1
}

close_tunnel() {
  tunnel_cleanup
  _TUNNEL_PID=""
  _TUNNEL_LOG=""
  _TUNNEL_LOCAL_PORT=""
}

# open_rds_tunnel BASTION_ID RDS_HOST forwards localhost:15432 -> RDS:5432.
open_rds_tunnel() { open_tunnel "$1" "$2" 5432 15432; }
close_rds_tunnel() { close_tunnel; }

# open_alb_tunnel BASTION_ID ALB_HOST forwards localhost:8888 -> ALB:80, for
# the internal admin ALB in front of Airflow/Argo CD (#107).
open_alb_tunnel() { open_tunnel "$1" "$2" 80 8888; }
close_alb_tunnel() { close_tunnel; }
