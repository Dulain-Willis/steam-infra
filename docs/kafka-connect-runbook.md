# Kafka Connect / Debezium connector runbook

Bring-up order for the CDC layer (EKS + Strimzi + Kafka + Connect +
connectors), on top of an already-applied RDS (`scripts/bootstrap.sh`,
`docs/rds-bootstrap.md`). Everything here is applied via `kubectl`, not
Terraform, per the IaC boundary (#28) — Terraform only owns EKS + the
Strimzi operator install (`terraform/eks.tf`, `terraform/strimzi.tf`).

## 1. Point kubectl at the cluster

```bash
aws eks update-kubeconfig --name steam-infra
```

## 2. RDS prerequisites

```bash
./scripts/check-rds-prereqs.sh
```

Verifies `rds.logical_replication=1` is actually in effect and
`steam_proj_admin` has `rds_replication` + `SELECT` on all 15 tables. Fails
with the exact fix (e.g. the missing `GRANT`) rather than letting a bad
connector config look like a new bug.

## 3. Kafka cluster

```bash
kubectl apply -f k8s/kafka/kafka-cluster.yaml
kubectl wait kafka/steam-infra -n kafka --for=condition=Ready --timeout=300s
```

## 4. Kafka Connect (build + deploy)

```bash
cd terraform
ECR_REPO=$(tofu output -raw kafka_connect_ecr_repository_url)
cd ..

kubectl create secret docker-registry ecr-registry-credentials -n kafka \
  --docker-server="${ECR_REPO%%/*}" \
  --docker-username=AWS \
  --docker-password="$(aws ecr get-login-password --region us-east-1)" \
  --dry-run=client -o yaml | kubectl apply -f -

sed "s|<account-id>.dkr.ecr.us-east-1.amazonaws.com/steam-infra-kafka-connect|$ECR_REPO|" \
  k8s/kafka/kafka-connect.yaml | kubectl apply -f -

kubectl wait kafkaconnect/steam-infra -n kafka --for=condition=Ready --timeout=600s
```

The build step compiles a plugin image and pushes it to ECR — the ECR login
token expires after 12h, so the registry Secret is regenerated per session
rather than committed.

## 5. Connector secrets

```bash
./scripts/create-connector-secrets.sh
```

Wires `rds-credentials` and `snowflake-keypair` into the `kafka` namespace
(see script header for the one-time Snowflake key-pair setup).

## 6. Debezium source connector

```bash
cd terraform
RDS_HOST=$(tofu output -raw rds_endpoint)
cd ..

sed "s|<rds-endpoint>|$RDS_HOST|" k8s/kafka/debezium-connector.yaml | kubectl apply -f -
```

## 7. Snowflake sink connector

```bash
kubectl apply -f k8s/kafka/snowflake-connector.yaml
```

Consumes the 15 `steam.public.*` Debezium topics directly and writes to
Snowflake via Snowpipe — no S3 or other landing zone (#34, #45).

## 8. Verify

Both connectors + all tasks `RUNNING` via the Connect REST API (fast signal —
checks before any data has to flow):

```bash
./scripts/check-connector-health.sh
```

Exits non-zero with the failing connector/task and state if anything isn't
`RUNNING` (#46).

Topics created for all 15 tables (`topic.prefix: steam` +
`schema.include.list: public`):

```bash
kubectl exec -n kafka steam-infra-dual-role-0 -c kafka -- \
  bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | grep ^steam\\.public\\.
```

Should list 15 topics, `steam.public.<table>` for each table in
`db/schema.sql`.

Snowflake tables receiving rows (each `steam.public.<table>` topic lands in
`STEAM_PROJECT.PUBLIC.<table>` per `snowflake.topic2table.map`):

```sql
select count(*) from steam_project.public.users;
```

## 9. End-to-end smoke test

Health checks above confirm the connectors are up, but not that data
actually flows. One command proves the whole pipeline end to end (#47):
writes a row to RDS via the same connection settings the generator uses,
then polls Snowflake until it's replicated or a bounded timeout elapses.

```bash
# through the SSM tunnel (docs/rds-bootstrap.md step 2), from repo root:
VENV=/tmp/steam-infra-smoke-venv
python3 -m venv "$VENV"
"$VENV/bin/pip" install -q -r scripts/requirements-smoke-test.txt

DB_HOST=localhost DB_PORT=15432 DB_NAME=steam DB_USER=steam_proj_admin \
DB_PASSWORD=$(cd terraform && tofu output -raw db_password) \
"$VENV/bin/python" scripts/smoke-test.py
```

Fails with a clear message (not a hang) on timeout, naming what to check
next in order: connector health, RDS logical replication prereqs, then
Snowflake ingestion.

## Teardown

Before `tofu destroy`, drop the replication slot Debezium created — it
isn't cleaned up automatically and pins WAL on the RDS instance otherwise
(`docs/debezium-postgres-config.md`):

```bash
scripts/teardown-replication-slot.sh
```

Opens its own SSM tunnel (no manual tunnel setup needed) and is a no-op if
the slot's already gone. The `kafka` namespace itself doesn't survive
`tofu destroy` (it lives on the EKS cluster being destroyed), so nothing
else needs explicit cleanup.
