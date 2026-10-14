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
# own metadata database and its own Snowflake service user. lib/env.sh's
# AIRFLOW_ENVIRONMENTS is the single list driving all of that.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=scripts/lib/output.sh
source "$REPO_ROOT/scripts/lib/output.sh"
# shellcheck source=scripts/lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"

stage 5 "Cluster"

# Which terraform/snowflake service user each Airflow environment runs dbt
# as. The environments themselves are lib/env.sh's AIRFLOW_ENVIRONMENTS — see
# that list for why one name is simultaneously the Application, the Helm
# release, the namespace and the URL prefix. This map holds only the part
# that is this stage's business.
#
# Each environment therefore gets its own namespace, its own Secrets, its own
# Snowflake identity and (via the chart's per-release Postgres) its own
# metadata database.
declare -A AIRFLOW_SNOWFLAKE_IDENTITY=(
  [airflow]=prod_airflow
  [airflow-staging]=staging_airflow
)

# rand_alnum N — N random [A-Za-z0-9] characters, for the plain-string
# Secrets (api-secret-key, jwt-secret, redis-password). Mirrors the chart's
# own `randAlphaNum` default so a pinned value looks like what it replaced.
rand_alnum() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }

# rand_fernet_key — 32 random bytes, URL-safe base64-encoded. That is
# exactly cryptography's Fernet.generate_key() (base64.urlsafe_b64encode of
# os.urandom(32)) and the only format Airflow's fernet_key config accepts;
# the chart's own generated default (`randAlphaNum 32`, alnum text) is not
# actually a valid Fernet key, which has never mattered because nothing has
# used it to encrypt a Connection (#118 Q7.10) -- get this one right anyway
# rather than carry the chart's shortcut forward into a value we control.
rand_fernet_key() { openssl rand -base64 32 | tr '+/' '-_'; }

# Every Application the root app-of-apps (argocd/apps) is expected to bring
# up. Checked in both directions — every name here must go Synced+Healthy,
# and report_unexpected_apps fails if argocd holds one that is not here.
EXPECTED_APPS=(root argocd alb-controller airflow-storageclass connectors kafka-cluster kafka-connect strimzi-operator "${AIRFLOW_ENVIRONMENTS[@]}")

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

# laggard_apps — the subset of EXPECTED_APPS that is not Synced+Healthy right
# now, "name(status/health)" each. Used only in the timeout failure message:
# #123 found that message naming *every* Application (nine of ten
# Synced/Healthy, one stuck) reads as a total ArgoCD collapse rather than one
# stuck release, which cost real diagnosis time. Re-queries rather than
# reusing apps_synced_and_healthy's last pass so the message reflects the
# state at the moment of failure, not an earlier iteration.
laggard_apps() {
  local app status health out=()
  for app in "${EXPECTED_APPS[@]}"; do
    status=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
    health=$(kubectl get application "$app" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)
    [[ "$status" == "Synced" && "$health" == "Healthy" ]] || out+=("$app(${status:-?}/${health:-?})")
  done
  printf '%s\n' "${out[*]}"
}

# The other direction: an Application the cluster has that EXPECTED_APPS does
# not. apps_synced_and_healthy only ever looks at the names it is given, so
# something added to argocd/apps and not to that list is never waited for and
# bring-up reports success without it — which is exactly how a half-deployed
# environment looks healthy. Reported once, after the wait, rather than as a
# wait condition: root creates the Applications, so during the wait a name
# can legitimately be present before this stage knows about it.
report_unexpected_apps() {
  local unexpected
  unexpected=$(comm -13 <(printf '%s\n' "${EXPECTED_APPS[@]}" | sort) \
    <(kubectl get applications -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null \
      | tr ' ' '\n' | grep -v '^$' | sort))
  [[ -z "$unexpected" ]] && return 0
  warn "Applications in argocd that this stage does not know about, so nothing waited for them: $(tr '\n' ' ' <<<"$unexpected")"
  note "add them to EXPECTED_APPS in this file (Airflow environments belong in lib/env.sh's AIRFLOW_ENVIRONMENTS instead)."
  return 1
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
for ns in "${AIRFLOW_ENVIRONMENTS[@]}"; do
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

for ns in "${AIRFLOW_ENVIRONMENTS[@]}"; do
  identity="${AIRFLOW_SNOWFLAKE_IDENTITY[$ns]:-}"
  # Named here rather than as sf_output's "no _user output" twenty minutes
  # into a bring-up: the two lists are in different files, so an environment
  # added to one and not the other is the likely mistake.
  [[ -n "$identity" ]] \
    || fail "no Snowflake service identity is mapped for the $ns Airflow environment — add it to AIRFLOW_SNOWFLAKE_IDENTITY in this file, with a matching service user in terraform/snowflake/identities.tf"
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

  # The five Secrets values.yaml pins (fernetKeySecretName etc, #123) --
  # unlike the Snowflake secrets above, created only if missing rather than
  # `apply`d every run. The Snowflake keys are *meant* to rotate every
  # bring-up because terraform/snowflake regenerates the key pair on every
  # apply regardless of what the k8s Secret holds; these are not tied to
  # any terraform output, so "apply unconditionally" would mean regenerating
  # them on every re-run of this stage, including a `--start-from 5` resume
  # against a cluster that is still up -- rotating the fernet/JWT/API/redis
  # values out from under pods that are already running on them, for no
  # reason (the thing #118 Q7.10 flagged as the actual cost of rotation).
  # Get-or-create makes them persist for the life of one cluster and rotate
  # only across a full bring-up/teardown cycle, which is when it is moot
  # anyway: teardown's tofu destroy removes the EKS cluster itself (not just
  # the namespace), so the next bring-up finds no Secret, no pod and no
  # metadata DB (chart Postgres PVC, also destroyed) to invalidate.
  if ! kubectl get secret fernet-key -n "$ns" >/dev/null 2>&1; then
    kubectl create secret generic fernet-key -n "$ns" --from-literal=fernet-key="$(rand_fernet_key)" >/dev/null
  fi
  if ! kubectl get secret api-secret-key -n "$ns" >/dev/null 2>&1; then
    kubectl create secret generic api-secret-key -n "$ns" --from-literal=api-secret-key="$(rand_alnum 32)" >/dev/null
  fi
  if ! kubectl get secret jwt-secret -n "$ns" >/dev/null 2>&1; then
    kubectl create secret generic jwt-secret -n "$ns" --from-literal=jwt-secret="$(rand_alnum 128)" >/dev/null
  fi
  # redis-password and broker-url must agree: the broker URL embeds the same
  # password the Celery workers authenticate to redis with (the chart's own
  # redis-secrets.yaml template does the same pairing). Generated together,
  # and both skipped once either exists, so a partial previous run can never
  # leave them holding two different passwords.
  if ! kubectl get secret redis-password -n "$ns" >/dev/null 2>&1 || ! kubectl get secret broker-url -n "$ns" >/dev/null 2>&1; then
    redis_password=$(rand_alnum 24)
    kubectl create secret generic redis-password -n "$ns" --from-literal=password="$redis_password" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl create secret generic broker-url -n "$ns" \
      --from-literal=connection="redis://:${redis_password}@${ns}-redis:6379/0" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  fi
  ok "$ns: fernet-key, api-secret-key, jwt-secret, redis-password, broker-url"
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
  (( SECONDS < deadline )) || fail "Application(s) did not reach Synced+Healthy in time: $(laggard_apps)"
  sleep 15
done
report_unexpected_apps \
  || fail "every expected Application is Synced+Healthy, but argocd holds Applications this stage never checked — see above"
ok "all ${#EXPECTED_APPS[@]} Applications Synced and Healthy, and no others exist"

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
for ns in "${AIRFLOW_ENVIRONMENTS[@]}"; do
  nsub "waiting for $ns scheduler + api-server ready..."
  deadline=$((SECONDS + 600))
  until deployment_ready "$ns" "$ns-scheduler" && deployment_ready "$ns" "$ns-api-server"; do
    (( SECONDS < deadline )) || fail "$ns's scheduler/api-server never became ready"
    sleep 15
  done
  ok "$ns scheduler + api-server ready"
done
