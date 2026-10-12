#!/usr/bin/env bash
# Stage 5: cluster. Point kubectl at EKS -> install ArgoCD via helm at the
# chart version pinned in argocd/apps/argocd.yaml (skip if already installed,
# so ArgoCD adopts its own Helm release cleanly once root syncs that
# Application) -> create/refresh every hand-made secret (idempotent) -> apply
# the root Application. Verify: every Application Synced+Healthy, Kafka
# Ready, KafkaConnect Ready, both connectors + their tasks RUNNING (the
# source of truth for that — #90 deleted the old
# scripts/check-connector-health.sh this replaced), and *every* Airflow
# environment's scheduler + api-server ready (the airflow chart here is
# Airflow 3, which renamed the webserver Deployment to api-server).
#
# There is more than one Airflow: prod in the `airflow` namespace and staging
# in `airflow-staging`, each its own Helm release with its own Secrets, its
# own metadata database and its own Snowflake service user. AIRFLOW_ENVS below
# is the single list driving all of that.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

stage 5 "Cluster"

# The Airflow environments, each mapped to the terraform/snowflake service
# user it runs dbt as. The key is the ArgoCD Application name, which the
# chart also uses as the Helm release name *and* which argocd/apps uses as the
# destination namespace — so it is simultaneously the namespace to create
# secrets in, the Application to wait for, and the prefix of the Deployments
# to health-check. One list, three uses, no third place to forget.
#
# Each environment gets its own namespace, its own Secrets and (via the
# chart's per-release Postgres) its own metadata database. Add an environment
# here and to k8s/airflow/values-<env>.yaml + argocd/apps/ together.
declare -A AIRFLOW_ENVS=(
  [airflow]=prod_airflow
  [airflow-staging]=staging_airflow
)

# Every Application the root app-of-apps (argocd/apps) is expected to bring
# up. Kept as one list so "all healthy" and "count matches" can't drift.
EXPECTED_APPS=(root argocd alb-controller airflow-storageclass connectors kafka-cluster kafka-connect strimzi-operator "${!AIRFLOW_ENVS[@]}")

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
for ns in "${!AIRFLOW_ENVS[@]}"; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
done

DB_USERNAME=$(tf output -raw db_username)
DB_PASSWORD=$(tf output -raw db_password)
[[ -n "$DB_USERNAME" && -n "$DB_PASSWORD" ]] || fail "missing db_username/db_password outputs — did Stage 3 (AWS) run?"
kubectl create secret generic rds-credentials -n kafka \
  --from-literal=username="$DB_USERNAME" --from-literal=password="$DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "rds-credentials (kafka)"

# Service-user credentials come from terraform/snowflake's sensitive outputs,
# never from .env: the operator's ACCOUNTADMIN key is a bootstrap identity and
# nothing in the pipeline authenticates with it any more (#114). The key pairs
# are regenerated by every apply, so these secrets rotate every session.
#
# The Kafka and Airflow namespaces get their key in two different encodings,
# because their consumers disagree:
#   - the Kafka Snowflake sink wants it on one line with the PEM header and
#     trailer stripped;
#   - dbt-snowflake wants the full PKCS#8 PEM, headers and newlines included,
#     and rejects anything else.
# Getting this wrong fails at DAG-run time, not here, so the two are built
# separately rather than shared.
#
# Each Airflow environment gets its *own* service user and key — a separate
# Snowflake identity that can be revoked on its own, and the other half of
# "staging is truly isolated from prod" (#112 story 22). The secret *names*
# are the same in every Airflow namespace, which is what lets the overlays'
# secretKeyRef blocks be byte-identical; only the contents differ.
run_step "tofu init (snowflake)" tf_snowflake init -input=false
LOADER_USER=$(sf_output loader_user)
LOADER_KEY=$(sf_output loader_private_key)

LOADER_KEY_STRIPPED=$(grep -v '^-----' <<<"$LOADER_KEY" | tr -d '\n')
[[ -n "$LOADER_KEY_STRIPPED" && "$LOADER_KEY_STRIPPED" != *-----* ]] \
  || fail "the loader key did not reduce to a header-free single line — the Kafka sink accepts no other form"

# The kafka and airflow secrets share a name but deliberately *not* a key, so
# a consumer wired to the wrong one fails to find it instead of silently
# reading an encoding it cannot parse.
kubectl create secret generic snowflake-keypair -n kafka \
  --from-literal=private_key="$LOADER_KEY_STRIPPED" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic snowflake-account -n kafka \
  --from-literal=account="$SNOWFLAKE_ACCOUNT" --from-literal=user="$LOADER_USER" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
ok "kafka: snowflake-keypair ($LOADER_USER, private_key stripped), snowflake-account"

for ns in "${!AIRFLOW_ENVS[@]}"; do
  identity="${AIRFLOW_ENVS[$ns]}"
  airflow_user=$(sf_output "${identity}_user")
  airflow_key=$(sf_output "${identity}_private_key")

  # Asserted rather than assumed: `private_key_pem_pkcs8` is what the module
  # outputs, but `private_key_pem` is PKCS#1 and one character away in the
  # .tf — and it would read fine here, then fail in dbt at DAG-run time.
  grep -q '^-----BEGIN PRIVATE KEY-----' <<<"$airflow_key" \
    || fail "${identity}_private_key is not PKCS#8 PEM — dbt-snowflake rejects PKCS#1 ('BEGIN RSA PRIVATE KEY') and headerless keys; check terraform/snowflake/outputs.tf uses private_key_pem_pkcs8"

  kubectl create secret generic snowflake-keypair -n "$ns" \
    --from-literal=private_key_pkcs8="$airflow_key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret generic snowflake-account -n "$ns" \
    --from-literal=account="$SNOWFLAKE_ACCOUNT" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret generic snowflake-user -n "$ns" \
    --from-literal=user="$airflow_user" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret generic airflow-alert-email -n "$ns" \
    --from-literal=email="$AIRFLOW_ALERT_EMAIL" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "$ns: snowflake-keypair ($airflow_user, private_key_pkcs8 PEM), snowflake-account, snowflake-user, airflow-alert-email"
done

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

# Per environment, because the chart names its Deployments after the release
# and each environment is its own release in its own namespace. Checked one
# environment at a time so the failure message names which one — "Airflow
# never became ready" with two of them is half a diagnosis.
for ns in "${!AIRFLOW_ENVS[@]}"; do
  nsub "waiting for $ns scheduler + api-server ready..."
  deadline=$((SECONDS + 600))
  until deployment_ready "$ns" "$ns-scheduler" && deployment_ready "$ns" "$ns-api-server"; do
    (( SECONDS < deadline )) || fail "$ns's scheduler/api-server never became ready"
    sleep 15
  done
  ok "$ns scheduler + api-server ready"
done
