#!/usr/bin/env bash
# Stage 4/5: cluster. Point kubectl at EKS -> install ArgoCD via helm at the
# chart version pinned in argocd/apps/argocd.yaml (skip if already installed,
# so ArgoCD adopts its own Helm release cleanly once root syncs that
# Application) -> create/refresh every hand-made secret (idempotent) -> apply
# the root Application. Verify: every Application Synced+Healthy, Kafka
# Ready, KafkaConnect Ready, both connectors + their tasks RUNNING (this
# replaces scripts/check-connector-health.sh as the source of truth), Airflow
# scheduler + webserver ready.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/output.sh
source "$REPO_ROOT/lib/output.sh"
# shellcheck source=lib/env.sh
source "$REPO_ROOT/lib/env.sh"

stage 4 5 "Cluster"

# Every Application the root app-of-apps (argocd/apps) is expected to bring
# up. Kept as one list so "all healthy" and "count matches" can't drift.
EXPECTED_APPS=(root argocd airflow airflow-storageclass connectors kafka-cluster kafka-connect strimzi-operator)

CONNECT_POD="steam-infra-connect-0"
CONNECTORS=(debezium-postgres-source snowflake-sink)

deployment_ready() {
  local ns="$1" name="$2" ready total
  ready=$(kubectl get deployment "$name" -n "$ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  total=$(kubectl get deployment "$name" -n "$ns" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
  [[ -n "$ready" && -n "$total" && "$ready" == "$total" ]]
}

crd_ready() {
  local kind="$1" name="$2" ns="$3"
  [[ "$(kubectl get "$kind" "$name" -n "$ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)" == "True" ]]
}

connectors_running() {
  local connector status http_code body state bad_tasks
  for connector in "${CONNECTORS[@]}"; do
    status=$(kubectl exec -n kafka "$CONNECT_POD" -- \
      curl -s -w '\n%{http_code}' "localhost:8083/connectors/$connector/status" 2>/dev/null) || return 1
    http_code=$(tail -n1 <<<"$status")
    body=$(sed '$d' <<<"$status")
    [[ "$http_code" == "200" ]] || return 1
    state=$(jq -r '.connector.state' <<<"$body")
    [[ "$state" == "RUNNING" ]] || return 1
    bad_tasks=$(jq -r '.tasks[] | select(.state != "RUNNING")' <<<"$body")
    [[ -z "$bad_tasks" ]] || return 1
  done
  return 0
}

apps_synced_and_healthy() {
  local app status health
  for app in "${EXPECTED_APPS[@]}"; do
    status=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    [[ "$status" == "Synced" && "$health" == "Healthy" ]] || return 1
  done
  return 0
}

nstep 1 "pointing kubectl at the EKS cluster..."
run_step "update kubeconfig" aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"

nstep 2 "installing ArgoCD..."
if kubectl get deployment argocd-server -n argocd >/dev/null 2>&1; then
  ok "ArgoCD already installed"
else
  argocd_chart_version=$(grep 'targetRevision:' "$REPO_ROOT/argocd/apps/argocd.yaml" | awk '{print $2}')
  [[ -n "$argocd_chart_version" ]] || fail "couldn't read ArgoCD chart version from argocd/apps/argocd.yaml"
  run_step "helm repo add argo" helm repo add argo https://argoproj.github.io/argo-helm --force-update
  run_step "helm repo update argo" helm repo update argo
  run_step "helm install argocd $argocd_chart_version" helm upgrade --install argocd argo/argo-cd \
    --version "$argocd_chart_version" -n argocd --create-namespace
  run_step "wait for argocd-server" kubectl rollout status deployment/argocd-server -n argocd --timeout=300s
  ok "ArgoCD $argocd_chart_version installed"
fi

nstep 3 "creating/refreshing secrets..."
kubectl create namespace kafka --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace airflow --dry-run=client -o yaml | kubectl apply -f - >/dev/null

DB_USERNAME=$(tf output -raw db_username)
DB_PASSWORD=$(tf output -raw db_password)
[[ -n "$DB_USERNAME" && -n "$DB_PASSWORD" ]] || fail "missing db_username/db_password outputs — did Stage 2 (AWS) run?"
kubectl create secret generic rds-credentials -n kafka \
  --from-literal=username="$DB_USERNAME" --from-literal=password="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "rds-credentials (kafka)"

PRIVATE_KEY_STRIPPED=$(grep -v '^-----' "$SNOWFLAKE_PRIVATE_KEY_PATH" | tr -d '\n')
for ns in kafka airflow; do
  kubectl create secret generic snowflake-keypair -n "$ns" \
    --from-literal=private_key="$PRIVATE_KEY_STRIPPED" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done
ok "snowflake-keypair (kafka, airflow)"

kubectl create secret generic snowflake-account -n kafka \
  --from-literal=account="$SNOWFLAKE_ACCOUNT" --from-literal=user="$SNOWFLAKE_USER" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic snowflake-account -n airflow \
  --from-literal=account="$SNOWFLAKE_ACCOUNT" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic snowflake-user -n airflow \
  --from-literal=user="$SNOWFLAKE_USER" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "snowflake-account (kafka, airflow), snowflake-user (airflow)"

kubectl create secret generic airflow-alert-email -n airflow \
  --from-literal=email="$AIRFLOW_ALERT_EMAIL" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "airflow-alert-email (airflow)"

# 12h-lived ECR login token, regenerated per session rather than stored in
# git (kafka-connect.yaml's header comment) — sessions here are short enough
# that this is accepted, not worked around.
ecr_repo=$(tf output -raw kafka_connect_ecr_repository_url)
kubectl create secret docker-registry ecr-registry-credentials -n kafka \
  --docker-server="${ecr_repo%%/*}" --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region "$AWS_REGION")" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "ecr-registry-credentials (kafka, 12h expiry)"

nstep 4 "applying the root Application..."
run_step "apply root Application" kubectl apply -f "$REPO_ROOT/argocd/root.yaml"

nstep 5 "verifying the CDC layer..."
nsub "waiting for every Application to be Synced and Healthy..."
deadline=$((SECONDS + 900))
until apps_synced_and_healthy; do
  (( SECONDS < deadline )) || fail "not every Application reached Synced+Healthy in time: ${EXPECTED_APPS[*]}"
  sleep 15
done
ok "all ${#EXPECTED_APPS[@]} Applications Synced and Healthy"

nsub "waiting for the Kafka cluster to be Ready..."
deadline=$((SECONDS + 600))
until crd_ready kafka steam-infra kafka; do
  (( SECONDS < deadline )) || fail "Kafka cluster never became Ready"
  sleep 10
done
ok "Kafka cluster Ready"

nsub "waiting for KafkaConnect to be Ready (in-cluster image build + push)..."
deadline=$((SECONDS + 900))
until crd_ready kafkaconnect steam-infra kafka; do
  (( SECONDS < deadline )) || fail "KafkaConnect never became Ready"
  sleep 15
done
ok "KafkaConnect Ready"

nsub "waiting for both connectors + tasks RUNNING..."
deadline=$((SECONDS + 300))
until connectors_running; do
  (( SECONDS < deadline )) || fail "connectors never all reached RUNNING: ${CONNECTORS[*]}"
  sleep 15
done
ok "connectors RUNNING: ${CONNECTORS[*]}"

nsub "waiting for Airflow scheduler + webserver ready..."
deadline=$((SECONDS + 600))
until deployment_ready airflow airflow-scheduler && deployment_ready airflow airflow-webserver; do
  (( SECONDS < deadline )) || fail "Airflow scheduler/webserver never became ready"
  sleep 15
done
ok "Airflow scheduler + webserver ready"
